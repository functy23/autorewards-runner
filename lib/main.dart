/// AutoRewards Runner 主入口。
///
/// 布局遵循 Material Design 3 + Apple 设计规范：
/// - 窗口宽 < 840dp（手机竖屏）→ 底部 NavigationBar（背景模糊），状态卡竖向堆叠
/// - 窗口宽 ≥ 840dp（横屏/平板/桌面）→ 图标式 NavigationRail，状态卡横排
/// - 沉浸式模糊顶栏（无标题；App 名称为主页大标题，随内容滚动）
/// - 主页右下角「执行全部」FAB；各状态卡右侧带单任务执行按钮
///
/// 底栏/侧栏均禁用悬停 tooltip。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'core/app_log.dart';
import 'core/app_prefs.dart';
import 'tasks/scheduler_service.dart';
import 'ui/theme.dart';
import 'ui/pages/accounts_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/widgets/log_window.dart';
import 'webview/bing_webview_page.dart';

Future<Directory> getSupportDir() async {
  if (Platform.isMacOS) {
    // 沙盒 container 下的 Application Support
    final base = Platform.environment['HOME'] ?? '.';
    final dir = Directory(
        '$base/Library/Containers/com.autotask.rewards-runner/Data/Library/Application Support/rewards_runner');
    if (dir.existsSync()) return dir;
    final d2 = Directory('$base/Library/Application Support/rewards_runner');
    if (!d2.existsSync()) d2.createSync(recursive: true);
    return d2;
  }
  // Android：app 私有目录
  final d = Directory('/data/data/com.autotask.rewards_runner/files');
  if (d.existsSync()) return d;
  final fallback = Directory.systemTemp.createTempSync('rewards_runner');
  return fallback;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.i('APP', 'AutoRewards Runner 启动中…');
  await AppPrefs.init();
  AppLog.i('APP', '本地配置加载完成');
  AppLog.init(await getSupportDir());
  // 全局异常兜底：渲染管线（布局/绘制）抛出的异常不经过 FlutterError.onError，
  // 会作为未捕获异常打到 PlatformDispatcher——两者都落一份到日志文件，便于排障
  FlutterError.onError = (details) {
    AppLog.e('FLUTTER', '${details.exception}\n${details.stack ?? ''}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.e('FLUTTER', '未捕获异常: $e\n$st');
    return false;
  };
  runApp(const RewardsRunnerApp());
}

class RewardsRunnerApp extends StatelessWidget {
  const RewardsRunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 监听 uiRevision：预测性返回等 MaterialApp 级设置变更时整体重建
    return ValueListenableBuilder<int>(
      valueListenable: uiRevision,
      builder: (context, _, _) => MaterialApp(
        title: 'AutoRewards Runner',
        theme: buildAppTheme(Brightness.light,
            predictiveBack: AppPrefs.predictiveBack),
        darkTheme: buildAppTheme(Brightness.dark,
            predictiveBack: AppPrefs.predictiveBack),
        themeMode: ThemeMode.system,
        home: const HomePage(),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const _NavItem(this.icon, this.selectedIcon, this.label);
}

const _navItems = [
  _NavItem(Icons.home_outlined, Icons.home_rounded, '总览'),
  _NavItem(Icons.search_outlined, Icons.search_rounded, 'Bing'),
  _NavItem(Icons.person_outline, Icons.person_rounded, '账号'),
  _NavItem(Icons.settings_outlined, Icons.settings_rounded, '设置'),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  StreamSubscription<LogLine>? _logSub;
  // Bing 页操作入口（顶栏按钮在外层，页面本身无 Scaffold）
  final GlobalKey<BingWebViewPageState> _bingKey = GlobalKey<BingWebViewPageState>();
  final GlobalKey<AccountsPageState> _accountsKey = GlobalKey<AccountsPageState>();
  // Bing 页按需挂载：进 Bing 页或一键运行时挂载；IndexedStack 保活后
  // 切到其他页 webview 继续运行、切回来不重载（需求：后台自动搜索）
  bool _bingMounted = false;

  // 宽窄断点：MD3 expanded（840dp）。窄=底栏+竖排卡片，宽=侧栏+横排卡片
  static const _wideBreakpoint = 840.0;

  bool get _running => TaskService.instance.isRunning;

  /// Bing 页顶栏操作（脚本自动开始 / 兜底搜索器 / 重新注入）。
  /// 注意在按下时才读 currentState——构建期 Bing 页可能还没挂载
  List<Widget> _bingActions() {
    return [
      IconButton(
        tooltip: '手动开始（点脚本按钮）',
        icon: const Icon(Icons.play_arrow),
        onPressed: () => _bingKey.currentState?.autoStartScript(),
      ),
      IconButton(
        tooltip: '启用兜底搜索器',
        icon: const Icon(Icons.shield_moon),
        onPressed: () => _bingKey.currentState?.startFallbackSearcherPublic(),
      ),
      IconButton(
        tooltip: '重新注入',
        icon: const Icon(Icons.refresh),
        onPressed: () => _bingKey.currentState?.reloadAndReinject(),
      ),
      const SizedBox(width: 4),
    ];
  }

  void _selectTab(int i) {
    if (i == 1) _bingMounted = true; // 进入 Bing 页才挂载 webview
    if (i == 2) _accountsKey.currentState?.refresh(); // 账号页常驻保活，回访时刷新
    setState(() => _tab = i);
  }

  @override
  void initState() {
    super.initState();
    // 日志驱动主页刷新：任务运行态 / 完成态随之更新
    _logSub = AppLog.stream.listen((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 查询真实完成状态（WorkBuddy/米游社查线上接口）
      TaskService.instance.refreshStatuses();
      // 「启动时自动运行所有任务」（默认关闭）
      if (AppPrefs.autoRunOnStart) {
        Future.delayed(const Duration(seconds: 2), () {
          TaskService.instance.runAll();
        });
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 宽窄用窗口宽度统一判定（侧栏/底栏切换与页面内部布局必须同源）
    final wide = MediaQuery.of(context).size.width >= _wideBreakpoint;
    // IndexedStack 保活四个页面：切走后 Bing webview 继续加载/执行脚本，
    // 切回来不重载；账号页常驻后改为回访时刷新（_selectTab）
    final pages = IndexedStack(
      index: _tab,
      children: [
        _homeBody(wide),
        _bingMounted
            ? BingWebViewPage(key: _bingKey)
            : const SizedBox.shrink(),
        AccountsPage(key: _accountsKey, wide: wide),
        const SettingsPage(),
      ],
    );

    // 顶栏常驻（Bing 页操作按钮挂在这里）——不能按 tab 切换 appBar 为 null，
    // 否则宽屏侧栏/窄屏内容会整体上移一个栏高
    final appBar = BlurredAppBar(actions: _tab == 1 ? _bingActions() : null);

    if (wide) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            // 图标式侧栏（唯一形态；悬停无 tooltip）
            TooltipVisibility(
              visible: false,
              child: NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: _selectTab,
                labelType: NavigationRailLabelType.none,
                destinations: [
                  for (final item in _navItems)
                    NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: Text(item.label),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: pages),
          ],
        ),
        floatingActionButton: _buildFab(wide),
      );
    }
    // 窄屏：底部导航栏。Bing 页是原生 WebView 平台视图，Flutter 的
    // BackdropFilter 无法模糊平台视图内容（合成在引擎之外），所以该页
    // 不让内容延伸到栏下（extendBody=false），避免「模糊失效」的观感
    return Scaffold(
      appBar: appBar,
      extendBody: _tab != 1,
      extendBodyBehindAppBar: _tab != 1,
      body: pages,
      bottomNavigationBar: TooltipVisibility(
        visible: false,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _selectTab,
              backgroundColor:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.7),
              destinations: [
                for (final item in _navItems)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.selectedIcon),
                    label: item.label,
                  ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: _buildFab(wide),
    );
  }

  // ================= 执行按钮（图标 FAB） =================

  Widget? _buildFab(bool wide) {
    if (_tab != 0) return null;
    return FloatingActionButton(
      tooltip: null,
      onPressed: () {
        if (_running) {
          TaskService.instance.cancel();
        } else {
          // 一键运行：WorkBuddy/米游社并行 + 后台挂载 Bing 页自动跑脚本
          // （不切换页面；IndexedStack 保活让脚本在后台持续执行）
          TaskService.instance
              .runAll(onBingStage: () async => setState(() => _bingMounted = true));
        }
      },
      child: Icon(_running ? Icons.pause_rounded : Icons.play_arrow_rounded),
    );
  }

  // ================= 主页 =================
  Widget _homeBody(bool wide) {
    final media = MediaQuery.of(context);
    final barHeight = Platform.isMacOS ? 40.0 : kToolbarHeight;
    // 沉浸式模糊顶栏：内容从其下滚过，大标题从栏下方开始
    final topPad = media.padding.top + barHeight + 12;
    // 底栏模糊（extendBody）：内容延伸到底栏下，日志区留出底栏+FAB 的高度
    final bottomPad = wide ? 16.0 : 96.0;

    Widget title() => Text(
          'AutoRewards Runner',
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        );

    if (wide) {
      // 宽屏（平板/桌面）：三列布局——每张状态卡下方挂各自的日志窗口
      // （只显示该任务 tag 的日志），全部顶对齐（需求 4/5）
      Widget taskColumn(String task, Set<String> logTags) => Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _statusCard(task),
                const SizedBox(height: 8),
                Expanded(child: LogWindow(tags: logTags, scrollable: true)),
              ],
            ),
          );

      return Padding(
        padding: EdgeInsets.fromLTRB(16, topPad, 16, bottomPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title(),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                // 顶对齐：各列高度不同时也不垂直居中
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  taskColumn('wb', {'WB'}),
                  const SizedBox(width: 8),
                  taskColumn('mhy', {'MHY'}),
                  const SizedBox(width: 8),
                  taskColumn('bing', {'BING', 'BING-JS'}),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 窄屏（手机竖屏）：单一滚动流，大标题、状态卡、全量日志顺序排列。
    // 注意：日志窗口内是普通行列表（非 ListView），不能反着把 ListView
    // 塞进滚动布局——RenderViewport 不支持 intrinsic 查询，会把渲染管线
    // 打断（主页空白的根因，见 docs/BUILD_NOTES.md A.9）。
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, topPad, 16, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title(),
          const SizedBox(height: 12),
          for (final task in ['wb', 'mhy', 'bing']) ...[
            _statusCard(task),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          const LogWindow(),
        ],
      ),
    );
  }

  /// 状态卡（含单任务执行入口）；Bing 卡的执行 = 挂载并切到 Bing 页
  Widget _statusCard(String task) {
    final (label, asset, configured) = switch (task) {
      'wb' => (
          'WorkBuddy',
          'assets/icons/workbuddy.png',
          (AppPrefs.secret('wb.token') ?? '').isNotEmpty,
        ),
      'mhy' => (
          '米游社',
          'assets/icons/miyoushe.png',
          (AppPrefs.secret('mhy.stoken') ?? AppPrefs.secret('mhy.cookie') ?? '')
              .isNotEmpty,
        ),
      _ => ('Bing', 'assets/icons/bing.png', true),
    };
    return ValueListenableBuilder<Map<String, bool?>>(
      valueListenable: TaskService.instance.statuses,
      builder: (context, st, _) {
        final done = st[task];
        return StatusCard(
          label: label,
          asset: asset,
          configured: configured,
          done: done,
          loading: configured && done == null,
          running: _running &&
              (TaskService.instance.runningTask == task ||
                  TaskService.instance.runningTask == 'all'),
          onRun: _running
              ? null
              : () {
                  if (task == 'bing') {
                    // Bing 需要真实 WebView 环境：挂载并切到 Bing 页自动执行
                    setState(() {
                      _bingMounted = true;
                      _tab = 1;
                    });
                    return;
                  }
                  TaskService.instance.runSingle(task);
                },
        );
      },
    );
  }
}
