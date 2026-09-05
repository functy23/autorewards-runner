/// WorkBuddy（原 CodeBuddy）每日积分领取模块。
///
/// 逆向来源：workbuddy-checkin-main（checkin.sh / decrypt-token.js / SKILL.md）
/// 完整分析见 docs/REVERSE_REPORT.md 第 3 节。
///
/// 结论摘要：
/// - 签到接口：POST https://copilot.tencent.com/billing/meter/daily-checkin
///             POST https://copilot.tencent.com/billing/meter/checkin-status
///   鉴权：Authorization: Bearer `accessToken`，body 为空 JSON `{}`，无额外签名。
///   幂等：已签到返回 HTTP 400 + code=10001，视为成功。
/// - 登录态（accessToken）在本机明文文件（v5.3.8+）：
///     macOS:   ~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
///     Windows: %LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info
///     Linux:   ~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info
///   JSON 结构：{ "auth": { "accessToken": "...", "domain": "..." },
///                "account": { "uid": ..., "enterpriseId": ... }, ... }
/// - 旧版（v5.3.8 之前）登录态在 Electron safeStorage 加密的 state.vscdb 里，
///   需要钥匙串授权解密，App 内不做（指引见 README）。
///
/// 平台说明：
/// - macOS App 沙盒下读取该文件需用户通过 open/close 面板授权一次（security-scoped
///   bookmark），或关闭沙盒（本项目默认关闭沙盒以简化，见 macOS entitlements）。
/// - Android 上不存在 WorkBuddy 桌面端本地文件 —— 在 Android 端由用户手动粘贴
///   token（从桌面端复制），或扫码传入。
library;

import 'dart:convert';
import 'dart:io';
import '../../core/app_log.dart';
import '../../core/app_prefs.dart';
import '../../core/http_box.dart';

class WorkBuddyResult {
  final bool ok;
  final String summary;
  final List<String> steps;
  WorkBuddyResult(this.ok, this.summary, this.steps);
  @override
  String toString() => summary;
}

class WorkBuddyService {
  static const apiBase = 'https://copilot.tencent.com';

  final HttpBox _http = HttpBox(retries: 1);

  // ============================================================
  // 登录态获取
  // ============================================================

  /// macOS：尝试从默认路径读取 WorkBuddy 桌面端明文登录态。
  /// 返回 null 表示文件不存在或结构不符。
  static ({String token, String uid, String domain, String enterpriseId})?
      readLocalAuthMacos() {
    final candidates = <String>[
      '${Platform.environment['HOME']}/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info',
      // 兼容更早命名的 CodeBuddy 时期
      '${Platform.environment['HOME']}/Library/Application Support/CodeBuddyExtension/Data/Public/auth/codebuddy-desktop.info',
    ];
    for (final path in candidates) {
      final f = File(path);
      if (!f.existsSync()) continue;
      try {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final auth = j['auth'] as Map<String, dynamic>?;
        final token = auth?['accessToken'] as String?;
        if (token == null || token.isEmpty) continue;
        final acct = j['account'] as Map<String, dynamic>?;
        return (
          token: token,
          uid: acct?['uid']?.toString() ?? '',
          domain: auth?['domain']?.toString() ?? '',
          enterpriseId: acct?['enterpriseId']?.toString() ?? '',
        );
      } catch (e) {
        AppLog.w('WB', '解析 $path 失败: $e');
      }
    }
    return null;
  }

  /// 手动导入（Android / 或 macOS 文件读取失败时）。
  Future<void> importToken(String token,
      {String uid = '', String domain = '', String enterpriseId = ''}) async {
    await AppPrefs.setSecret('wb.token', token.trim());
    await AppPrefs.setSecret('wb.uid', uid);
    await AppPrefs.setSecret('wb.domain', domain);
    await AppPrefs.setSecret('wb.enterpriseId', enterpriseId);
    AppLog.i('WB', 'token 手动导入成功 (uid=$uid)');
  }

