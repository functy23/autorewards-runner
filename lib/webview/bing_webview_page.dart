/// 必应 Bing Rewards 刷分页面。
///
/// 两层实现：
/// 1. 油猴脚本层：注入原版「Microsoft Bing Rewards 自动搜索助手」（greasyfork
///    538825）+ 自动启动补丁。原脚本负责：从 Rewards 侧栏抓搜索词、进度检查、
///    随机滚动、休息策略 —— 全部保留。
/// 2. 兜底层：若原脚本 UI 没出现（改版/加载失败），注入一个我们自己的轻量
///    自动搜索器（随机词 + 随机延迟 + 滚动），见 [BingAutoSearcher]。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../core/app_log.dart';
import '../core/app_prefs.dart';
import '../core/cn_words.dart';
import '../services/userscript/userscript_engine.dart';

class BingWebViewPage extends StatefulWidget {
  const BingWebViewPage({super.key});

  /// 主页通过 `GlobalKey<BingWebViewPageState>` 调用页面操作（顶栏按钮挂在
  /// 外层 BlurredAppBar 上，本页面不再自带 Scaffold —— 否则外层顶栏会
  /// 消失导致侧边栏跳位）
  @override
  BingWebViewPageState createState() => BingWebViewPageState();
}

class BingWebViewPageState extends State<BingWebViewPage> {
  InAppWebViewController? _controller;
  final _rng = Random();
  bool _fallbackStarted = false;
  String _status = '加载中…';
  Timer? _statusTimer;

  // 起始页：必应搜索结果页，搜索词每次进入页面从内置二字词库随机挑选
  late final String _startUrl = _randomSearchUrl();

  /// 原生 UserScript（webview 创建时注册进 WKUserContentController，每次导航
  /// 自动执行）。不能用 evaluateJavascript 注入：macOS 上 method channel 与
  /// 页面回调的注册时序不稳定，实测会出现整段生命周期 MissingPluginException，
  /// 脚本完全注不进去（悬浮框不出现）。静态缓存避免重复读资产。
  static String? _bundledCache;
  List<UserScript>? _userScripts;

  @override
  void initState() {
    super.initState();
    _prepareScripts();
  }

  String _randomSearchUrl() {
    final word = kCnWords2[_rng.nextInt(kCnWords2.length)];
    final encoded = Uri.encodeComponent(word);
    return 'https://www.bing.com/search?q=$encoded&PC=U316&FORM=CHROMN';
  }

  Future<void> _prepareScripts() async {
    try {
      final custom = AppPrefs.customUserscript;
      final String source;
      if (custom != null && custom.trim().isNotEmpty) {
        source = custom;
        AppLog.i('BING', '使用用户自定义脚本 (${source.length}B)');
      } else {
        _bundledCache ??= await UserscriptEngine.loadBundled(
            'assets/userscripts/bing_rewards_1.3.2.user.js');
        source = _bundledCache!;
        AppLog.i('BING', '使用内置脚本 bing_rewards_1.3.2 (${source.length}B)');
      }
      var wrapped = UserscriptEngine.wrapForInjection(
        source,
        storageKey: 'bing_rewards_auto_searcher_config',
      );
      // 自动启动补丁并入同一个 UserScript：多 UserScript 在 macOS 上曾出现
      // 只有第一个被执行的情况（自动启动静默失效），合并后无此问题
      if (AppPrefs.bingAutoStart) {
        wrapped = '$wrapped;\n${UserscriptEngine.autoStartPatch()}';
      }
      final scripts = <UserScript>[
        UserScript(
          source: wrapped,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
          forMainFrameOnly: true,
          groupName: 'bing_rewards_main',
        ),
      ];
      if (!mounted) return;
      setState(() => _userScripts = scripts);
    } catch (e, st) {
      AppLog.e('BING', '脚本准备失败: $e\n$st');
      _setStatus('脚本加载失败: $e');
    }
  }

