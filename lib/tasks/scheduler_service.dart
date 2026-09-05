/// 任务执行服务。
///
/// - runAll：全部任务（主页 FAB「执行全部」）
/// - runSingle：单任务执行（主页各状态卡的播放按钮）
/// - cancel()：请求停止（粗粒度：在任务之间生效）
/// - statuses：各任务真实完成状态（查线上接口），主页监听展示
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import '../core/app_log.dart';
import '../core/app_prefs.dart';
import '../core/task_notifier.dart';
import '../services/mihoyobbs/mihoyobbs_service.dart';
import '../services/workbuddy/workbuddy_service.dart';

class TaskService {
  static final TaskService instance = TaskService._();
  TaskService._();

  bool _running = false;
  bool _cancelRequested = false;
  String _runningTask = '';

  bool get isRunning => _running;
  String get runningTask => _runningTask;

  /// 各任务真实完成状态（null = 未配置/查询失败），主页监听展示
  final ValueNotifier<Map<String, bool?>> statuses =
      ValueNotifier<Map<String, bool?>>({'wb': null, 'mhy': null, 'bing': null});

  /// 查询实际完成状态：WorkBuddy/米游社查线上接口，Bing 用本地当日标记。
  /// 本地已完成标记直接短路（不打 API 查询日志）：接口的 today_checked_in
  /// 实测不可靠，启动时会出现「日志说未完成、卡片已完成」的矛盾展示。
  Future<void> refreshStatuses() async {
    bool wb;
    bool mhy;
    if (AppPrefs.isDoneToday('wb')) {
      wb = true;
      AppLog.i('WB', 'WorkBuddy 今日已签到（本地标记）');
    } else {
      try {
        final api = await WorkBuddyService().checkStatus();
        wb = api == true;
        AppLog.i('WB',
            api == null ? 'WorkBuddy 状态查询失败（未配置或 token 过期）' : 'WorkBuddy 今日${wb ? '已签到' : '未签到'}');
      } catch (e) {
        wb = false;
        AppLog.w('WB', 'WorkBuddy 状态查询异常: $e');
      }
    }
    if (AppPrefs.isDoneToday('mhy')) {
      mhy = true;
      AppLog.i('MHY', '米游社今日任务已完成（本地标记）');
    } else {
      try {
        final api = await MihoyoBbsService().tasksAllDone();
        mhy = api == true;
        AppLog.i('MHY',
            api == null ? '米游社状态查询失败（未配置或登录态过期）' : '米游社今日任务${mhy ? '已完成' : '未完成'}');
      } catch (e) {
        mhy = false;
        AppLog.w('MHY', '米游社状态查询异常: $e');
      }
    }
    statuses.value = {
      'wb': wb || AppPrefs.isDoneToday('wb'),
      'mhy': mhy || AppPrefs.isDoneToday('mhy'),
      'bing': AppPrefs.isDoneToday('bing'),
    };
  }

  /// 请求停止当前执行（在当前步骤完成后生效）
  void cancel() {
    if (_running) {
      _cancelRequested = true;
      AppLog.w('TASK', '已请求停止，当前步骤完成后终止');
    }
  }

  bool _shouldStop() {
    if (!_cancelRequested) return false;
    AppLog.w('TASK', '执行已停止');
    return true;
  }

  /// 单任务执行
  Future<void> runSingle(String task) async {
    if (_running) {
      AppLog.w('TASK', '已有任务在执行中，忽略本次触发');
      return;
    }
    _running = true;
    _cancelRequested = false;
    _runningTask = task;
    final name = switch (task) {
      'wb' => 'WorkBuddy',
      'mhy' => '米游社',
      _ => 'Bing',
    };
    TaskNotifier.busy(title: '$name 任务', text: '正在执行…');
    try {
      switch (task) {
        case 'wb':
          await _runWorkBuddy();
        case 'mhy':
          await _runMihoyo();
        case 'bing':
          AppLog.i('TASK', 'Bing 刷分需要 WebView 环境，请到 Bing 页执行');
      }
      await TaskNotifier.finish(text: '$name 任务结束');
    } finally {
      _running = false;
      _runningTask = '';
      unawaited(refreshStatuses());
    }
  }

  /// 全部任务：WorkBuddy 与米游社**并行**执行；Bing 通过 [onBingStage] 回调
  /// 由 UI 层后台挂载 webview（脚本随页面原生注入并自动启动），不切换页面。
  Future<void> runAll({Future<void> Function()? onBingStage}) async {
    if (_running) {
      AppLog.w('TASK', '任务已在运行中，忽略本次触发');
      return;
    }
    _running = true;
    _cancelRequested = false;
    _runningTask = 'all';
    var done = 0;
    void bump(String name) {
      done++;
      unawaited(TaskNotifier.progress(
          done: done, total: 3, text: '$name 已完成'));
    }

    TaskNotifier.start(title: 'AutoRewards 任务', text: '并行执行 WorkBuddy + 米游社…');
    try {
      AppLog.i('TASK', '===== 开始执行全部任务（WorkBuddy/米游社并行） =====');
      await Future.wait([_runWorkBuddy(onDone: () => bump('WorkBuddy')), _runMihoyo(onDone: () => bump('米游社'))]);

      if (!_shouldStop()) {
        if (onBingStage != null) {
          AppLog.i('TASK', '【Bing Rewards】后台挂载 Bing 页，脚本将随页面自动执行');
          await onBingStage();
          bump('Bing');
        } else {
          AppLog.i('TASK', '【Bing Rewards】请到「Bing」页打开 WebView 自动执行');
        }
      }
      AppLog.i('TASK', '===== 全部任务结束 =====');
      await TaskNotifier.finish(text: done >= 3 ? '全部任务已完成' : 'WorkBuddy/米游社结束');
    } finally {
      _running = false;
      _runningTask = '';
      unawaited(refreshStatuses());
    }
  }

  /// [onDone] 任务流程结束时回调（无论成败，供进度通知计数）
  Future<void> _runWorkBuddy({void Function()? onDone}) async {
    if (_shouldStop()) return;
    AppLog.i('WB', '【WorkBuddy】开始签到…');
    try {
      final r = await WorkBuddyService().checkin();
      AppLog.i('WB', '【WorkBuddy】${r.summary}');
      for (final s in r.steps) {
        AppLog.i('WB', s.trim());
      }
      if (r.ok) await AppPrefs.markDoneToday('wb');
    } catch (e) {
      AppLog.e('WB', '【WorkBuddy】异常: $e');
    } finally {
      onDone?.call();
    }
  }

  Future<void> _runMihoyo({void Function()? onDone}) async {
    if (_shouldStop()) return;
    AppLog.i('MHY', '【米游社】开始执行…');
    try {
      final r = await MihoyoBbsService().runAll();
      AppLog.i('MHY', '【米游社】${r.summary}');
      for (final s in r.steps) {
        AppLog.i('MHY', s.trim());
      }
      if (r.ok) await AppPrefs.markDoneToday('mhy');
    } catch (e) {
      AppLog.e('MHY', '【米游社】异常: $e');
    } finally {
      onDone?.call();
    }
  }
}