  Future<String?> _token() async {
    final saved = AppPrefs.secret('wb.token');
    if (saved != null && saved.isNotEmpty) return saved;
    if (Platform.isMacOS) {
      final local = readLocalAuthMacos();
      if (local != null) {
        await importToken(local.token,
            uid: local.uid,
            domain: local.domain,
            enterpriseId: local.enterpriseId);
        return local.token;
      }
    }
    return null;
  }

  Future<bool> hasToken() async {
    final t = await _token();
    return t != null && t.isNotEmpty;
  }

  /// 查询今日真实签到状态（checkin-status 接口）。
  /// 返回 null = 未配置/查询失败。
  Future<bool?> checkStatus() async {
    final token = await _token();
    if (token == null || token.isEmpty) return null;
    final st = await _http.post('$apiBase/billing/meter/checkin-status',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        bodyRaw: '{}');
    if (st.status == 401 || st.status == 403 || !st.ok) return null;
    try {
      return st.json['data']?['today_checked_in'] == true;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // 签到
  // ============================================================

  Future<WorkBuddyResult> checkin() async {
    final steps = <String>[];
    final token = await _token();
    if (token == null || token.isEmpty) {
      return WorkBuddyResult(false, 'WorkBuddy 未配置 token',
          ['macOS 请先登录 WorkBuddy 桌面端，或手动粘贴 accessToken']);
    }

    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };

    // 1. 查询状态（只用于省一次请求 + 401 探测；幂等兜底在 checkin 的 10001）
    final st = await _http.post('$apiBase/billing/meter/checkin-status',
        headers: headers, bodyRaw: '{}');
    if (st.status == 401 || st.status == 403) {
      return WorkBuddyResult(false, 'token 已过期（HTTP ${st.status}）',
          [...steps, '请打开 WorkBuddy 桌面端刷新登录态后重试']);
    }
    if (st.ok) {
      try {
        final j = st.json;
        final checked = j['data']?['today_checked_in'];
        // 注意：v5.3.8 实测 today_checked_in 不可靠，仅作快速短路
        if (checked == true) {
          steps.add('今日已签到（状态接口返回），无需重复领取');
          return WorkBuddyResult(true, 'WorkBuddy 今日已签到', steps);
        }
      } catch (_) {}
    } else {
      steps.add('状态查询 HTTP ${st.status}（继续尝试签到）');
    }

    // 2. 签到
    final ms = 800 + DateTime.now().millisecond % 900;
    await Future.delayed(Duration(milliseconds: ms));
    final r = await _http.post('$apiBase/billing/meter/daily-checkin',
        headers: headers, bodyRaw: '{}');
    if (r.status == 401 || r.status == 403) {
      return WorkBuddyResult(false, 'token 已过期（HTTP ${r.status}）', steps);
    }

    // 3. 解析结果（HTTP 400 + code=10001 = 今日已签到，是官方幂等拒绝）
    try {
      final j = r.json;
      final code = j['code'];
      if (code == 0) {
        final data = j['data'] as Map<String, dynamic>?;
        final credit = data?['credit'];
        final streak = data?['streak_days'];
        steps.add('🎉 领取成功 credit=$credit, streak_days=$streak');
        return WorkBuddyResult(true, 'WorkBuddy 签到成功（+$credit 积分）', steps);
      } else if (code == 10001) {
        steps.add('今日已签到（code=10001），无需重复领取');
        return WorkBuddyResult(true, 'WorkBuddy 今日已签到', steps);
      } else {
        steps.add('签到失败 code=$code msg=${j['msg'] ?? j['message']}');
        return WorkBuddyResult(false, 'WorkBuddy 签到失败 code=$code', steps);
      }
    } catch (e) {
      steps.add('响应解析失败 HTTP ${r.status}: ${r.body.substring(0, r.body.length.clamp(0, 200))}');
      return WorkBuddyResult(false, 'WorkBuddy 响应异常', steps);
    }
  }
}
