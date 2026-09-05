/// 油猴（Userscript）兼容引擎。
///
/// 思路：flutter_inappwebview 的 UserScript 只有 GM 特性的极小子集
/// （@match、@run-at、true 注入 main world），不认识 GM_* API 与
/// @grant none 之外的很多元数据。这里做三层适配：
///
/// 1. [metadata]        解析 ==UserScript== 元数据块
/// 2. [wrapForInjection] 把脚本体包一层 polyfill（GM_addStyle、GM_setValue/
///    GM_getValue 用 localStorage 模拟、unsafeWindow=window 等）
/// 3. [autoStartPatch]   针对“Microsoft Bing Rewards 自动搜索助手”
///    (greasyfork 538825) 的改造：把用户点按钮才开始的交互改成 App 注入的
///    启动命令自动触发 —— 保持原脚本全部逻辑（延迟/滚动/进度检查）不变。
library;

import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;

class UserscriptMeta {
  final String name;
  final String version;
  final List<String> matches;
  final bool grantNone;
  final String source;
  UserscriptMeta({
    required this.name,
    required this.version,
    required this.matches,
    required this.grantNone,
    required this.source,
  });
}

class UserscriptEngine {
  /// 解析元数据
  static UserscriptMeta parse(String source) {
    final m = RegExp(
      r'//\s*==UserScript==([\s\S]*?)//\s*==/UserScript==',
    ).firstMatch(source);
    var name = 'userscript';
    var version = '0.0.0';
    final matches = <String>[];
    var grantNone = false;
    if (m != null) {
      for (final line in m.group(1)!.split('\n')) {
        final kv = RegExp(r'@(\S+)\s+(.*)').firstMatch(line.trim());
        if (kv == null) continue;
        final key = kv.group(1)!;
        final value = kv.group(2)!.trim();
        switch (key) {
          case 'name':
            name = value;
          case 'version':
            version = value;
          case 'match' || 'include':
            matches.add(value);
          case 'grant':
            if (value == 'none') grantNone = true;
        }
      }
    }
    return UserscriptMeta(
        name: name,
        version: version,
        matches: matches,
        grantNone: grantNone,
        source: source);
  }

  /// 去掉元数据块（注入时不必要，还能减少解析成本）
  static String stripMeta(String source) =>
      source.replaceFirst(RegExp(r'//\s*==UserScript==[\s\S]*?//\s*==/UserScript==\s*'), '');

  /// 包装脚本：GM polyfill + 错误捕获
  static String wrapForInjection(String source, {String storageKey = '__gm_storage'}) {
    final body = stripMeta(source);
    return '''
(function(){
  'use strict';
  // ---- GM polyfill（最小集，用 localStorage 模拟持久化）----
  var __GM_KEY = '$storageKey';
  function __gmStore(){ try{ return JSON.parse(localStorage.getItem(__GM_KEY)||'{}'); }catch(e){ return {}; } }
  function __gmSave(o){ try{ localStorage.setItem(__GM_KEY, JSON.stringify(o)); }catch(e){} }
  window.GM_getValue = function(k, d){ var s=__gmStore(); return (k in s) ? s[k] : d; };
  window.GM_setValue = function(k, v){ var s=__gmStore(); s[k]=v; __gmSave(s); };
  window.GM_deleteValue = function(k){ var s=__gmStore(); delete s[k]; __gmSave(s); };
  window.GM_addStyle = function(css){ var s=document.createElement('style'); s.textContent=css; (document.head||document.documentElement).appendChild(s); };
  window.GM_xmlhttpRequest = function(opt){ // 最小实现，走页面同源 fetch
    fetch(opt.url, {method: opt.method||'GET', headers: opt.headers||{}, body: opt.data})
      .then(function(r){ return r.text().then(function(t){ opt.onload && opt.onload({status:r.status, responseText:t}); }); })
      .catch(function(e){ opt.onerror && opt.onerror(e); });
  };
  if (typeof window.unsafeWindow === 'undefined') { window.unsafeWindow = window; }
  // ---- 用户脚本体 ----
  try {
    $body
  } catch (e) {
    console.error('[UserscriptEngine]', e);
  }
})();
''';
  }

  /// 读取内置脚本（assets 里的油猴脚本在编译期打进 app）
  static Future<String> loadBundled(String assetPath) =>
      rootBundle.loadString(assetPath);

  // ============================================================
  // 针对脚本 538825（Bing Rewards 自动搜索助手 v1.3.2）的自动启动改造
  // ============================================================

  /// App 侧注入的“启动器”脚本：
  /// - 原脚本在 window load 后创建 UI 面板，等待用户点「开始自动搜索」按钮
  /// - 我们模拟一次对该按钮的点击（el.click() 是程序事件，Bing 页面不校验
  ///   isTrusted 的场景下可用 —— 按钮处理逻辑属于脚本自身，不存在过滤）
  /// - 若面板未找到（脚本更新改版），回退：直接向搜索框填词提交 N 次的
  ///   简易模式由 Dart 侧 [BingAutoSearcher] 完成
  ///
  /// 作为原生 UserScript 时每次导航都会执行，而点击「开始自动搜索」本身会
  /// 触发搜索导航——必须用本机标记去重，否则每个搜索结果页都重新点击一次，
  /// 形成「点开始→导航→再点」的无限循环（2026-09-05 实测）。30 分钟 TTL：
  /// 与脚本单次刷分会话时长同量级，跨天/手动重开不受影响。
  /// [force] = 手动点击顶栏按钮触发，跳过 30 分钟去重标记。
  /// ⚠️ force 必须插值成 JS 字面量（true/false）——写成裸标识符会在
  /// JS 里变成未定义变量 ReferenceError，补丁静默死亡（曾踩坑）
  static String autoStartPatch({bool force = false}) => '''
(function(){
  console.log('[AutoStart] patch entered');
  var MARK = '__gm_autostart_done_at';
  var last = 0;
  try { last = parseInt(localStorage.getItem(MARK) || '0', 10) || 0; } catch (e) {}
  if (!$force && Date.now() - last < 30 * 60 * 1000) {
    console.log('[AutoStart] 30 分钟内已自动启动过，跳过');
    return;
  }
  var attempts = 0;
  var timer = setInterval(function(){
    attempts++;
    if (attempts > 120) {
      clearInterval(timer);
      console.log('[AutoStart] 60 秒内未找到「开始自动搜索」按钮，放弃');
      return;
    }
    if (attempts % 10 === 0) console.log('[AutoStart] waiting btn x' + attempts);
    // 找「开始自动搜索」按钮（脚本 UI 内 id 随机，用文本匹配）
    var btns = document.querySelectorAll('div[style], button, span');
    var target = null;
    for (var i = 0; i < btns.length; i++) {
      var t = (btns[i].textContent || '').trim();
      if (t === '开始自动搜索') { target = btns[i]; break; }
    }
    if (target) {
      clearInterval(timer);
      var ev = new MouseEvent('click', {bubbles: true, cancelable: true});
      target.dispatchEvent(ev);
      // 标记必须在点击成功派发之后再写：写早了万一派发失败，
      // 30 分钟内就不会再自动启动了
      try { localStorage.setItem(MARK, String(Date.now())); } catch (e) {}
      console.log('[AutoStart] clicked 开始自动搜索');
    }
  }, 500);
})();
''';
}

/// 便捷工具：从 File 读脚本（用户自定义脚本用）
Future<String> readUserscriptFile(String path) => File(path).readAsString();