  // PullToRefreshController 仅在 Android 上受支持（macOS WebView 无此实现，
  // 直接创建会抛 UnimplementedError，所以按平台条件构造）
  late final PullToRefreshController? _pullRefresh = Platform.isAndroid
      ? PullToRefreshController(onRefresh: () => _controller?.reload())
      : null;

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  /// evaluateJavascript 平台通道竞态防护：macOS 上 method channel 偶发晚于
  /// 页面回调注册，带退避重试。主脚本注入已改走原生 UserScript，这里只剩
  /// 交互按钮和兜底监测在用，重试次数调小避免刷屏。
  Future<bool> _safeEval(String source, {int retries = 2}) async {
    for (var i = 0; i < retries; i++) {
      final c = _controller;
      if (c == null) {
        await Future.delayed(const Duration(milliseconds: 300));
        continue;
      }
      try {
        await c.evaluateJavascript(source: source);
        return true;
      } on MissingPluginException {
        AppLog.w('BING',
            'evaluateJavascript 通道未就绪，${300 * (i + 1)}ms 后重试 (${i + 1}/$retries)');
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      } catch (e) {
        AppLog.w('BING', 'evaluateJavascript 失败: $e');
        return false;
      }
    }
    return false;
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  // ============================================================
  // 兜底自动搜索器（不依赖油猴脚本）
  // ============================================================

  void _startFallbackSearcher() {
    if (_fallbackStarted) return;
    _fallbackStarted = true;

    // 设置页的 Bing 配置已移除：次数/节奏用固定默认值，词用内置二字词库
    const count = 30;
    const minD = 12, maxD = 28;

    var done = 0;
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _controller == null) {
        timer.cancel();
        return;
      }
      if (done >= count) {
        timer.cancel();
        _setStatus('兜底搜索完成（$count 次）');
        return;
      }
      final remain = timer.tick;
      final interval = minD + _rng.nextInt((maxD - minD).clamp(1, 120));
      if (remain % interval != 0) return;

      final term = kCnWords2[_rng.nextInt(kCnWords2.length)];
      final js = '''
(function(){
  var box = document.querySelector('#sb_form_q');
  var form = document.querySelector('#sb_form');
  if (!box || !form) return false;
  box.value = ${jsonEncodeJs(term)};
  form.submit();
  return true;
})()
''';
      final ok = await _safeEval(js);
      if (ok) {
        done++;
        _setStatus('兜底搜索 $done/$count: $term');
        AppLog.i('BING', 'fallback search #$done: $term');
        // 随机滚动，模拟真人浏览
        await Future.delayed(const Duration(seconds: 2));
        await _safeEval(
            'window.scrollBy({top: ${200 + _rng.nextInt(600)}, behavior: "smooth"});');
      }
    });
  }

  String jsonEncodeJs(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  // ============================================================
  // 顶栏操作（由主页外层 BlurredAppBar 的按钮调用）
  // ============================================================

  Future<void> autoStartScript() async {
    // 手动触发：强制执行，不受 30 分钟自动启动去重限制
    await _safeEval(UserscriptEngine.autoStartPatch(force: true));
  }

  void startFallbackSearcherPublic() => _startFallbackSearcher();

  void reloadAndReinject() {
    // UserScript 原生注册，reload 即重新执行全部脚本
    _fallbackStarted = false;
    _controller?.reload();
  }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // 不再自带 Scaffold/appBar：外层主页顶栏常驻（Bing 操作按钮也挂那里），
    // body 从顶栏下方开始，状态条不需要再加顶栏高度偏移
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          width: double.infinity,
          child: Text(
            '状态: $_status',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          // 脚本异步准备就绪后才创建 webview——initialUserScripts 只能在
          // 创建时传入，之后无法补挂
          child: _userScripts == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_startUrl)),
                  pullToRefreshController: _pullRefresh,
                  initialUserScripts:
                      UnmodifiableListView<UserScript>(_userScripts!),
                  initialSettings: InAppWebViewSettings(
                    userAgent: null, // 用系统默认 WebView UA（桌面/mac 用 Safari 风格）
                    javaScriptEnabled: true,
                    transparentBackground: false,
                    supportZoom: true,
                    isInspectable: true, // macOS 上允许右键检查，方便调试
                    cacheEnabled: true,
                    incognito: false, // 必须非隐身：要保留 Bing 登录 cookie
                  ),
                  onWebViewCreated: (c) {
                    _controller = c;
                  },
                  onLoadStop: (c, uri) async {
                    _setStatus('页面加载完成: ${uri?.host}（脚本已随页面执行）');
                    // 油猴 UI 启动的刷分会话开始 → 标记今日完成（幂等）
                    await AppPrefs.markDoneToday('bing');
                    // 兜底监测：20 秒后若还没检测到脚本 UI，用兜底搜索器
                    if (!_fallbackStarted) {
                      Timer(const Duration(seconds: 20), () async {
                        if (!mounted || _fallbackStarted) return;
                        final hasUi = await _safeEval(
                            '!!document.querySelector("#sb_form_q") && (function(){'
                            ' var els=document.querySelectorAll("div,button,span");'
                            ' for(var i=0;i<els.length;i++){'
                            '   if((els[i].textContent||"").trim()==="开始自动搜索") return true;'
                            ' } return false;})()',
                            retries: 1);
                        if (!hasUi && mounted) {
                          _setStatus('未检测到脚本 UI，启用兜底自动搜索');
                          _startFallbackSearcher();
                        }
                      });
                    }
                  },
                  onConsoleMessage: (c, msg) {
                    final text = msg.message;
                    if (text.contains('[AutoStart]') ||
                        text.contains('Rewards') ||
                        text.contains('[UserscriptEngine]')) {
                      AppLog.d('BING-JS', text);
                    }
                  },
                  onPermissionRequest: (c, req) async {
                    // 拒绝所有权限请求（定位/摄像头等），Bing 页面不需要
                    return;
                  },
                ),
        ),
      ],
    );
  }
}
