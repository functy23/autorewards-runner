/// Android 任务进度通知（「实时活动」的 Android 承载形式）。
///
/// Android 没有 iOS 的 Live Activity，用常驻进度通知实现同样语义：
/// - 单任务：通知标题=任务名，进度条+文本
/// - 一键运行：总进度（x/3）+ 当前完成项
/// 原生端见 MainActivity.kt 的 `rewards_runner/notifications` channel。
/// 所有方法吞异常——通知失败绝不能影响任务执行。非 Android 平台全部 no-op。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class TaskNotifier {
  static const _ch = MethodChannel('rewards_runner/notifications');

  static bool get supported => Platform.isAndroid;

  static Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!supported) return;
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {
      // 通知是锦上添花，静默失败
    }
  }

  /// 请求通知权限（Android 13+ POST_NOTIFICATIONS 运行时权限）。
  /// 返回 true 表示权限可能已具备（部分系统无法同步获知结果）。
  static Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      final r = await _ch.invokeMethod<bool>('requestPermission');
      return r ?? true;
    } catch (_) {
      return false;
    }
  }

  /// 开始一轮任务：创建/更新常驻通知
  static Future<void> start({required String title, required String text}) =>
      _invoke('start', {'title': title, 'text': text});

  /// 更新总进度（一键运行：done/total）
  static Future<void> progress({
    required int done,
    required int total,
    required String text,
  }) =>
      _invoke('progress', {'done': done, 'total': total, 'text': text});

  /// 单任务进度（不确定进度，转圈样式）
  static Future<void> busy({required String title, required String text}) =>
      _invoke('busy', {'title': title, 'text': text});

  /// 结束：显示完成文案，数秒后自动消失
  static Future<void> finish({required String text}) =>
      _invoke('finish', {'text': text});

  static Future<void> cancel() => _invoke('cancel');
}
