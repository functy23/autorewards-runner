/// 设置页（aShellYou settings-dsl 风格：分组标题 + 连体圆角卡片组 + 圆形图标底
/// 条目 + 顶部搜索栏实时过滤）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/app_log.dart';
import '../../core/app_prefs.dart';
import '../../core/task_notifier.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/settings_items.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.wide = false});

  final bool wide;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 可搜索的设置条目元数据
class _Entry {
  final String group;
  final String title;
  final String desc;
  final Widget Function(BuildContext) build;
  _Entry(this.group, this.title, this.desc, this.build);
}

class _SettingsPageState extends State<SettingsPage> {
  final _forumsCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _forumsCtrl.text = AppPrefs.mhyForums;
  }

  @override
  void dispose() {
    _forumsCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ============================================================
  // 可搜索条目目录
  // ============================================================

  List<_Entry> _catalog() {
    return [
      _Entry('启动行为', 'App 启动时自动运行所有任务', '默认关闭；开启后每次打开 App 自动执行一轮任务',
          (_) => SettingsSwitchItem(
                title: 'App 启动时自动运行所有任务',
                description: '默认关闭；开启后每次打开 App 自动执行一轮任务',
                icon: Icons.rocket_launch_rounded,
                value: AppPrefs.autoRunOnStart,
                onChanged: (v) => setState(() => AppPrefs.autoRunOnStart = v),
              )),
      _Entry('启动行为', '预测性返回手势', 'Android 14+ 返回预览动画，默认开启（重启 App 生效）',
          (_) => SettingsSwitchItem(
                title: '预测性返回手势',
                description: 'Android 14+ 返回预览动画，默认开启（重启 App 生效）',
                icon: Icons.swipe_left_rounded,
                value: AppPrefs.predictiveBack,
                onChanged: (v) {
                  setState(() => AppPrefs.predictiveBack = v);
                  uiRevision.value++;
                },
              )),
      _Entry('米游社任务', '游戏签到', '原神/星铁/绝区零等 luna 每日签到（原石等奖励）',
          (_) => SettingsSwitchItem(
            title: '游戏签到',
            icon: Icons.redeem_rounded,
            value: AppPrefs.mhyGameSign,
            onChanged: (v) => setState(() => AppPrefs.mhyGameSign = v),
          )),
      _Entry('米游社任务', '讨论区签到', '', (_) => SettingsSwitchItem(
            title: '讨论区签到',
            icon: Icons.how_to_reg_rounded,
            value: AppPrefs.mhySign,
            onChanged: (v) => setState(() => AppPrefs.mhySign = v),
          )),
      _Entry('米游社任务', '看帖', '', (_) => SettingsSwitchItem(
            title: '看帖',
            icon: Icons.article_rounded,
            value: AppPrefs.mhyRead,
            onChanged: (v) => setState(() => AppPrefs.mhyRead = v),
          )),
      _Entry('米游社任务', '点赞', '', (_) => SettingsSwitchItem(
            title: '点赞',
            icon: Icons.thumb_up_alt_rounded,
            value: AppPrefs.mhyLike,
            onChanged: (v) => setState(() => AppPrefs.mhyLike = v),
          )),
      _Entry('米游社任务', '点赞后自动取消', '', (_) => SettingsSwitchItem(
            title: '点赞后自动取消',
            icon: Icons.sync_rounded,
            value: AppPrefs.mhyCancelLike,
            onChanged: (v) => setState(() => AppPrefs.mhyCancelLike = v),
          )),
      _Entry('米游社任务', '分享', '', (_) => SettingsSwitchItem(
            title: '分享',
            icon: Icons.ios_share_rounded,
            value: AppPrefs.mhyShare,
            onChanged: (v) => setState(() => AppPrefs.mhyShare = v),
          )),
      _Entry('米游社任务', '分区 ID', 'gids：2=原神 6=星铁 1=崩三 8=绝区零',
          (_) => SettingsContentItem(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CopyableField(
                  controller: _forumsCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '分区 ID（逗号分隔）',
                    helperText: 'gids：2=原神 6=星穹铁道 1=崩坏3 8=绝区零 5=大别野',
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    AppPrefs.mhyForums = _forumsCtrl.text;
                    _toast('米游社配置已保存');
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ],
            ),
          )),
      if (Platform.isAndroid)
        _Entry('通知', '任务进度通知', '运行任务时在系统通知栏显示实时进度（Android 13+ 需授权）',
            (_) => SettingsTapItem(
                  title: '开启任务进度通知',
                  description: '运行任务时在系统通知栏显示实时进度；一键运行显示总进度',
                  icon: Icons.notifications_active_rounded,
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final ok = await TaskNotifier.requestPermission();
                    _toast(ok ? '已请求通知权限，可在系统设置中确认' : '当前设备不支持或已拒绝通知');
                  },
                )),
      _Entry('配置文件', '导出配置', '全部配置 + 凭据 + Bing 浏览器 Cookie',
          (_) => SettingsTapItem(
                title: '导出配置',
                description: '全部配置 + 凭据 + Bing 浏览器 Cookie，可迁移到另一台设备',
                icon: Icons.ios_share_rounded,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _exportConfig,
              )),
      _Entry('配置文件', '导入配置', '粘贴另一个客户端导出的 JSON',
          (_) => SettingsTapItem(
                title: '导入配置',
                description: '粘贴另一个客户端导出的 JSON',
                icon: Icons.download_rounded,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _importConfig,
              )),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 窄屏：内容在模糊顶栏/底栏下滚动，需留出相应边距
    final wide = widget.wide;
    final media = MediaQuery.of(context);
    final topPad = wide ? 8.0 : media.padding.top + kToolbarHeight + 4;
    final q = _query.trim().toLowerCase();
    return Column(
      children: [
        // ---- 搜索栏（aShellYou 风格：圆角胶囊）----
        Padding(
          padding: EdgeInsets.fromLTRB(15, topPad, 15, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              hintText: '搜索设置',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: q.isEmpty
              ? _groupedView()
              : _searchView(q, cs: Theme.of(context).colorScheme),
        ),
      ],
    );
  }

  // ---- 常规分组视图：按组名聚合目录条目（避免下标漂移）----
  Widget _groupedView() {
    final bottomPad = widget.wide ? 32.0 : MediaQuery.paddingOf(context).bottom + 100;
    final entries = _catalog();
    Widget group(String name, {Widget? extras}) => Column(
          children: [
            SettingsGroupHeader(name),
            SettingsCardGroup(children: [
              for (final e in entries.where((e) => e.group == name))
                e.build(context),
              ?extras,
            ]),
          ],
        );
    Widget mhyExtras() => SettingsContentItem(
          child: Text(
            '任务进度只认扫码登录（stoken）；账号页可重新登录。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        );

    return ListView(
      padding: EdgeInsets.fromLTRB(15, 4, 15, bottomPad),
      children: [
        group('启动行为'),
        group('米游社任务', extras: mhyExtras()),
        if (entries.any((e) => e.group == '通知')) group('通知'),
        group('配置文件'),
        const SizedBox(height: 16),
      ],
    );  }

  // ---- 搜索结果视图 ----
  Widget _searchView(String q, {required ColorScheme cs}) {
    final bottomPad = widget.wide ? 32.0 : MediaQuery.paddingOf(context).bottom + 100;
    final hits = _catalog()
        .where((e) =>
            e.title.toLowerCase().contains(q) ||
            e.desc.toLowerCase().contains(q) ||
            e.group.toLowerCase().contains(q))
        .toList();
    if (hits.isEmpty) {
      return Center(
        child: Text('没有匹配「$_query」的设置项',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant)),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(15, 4, 15, bottomPad),
      children: [
        const SettingsGroupHeader('搜索结果'),
        SettingsCardGroup(
          children: [
            for (final e in hits)
              SettingsTapItem(
                title: e.title,
                description: e.desc.isEmpty ? e.group : '${e.group} · ${e.desc}',
                icon: Icons.tune_rounded,
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 导出 / 导入
  // ============================================================

  static String _ts() {
    final n = DateTime.now();
    return '${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}'
        '-${n.hour.toString().padLeft(2, '0')}${n.minute.toString().padLeft(2, '0')}';
  }

  Future<List<Map<String, dynamic>>> _collectBingCookies() async {
    final out = <Map<String, dynamic>>[];
    try {
      final cm = CookieManager.instance();
      final cookies = await cm.getCookies(url: WebUri('https://www.bing.com'));
      for (final c in cookies) {
        out.add({
          'name': c.name,
          'value': c.value ?? '',
          'domain': c.domain ?? '',
          'path': c.path ?? '/',
          'isSecure': c.isSecure,
          'isHttpOnly': c.isHttpOnly,
        });
      }
    } catch (e) {
      AppLog.w('CFG', '收集 Bing Cookie 失败: $e');
    }
    return out;
  }

  Future<void> _exportConfig() async {
    final payload = {
      '_format': 'autorewards-config',
      '_version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'prefs': AppPrefs.dumpAll(),
      'bingCookies': await _collectBingCookies(),
    };
    final text = const JsonEncoder.withIndent('  ').convert(payload);

    String? path;
    try {
      final dir = Platform.isMacOS
          ? Directory('${Platform.environment['HOME']}/Downloads')
          : Directory.systemTemp;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}/autorewards-config-${_ts()}.json');
      await f.writeAsString(text);
      path = f.path;
    } catch (e) {
      AppLog.w('CFG', '配置文件写盘失败: $e');
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('配置已导出'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (path != null)
                Text('已保存到：$path\n（含 Cookie/令牌，等同账号密码，请勿外传）',
                    style: Theme.of(dctx).textTheme.bodySmall),
              if (path == null) const Text('写盘失败，可复制以下内容手动保存'),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(text,
                      style: Theme.of(dctx).textTheme.bodySmall
                          ?.copyWith(fontFamily: 'monospace')),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(dctx)
                  .showSnackBar(const SnackBar(content: Text('配置 JSON 已复制')));
            },
            child: const Text('复制全部'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _importConfig() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('导入配置'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            maxLines: 10,
            style: Theme.of(dctx).textTheme.bodySmall
                ?.copyWith(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '粘贴另一个客户端导出的配置 JSON（_format: autorewards-config）',
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final map = jsonDecode(ctrl.text.trim());
      if (map is! Map) throw const FormatException('根节点必须是 JSON 对象');
      final count = await AppPrefs.importJson(jsonEncode(map['prefs'] ?? map));

      var cookieCount = 0;
      if (map['bingCookies'] is List) {
        final cm = CookieManager.instance();
        for (final c in (map['bingCookies'] as List)) {
          if (c is! Map || c['name'] == null) continue;
          try {
            await cm.setCookie(
              url: WebUri('https://www.bing.com'),
              name: c['name'].toString(),
              value: (c['value'] ?? '').toString(),
              domain: (c['domain'] ?? '').toString().isEmpty
                  ? null
                  : c['domain'].toString(),
              path: (c['path'] ?? '/').toString(),
              isSecure: c['isSecure'] == true,
            );
            cookieCount++;
          } catch (_) {}
        }
      }
      _toast('已导入 $count 项配置、$cookieCount 条 Cookie（部分配置重启后生效）');
    } catch (e) {
      _toast('导入失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
