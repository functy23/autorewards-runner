/// 本地配置存储。
///
/// 全部数据仅保存在本机：
/// - Android:  app 私有目录（App Data，卸载即清除，其它应用不可读）
/// - macOS:    沙盒 Container 的 SharedPreferences（~/Library/Containers/...）
///
/// 敏感字段（cookie/stoken/token）与普通配置分开 API，便于审查：
/// 涉密读写只允许通过 [secrets] 命名空间，且永远不进日志。
/// 支持整包导出/导入（配置 + 凭据 + Bing 浏览器 Cookie），用于迁移到另一个客户端。
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  static SharedPreferences? _sp;

  static Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p =>
      _sp ?? (throw StateError('AppPrefs.init() 未调用'));

  // ---------- 启动行为 ----------
  /// App 启动时自动运行所有任务（默认关闭）
  static bool get autoRunOnStart => _p.getBool('app.autoRunOnStart') ?? false;
  static set autoRunOnStart(bool v) => _p.setBool('app.autoRunOnStart', v);

  /// 预测性返回手势（Android predictive back，默认开启）
  static bool get predictiveBack => _p.getBool('app.predictiveBack') ?? true;
  static set predictiveBack(bool v) => _p.setBool('app.predictiveBack', v);

  /// 主题/UI 修订号：设置页改动需要重建 MaterialApp 时递增
  static int uiRevision = 0;

  // ---------- 每日完成态（键：wb / mhy / bing，值为 YYYY-MM-DD）----------
  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static bool isDoneToday(String task) =>
      _p.getString('done.$task') == _today();

  static Future<void> markDoneToday(String task) =>
      _p.setString('done.$task', _today());

  // ---------- 米游社任务开关 ----------
  /// 游戏社区签到（luna：原石/星琼等奖励），独立于社区签到
  static bool get mhyGameSign => _p.getBool('mhy.gameSign') ?? true;
  static set mhyGameSign(bool v) => _p.setBool('mhy.gameSign', v);
  static bool get mhySign => _p.getBool('mhy.sign') ?? true;
  static set mhySign(bool v) => _p.setBool('mhy.sign', v);
  static bool get mhyRead => _p.getBool('mhy.read') ?? true;
  static set mhyRead(bool v) => _p.setBool('mhy.read', v);
  static bool get mhyLike => _p.getBool('mhy.like') ?? true;
  static set mhyLike(bool v) => _p.setBool('mhy.like', v);
  static bool get mhyShare => _p.getBool('mhy.share') ?? true;
  static set mhyShare(bool v) => _p.setBool('mhy.share', v);
  static bool get mhyCancelLike => _p.getBool('mhy.cancelLike') ?? true;
  static set mhyCancelLike(bool v) => _p.setBool('mhy.cancelLike', v);
  static String get mhyForums =>
      _p.getString('mhy.forums') ?? '5,2'; // gids：大别野/原神（MiyoQian 默认）
  static set mhyForums(String v) => _p.setString('mhy.forums', v);
  /// 游戏签到（luna）启用的游戏，逗号分隔：
  /// genshin/starrail/zzz/honkai3rd/tears/honkai2
  static String get mhySignGames =>
      _p.getString('mhy.signGames') ?? 'genshin,starrail,zzz';
  static set mhySignGames(String v) => _p.setString('mhy.signGames', v);

  // ---------- Bing ----------
  // 搜索词/次数/间隔的设置项已移除：词用内置二字词库（core/cn_words.dart），
  // 次数与节奏固定在 bing_webview_page.dart 内
  static bool get bingAutoStart =>
      _p.getBool('bing.autoStart') ?? true; // WebView 打开后自动点“开始自动搜索”
  static set bingAutoStart(bool v) => _p.setBool('bing.autoStart', v);

  // ---------- 用户自定义脚本 ----------
  static String? get customUserscript => _p.getString('bing.customScript');
  static set customUserscript(String? v) =>
      v == null ? _p.remove('bing.customScript') : _p.setString('bing.customScript', v);

  // ---------- 敏感数据命名空间 ----------
  // key 约定：
  //   sec.mhy.cookie / sec.mhy.stoken / sec.mhy.stuid / sec.mhy.mid
  //   sec.wb.token / sec.wb.uid / sec.wb.domain / sec.wb.enterpriseId
  static String? secret(String key) => _p.getString('sec.$key');
  static Future<void> setSecret(String key, String? value) async {
    final k = 'sec.$key';
    if (value == null || value.isEmpty) {
      await _p.remove(k);
    } else {
      await _p.setString(k, value);
    }
  }

  // ============================================================
  // 配置文件导出 / 导入
  // ============================================================

  static Map<String, Object?> dumpAll() =>
      _p.getKeys().fold<Map<String, Object?>>({}, (m, k) {
        final v = _p.get(k);
        if (v != null) m[k] = v;
        return m;
      });

  static String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(dumpAll());

  /// 导入另一个客户端导出的配置（只合并，不删除本机已有键）。
  /// 返回写入的键数量。
  static Future<int> importJson(String jsonStr) async {
    final map = jsonDecode(jsonStr);
    if (map is! Map<String, dynamic>) {
      throw const FormatException('配置文件格式错误：根节点必须是 JSON 对象');
    }
    var count = 0;
    for (final e in map.entries) {
      final v = e.value;
      if (v is bool) {
        await _p.setBool(e.key, v);
      } else if (v is int) {
        await _p.setInt(e.key, v);
      } else if (v is double) {
        await _p.setDouble(e.key, v);
      } else if (v is String) {
        await _p.setString(e.key, v);
      } else {
        continue;
      }
      count++;
    }
    return count;
  }
}
