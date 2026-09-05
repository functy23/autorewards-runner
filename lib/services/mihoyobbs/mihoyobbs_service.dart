/// 米游社（miyoushe / 米游币）自动任务模块。
///
/// 逆向来源：MihoyoBBSTools-master（setting.py / tools.py / login.py / mihoyobbs.py）
/// 完整抓包分析见 docs/REVERSE_REPORT.md 第 2 节。
///
/// 登录态（三选一，自动识别）：
///   A. stoken：cookie 串里含 `stoken=...`（v1/v2）→ 直接作为 App 登录态（推荐）
///   B. login_ticket：有效期约 30 分钟，可换取 stoken（v1）
///   C. 普通 cookie（cookie_token）：仅支持任务查询接口，无法 App 签到
library;

import 'dart:convert';
import 'dart:math';
import '../../core/app_log.dart';
import '../../core/app_prefs.dart';
import '../../core/http_box.dart';
import '../../crypto/uuid_v3.dart';
import '../../crypto/md5.dart';
import 'ds_sign.dart';
class MhyResult {
  final bool ok;
  final String summary;
  final List<String> steps;
  MhyResult(this.ok, this.summary, this.steps);

  @override
  String toString() => summary;
}

class MihoyoBbsService {
  static const bbsApi = 'https://bbs-api.miyoushe.com';
  static const webApi = 'https://api-takumi.mihoyo.com';
  static const passportApi = 'https://passport-api.mihoyo.com';

  static const appVersion = '2.109.0';
  static const clientTypeAndroid = '2';
  static const clientTypeWeb = '5';
  static const verifyKey = 'bll8iq97cem8';

  // 分区对照（MihoyoBBSTools setting.py）：签到接口用 gids（游戏 id），
  // 帖子接口用 forum_id，两者数值不同——实测 forum_id=2 是空分区（2026-09），
  // 原神帖子分区是 26。旧配置里混写的 id 两侧都做归一化。
  static const gidsToForumId = {
    '1': '1', // 崩坏3
    '2': '26', // 原神
    '3': '30', // 崩坏2
    '4': '37', // 未定事件簿
    '5': '34', // 大别野
    '6': '52', // 星穹铁道
    '8': '57', // 绝区零
  };
  static const forumIdToGids = {
    '1': '1', '26': '2', '30': '3', '37': '4',
    '34': '5', '52': '6', '57': '8',
  };

  final HttpBox _http = HttpBox(retries: 1);

  static final Random _rng = Random();

  // 登录态
  String _stoken = '';
  String _stuid = '';
  String _mid = '';
  String _cookie = ''; // 完整用户 cookie（任务查询用 web 登录态）
  String _deviceId = '';
  String _deviceFp = '';

  // ============================================================
  // 登录态解析
  // ============================================================

  /// 从用户粘贴的 cookie 串解析登录态，并做一次活体验证。
  /// 支持：stoken（推荐）/ login_ticket（自动换 stoken）/ 纯 cookie。
  Future<MhyResult> importCookie(String rawCookie) async {
    final steps = <String>[];
    final tidy = rawCookie
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join('; ');
    _cookie = tidy;

    String? stoken = _extract(tidy, 'stoken');
    final stuid = _extract(tidy, 'stuid') ?? _extract(tidy, 'ltuid') ?? _extract(tidy, 'account_id');
    String? mid = _extract(tidy, 'mid') ?? _extract(tidy, 'account_mid_v2') ?? _extract(tidy, 'ltmid_v2');
    final loginTicket = _extract(tidy, 'login_ticket');

    // B. login_ticket → 换 stoken（v1）
    if ((stoken == null || stoken.isEmpty) && loginTicket != null && stuid != null) {
      steps.add('检测到 login_ticket，尝试换取 stoken…');
      final r = await _getStokenByLoginTicket(loginTicket, stuid);
      if (r != null) {
        stoken = r;
        steps.add('stoken 获取成功');
      } else {
        steps.add('login_ticket 已失效（有效期约 30 分钟）');
      }
    }

    if (stoken != null && stoken.isNotEmpty) {
      _stoken = stoken;
      _stuid = stuid ?? '';
      _mid = mid ?? '';
      if (_stoken.startsWith('v2_') && _mid.isEmpty) {
        // v2 stoken 的 bbs 任务接口必须带 mid（cookie 里没有时任务会失败）
        steps.add('⚠️ stoken 为 v2 但 cookie 里没有 mid，任务接口可能不可用');
      }
      // 生成稳定 device_id（uuid3(cookie)）
      _deviceId = UuidV3.fromString(_stoken + _stuid);
      _deviceFp = Md5Like.fingerprint(_deviceId); // 伪 device_fp（41 位 hex）

      final ok = await verifyStoken();
      if (ok) {
        await AppPrefs.setSecret('mhy.cookie', tidy);
        await AppPrefs.setSecret('mhy.stoken', _stoken);
        await AppPrefs.setSecret('mhy.stuid', _stuid);
        await AppPrefs.setSecret('mhy.mid', _mid);
        AppLog.i('MHY', 'stoken 导入成功 (uid=$_stuid)');
        steps.add('✅ stoken 验证通过，登录态已保存到本机');
        return MhyResult(true, '米游社登录态导入成功', steps);
      }
      steps.add('❌ stoken 验证失败（可能已过期）');
      _stoken = '';
    }

    // C. 退回纯 cookie 模式（能查询任务，但签到/看帖等任务接口需要 stoken）
    if (tidy.contains('cookie_token') || tidy.contains('account_id')) {
      await AppPrefs.setSecret('mhy.cookie', tidy);
      final ok = await verifyWebCookie();
      if (ok) {
        steps.add('✅ web cookie 可用（仅任务状态查询）');
        steps.add('⚠️ 签到/看帖等任务需要 stoken —— 请用「扫码登录」重新登录');
        return MhyResult(true, '米游社 web cookie 导入成功（无 stoken，任务需扫码登录）', steps);
      }
    }

    return MhyResult(false, '米游社登录态导入失败', steps);
  }

  Future<void> loadSaved() async {
    _cookie = AppPrefs.secret('mhy.cookie') ?? '';
    _stoken = AppPrefs.secret('mhy.stoken') ?? '';
    _stuid = AppPrefs.secret('mhy.stuid') ?? '';
    _mid = AppPrefs.secret('mhy.mid') ?? '';
    if (_stoken.isNotEmpty) {
      _deviceId = UuidV3.fromString(_stoken + _stuid);
      _deviceFp = Md5Like.fingerprint(_deviceId);
    }
  }

  bool get hasLogin =>
      _stoken.isNotEmpty ||
      (_cookie.contains('cookie_token') && _cookie.contains('account_id'));

  static String? _extract(String cookie, String key) {
    final m = RegExp('$key=([^;]+)').firstMatch(cookie);
    return m?.group(1);
  }

  // ============================================================
  // 登录态兑换 / 验证
  // ============================================================

  /// login_ticket 换 stoken（token_types=3 → stoken v1，有效期约 30 分钟内有效）
  Future<String?> _getStokenByLoginTicket(String ticket, String uid) async {
    final url = '$webApi/auth/api/getMultiTokenByLoginTicket'
        '?login_ticket=$ticket&token_types=3&uid=$uid';
    final r = await _http.get(url, headers: _baseWebHeaders());
    final j = r.jsonSafe;
    if (j['retcode'] == 0) {
      final list = j['data']?['list'] as List?;
      if (list != null && list.isNotEmpty) {
        return list[0]['token'] as String?;
      }
    }
    AppLog.w('MHY', 'getMultiTokenByLoginTicket: ${j['message']}');
    return null;
  }

  /// stoken 活体验证 + 刷新 web cookie_token。
  ///
  /// 用老接口 auth/api/getCookieAccountInfoBySToken（api-takumi，GET），
  /// 不用 ma-cn-session/app/getTokenBySToken——后者对非官方设备指纹有风控，
  /// 连扫码刚签发的全新 stoken 也会 -5300「请升级应用版本」拒绝（2026-09-05
  /// 实测，穷举头组合无效），而老接口直接通过。成功即 stoken 有效，顺带把
  /// 返回的 cookie_token 合入 _cookie 并持久化（任务状态查询依赖它）。
  Future<bool> verifyStoken() async {
    if (_stoken.isEmpty) return false;
    final url = '$webApi/auth/api/getCookieAccountInfoBySToken';
    final r = await _http.get(url, headers: {
      'User-Agent': 'okhttp/4.9.3',
      'x-rpc-client_type': clientTypeAndroid,
      'x-rpc-app_version': appVersion,
      'DS': DsSign.ds1(),
      'Cookie': _stokenCookie(),
      'Referer': 'https://app.mihoyo.com',
    });
    final j = r.jsonSafe;
    final ok = j['retcode'] == 0;
    if (!ok) {
      AppLog.e('MHY', 'getCookieAccountInfoBySToken 失败: retcode=${j['retcode']} ${j['message']}');
      return false;
    }
    final ct = j['data']?['cookie_token']?.toString();
    if (ct != null && ct.isNotEmpty) {
      if (_cookie.contains('cookie_token=')) {
        _cookie = _cookie.replaceFirst(RegExp('cookie_token=[^;]*'), 'cookie_token=$ct');
      } else {
        _cookie = _cookie.isEmpty ? 'cookie_token=$ct' : '$_cookie; cookie_token=$ct';
      }
      await AppPrefs.setSecret('mhy.cookie', _cookie);
    }
    return true;
  }

  Future<bool> verifyWebCookie() async {
    final r = await _http.get(
      '$webApi/binding/api/getUserGameRolesByCookie',
      headers: {'Cookie': _cookie, 'User-Agent': HttpBox.uaMobileChrome},
    );
    return r.jsonSafe['retcode'] == 0;
  }

  /// 查询今日任务真实完成状态：can_get_points == 0 即全部完成。
  /// 返回 null = 未配置/查询失败。
  Future<bool?> tasksAllDone() async {
    await loadSaved();
    if (!hasLogin) return null;
    final r = await _http.get(
      '$bbsApi/apihub/wapi/getUserMissionsState?point_sn=myb',
      headers: {..._baseWebHeaders(), 'Cookie': _cookie},
    );
    final j = r.jsonSafe;
    if (j['retcode'] != 0) return null;
    return ((j['data']?['can_get_points'] as num?)?.toInt() ?? 1) == 0;
  }

  // ============================================================
  // Headers
  // ============================================================

  Map<String, String> _baseWebHeaders() => {
        'User-Agent': HttpBox.uaMobileChrome,
        'Accept': 'application/json, text/plain, */*',
        'x-rpc-app_version': appVersion,
        'x-rpc-client_type': clientTypeWeb,
        'x-rpc-channel': 'miyousheluodi',
        'Accept-Language': 'zh-CN,en-US;q=0.8',
        'Origin': 'https://webstatic.mihoyo.com',
        'Referer': 'https://webstatic.mihoyo.com/',
        'X-Requested-With': 'com.mihoyo.hyperion',
      };

  String _stokenCookie() {
    final sb = StringBuffer('stuid=$_stuid;stoken=$_stoken');
    if (_stoken.startsWith('v2_') && _mid.isNotEmpty) sb.write(';mid=$_mid');
    return sb.toString();
  }

  // ============================================================
  // 任务主流程（MiyoQian 移植：游戏签到 luna + 米游币社区任务）
  // ============================================================

  /// 米游签（MiyoQian）接口常量：游戏签到走 luna 系列接口（act_id 维度，
  /// 奖励为原石/星琼等），按 game_biz 拉绑定角色逐个签到；验证码不接打码
  /// 平台，触发即跳过并留痕。
  static const takumiApi = 'https://api-takumi.mihoyo.com';
  static const zzzActApi = 'https://act-nap-api.mihoyo.com';

  static const _miyoUa =
      'Mozilla/5.0 (Linux; Android 12; Unspecified Device) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
      'Chrome/103.0.5060.129 Mobile Safari/537.36 miHoYoBBS/2.106.2';

  static const _games = {
    'genshin': (
      name: '原神',
      gameBiz: 'hk4e_cn',
      actId: 'e202311201442471',
      zzz: false,
      signGame: 'hk4e',
    ),
    'starrail': (
      name: '崩坏：星穹铁道',
      gameBiz: 'hkrpg_cn',
      actId: 'e202304121516551',
      zzz: false,
      signGame: '',
    ),
    'zzz': (
      name: '绝区零',
      gameBiz: 'nap_cn',
      actId: 'e202406242138391',
      zzz: true,
      signGame: 'zzz',
    ),
    'honkai3rd': (
      name: '崩坏3',
      gameBiz: 'bh3_cn',
      actId: 'e202306201626331',
      zzz: false,
      signGame: '',
    ),
    'tears': (
      name: '未定事件簿',
      gameBiz: 'nxx_cn',
      actId: 'e202202251749321',
      zzz: false,
      signGame: '',
    ),
    'honkai2': (
      name: '崩坏学园2',
      gameBiz: 'bh2_cn',
      actId: 'e202203291431091',
      zzz: false,
      signGame: '',
    ),
  };

  /// gids → (id, forum_id, name)，与 MiyoQian BBS_FORUMS 一致
  static const _forums = {
    '1': (id: '1', forumId: '1', name: '崩坏3'),
    '2': (id: '2', forumId: '26', name: '原神'),
    '3': (id: '3', forumId: '30', name: '崩坏2'),
    '4': (id: '4', forumId: '37', name: '未定事件簿'),
    '5': (id: '5', forumId: '34', name: '大别野'),
    '6': (id: '6', forumId: '52', name: '崩坏：星穹铁道'),
    '8': (id: '8', forumId: '57', name: '绝区零'),
  };

  /// MiyoQian 风格 app/bbs 通道头（BBS 2.106.2 salt 配对，米游币任务用）
  Map<String, String> _miyoAppHeaders({String ds = ''}) => {
        'DS': ds,
        'Cookie': _stokenCookie(),
        'x-rpc-client_type': '2',
        'x-rpc-app_version': DsSign.bbsVersionV206,
        'x-rpc-sys_version': '12',
        'x-rpc-channel': 'miyousheluodi',
        'x-rpc-device_id': _deviceId,
        'x-rpc-device_name': 'Xiaomi MI 6',
        'x-rpc-device_model': 'Mi 6',
        'x-rpc-h265_supported': '1',
        'Referer': 'https://app.mihoyo.com',
        'Content-Type': 'application/json; charset=UTF-8',
        'x-rpc-verify_key': verifyKey,
        'x-rpc-csm_source': 'home',
        'User-Agent': 'okhttp/4.9.3',
        if (_deviceFp.isNotEmpty) 'x-rpc-device_fp': _deviceFp,
      };

  /// MiyoQian 风格 web 通道头。gameSign=true 时带 luna 签到全套
  /// （web DS + client_type 5 + act.mihoyo.com 来源），否则为裸 web 头
  /// （任务状态/分享不需要 DS）
  Map<String, String> _miyoWebHeaders({
    bool gameSign = false,
    String signGame = '',
  }) =>
      {
        'Accept': 'application/json, text/plain, */*',
        if (gameSign) 'DS': DsSign.ds1(salt: DsSign.saltBbsWebV206),
        if (gameSign) 'x-rpc-channel': 'miyousheluodi',
        if (gameSign) 'Origin': 'https://act.mihoyo.com',
        if (gameSign) 'x-rpc-app_version': DsSign.bbsVersionV206,
        if (gameSign) 'x-rpc-client_type': '5',
        if (gameSign) 'X-Requested-With': 'com.mihoyo.hyperion',
        'User-Agent': _miyoUa,
        if (gameSign) 'Referer': 'https://act.mihoyo.com/',
        if (gameSign) 'Accept-Language': 'zh-CN,en-US;q=0.8',
        if (signGame.isNotEmpty) 'x-rpc-signgame': signGame,
        'Cookie': _cookie,
        if (gameSign) 'x-rpc-device_id': _deviceId,
      };

  /// 完整跑一遍米游社任务：游戏签到（luna，原石/星琼等奖励）
  /// + 米游币社区任务（社区签到/看帖/点赞/分享领米游币）
  Future<MhyResult> runAll() async {
    final steps = <String>[];
    await loadSaved();
    if (!hasLogin) {
      return MhyResult(false, '米游社未配置登录态', ['请先在账号页导入 cookie']);
    }

    try {
      if (_stoken.isEmpty) {
        steps.add('⚠️ 当前登录态没有 stoken（网页登录仅支持状态查询）');
        steps.add('请到「账号」页用「扫码登录」重新登录后再执行任务');
        return MhyResult(false, '米游社任务需要 stoken（扫码登录）', steps);
      }

      // 1. 游戏社区签到（luna）
      if (AppPrefs.mhyGameSign) {
        await _gameSign(steps);
      } else {
        steps.add('游戏签到未启用，跳过');
      }

      // 2. 米游币社区任务
      await _bbsTasks(steps);

      steps.add('✅ 米游社任务流程结束');
      return MhyResult(true, '米游社任务完成', steps);
    } catch (e, st) {
      AppLog.e('MHY', 'runAll 异常: $e\n$st');
      return MhyResult(false, '米游社任务异常: $e', steps);
    }
  }

  Future<void> _humanDelay(int a, int b) async {
    await Future.delayed(Duration(seconds: a + _rng.nextInt(b - a + 1)));
  }

  String _short(String s) => s.length > 18 ? '${s.substring(0, 18)}…' : s;

  // ---- 游戏社区签到（luna，MiyoQian GameCheckin 移植）----

  Future<void> _gameSign(List<String> steps) async {
    final enabled = AppPrefs.mhySignGames
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (enabled.isEmpty) {
      steps.add('未配置任何游戏，跳过游戏签到');
      return;
    }
    for (final key in enabled) {
      final g = _games[key];
      if (g == null) {
        steps.add('[跳过] 未知游戏配置: $key');
        continue;
      }
      steps.add('== ${g.name} ==');
      steps.add('正在获取${g.name}绑定角色');
      final roles = await _gameRoles(g);
      if (roles.isEmpty) {
        steps.add('${g.name}: 未找到绑定角色');
        continue;
      }
      final awards = await _gameAwards(g);
      for (final role in roles) {
        if (role is! Map) continue;
        final uid = role['game_uid']?.toString() ?? '';
        final nickname = role['nickname']?.toString() ?? uid;
        final label = '${g.name} $nickname($uid)';
        final info = await _gameInfo(g, role);
        if (info.isEmpty) {
          steps.add('$label 签到状态查询失败');
          continue;
        }
        if (info['first_bind'] == true) {
          steps.add('$label 首次绑定，请先手动签到一次');
          continue;
        }
        final signed = info['is_sign'] == true;
        final dayIndex =
            max(((int.tryParse('${info['total_sign_day']}') ?? 1) - 1), 0);
        if (signed) {
          steps.add('$label 今日已签到，奖励 ${_describeAward(awards, dayIndex)}');
          continue;
        }
        final r = await _gameSignRequest(g, role);
        if (r['retcode'] == -5003) {
          steps.add('$label 今日已签到，奖励 ${_describeAward(awards, dayIndex)}');
          continue;
        }
        if (r['retcode'] != 0) {
          steps.add('$label 签到失败: ${r['message']}(${r['retcode']})');
          continue;
        }
        final data = (r['data'] as Map?) ?? {};
        if (data['success'] == 1) {
          steps.add('⚠️ $label 触发验证码，本次跳过');
          continue;
        }
        steps.add('$label 签到成功，奖励 ${_describeAward(awards, dayIndex + 1)}');
        await _humanDelay(1, 3);
      }
    }
  }

  /// 绑定角色（web cookie）；-100 时用 stoken 刷新 cookie_token 重试一次
  Future<List<dynamic>> _gameRoles(({String name, String gameBiz, String actId, bool zzz, String signGame}) g,
      {bool retried = false}) async {
    final r = await _http.get(
      '$takumiApi/binding/api/getUserGameRolesByCookie?game_biz=${g.gameBiz}',
      headers: _miyoWebHeaders(gameSign: true, signGame: g.signGame),
    );
    final j = r.jsonSafe;
    if (j['retcode'] == -100 && !retried) {
      if (await _refreshCookieToken()) {
        return _gameRoles(g, retried: true);
      }
    }
    final list = j['data']?['list'];
    return list is List ? list : [];
  }

  Future<List<dynamic>> _gameAwards(
      ({String name, String gameBiz, String actId, bool zzz, String signGame}) g) async {
    final base = g.zzz ? '$zzzActApi/event/luna/zzz/home' : '$takumiApi/event/luna/home';
    final r = await _http.get('$base?lang=zh-cn&act_id=${g.actId}',
        headers: _miyoWebHeaders(gameSign: true, signGame: g.signGame));
    final list = r.jsonSafe['data']?['awards'];
    return list is List ? list : [];
  }

  Future<Map<String, dynamic>> _gameInfo(
      ({String name, String gameBiz, String actId, bool zzz, String signGame}) g,
      Map role) async {
    final base = g.zzz ? '$zzzActApi/event/luna/zzz/info' : '$takumiApi/event/luna/info';
    final r = await _http.get(
      '$base?lang=zh-cn&act_id=${g.actId}'
      '&region=${Uri.encodeComponent('${role['region'] ?? ''}')}'
      '&uid=${Uri.encodeComponent('${role['game_uid'] ?? ''}')}',
      headers: _miyoWebHeaders(gameSign: true, signGame: g.signGame),
    );
    final j = r.jsonSafe;
    final d = j['data'];
    if (j['retcode'] == 0 && d is Map) {
      return Map<String, dynamic>.from(d);
    }
    return {};
  }

  Future<Map<String, dynamic>> _gameSignRequest(
      ({String name, String gameBiz, String actId, bool zzz, String signGame}) g,
      Map role) async {
    final base = g.zzz ? '$zzzActApi/event/luna/zzz/sign' : '$takumiApi/event/luna/sign';
    final body = jsonEncode({
      'act_id': g.actId,
      'region': role['region'],
      'uid': role['game_uid'],
    });
    final r = await _http.post(base,
        headers: _miyoWebHeaders(gameSign: true, signGame: g.signGame),
        bodyRaw: body);
    return r.jsonSafe;
  }

  String _describeAward(List<dynamic> awards, int index) {
    if (awards.isEmpty) return '未知';
    final i = index.clamp(0, awards.length - 1);
    final a = awards[i];
    if (a is! Map) return '未知';
    return '「${a['name'] ?? '未知'}」x${a['cnt'] ?? '?'}';
  }

  // ---- 米游币社区任务（MiyoQian BbsTasks 移植）----

  Future<void> _bbsTasks(List<String> steps) async {
    steps.add('== 米游币社区任务 ==');
    steps.add('正在获取米游币任务状态');
    var state = await _taskState();
    if (state.isEmpty) {
      steps.add('任务状态获取失败，请检查 cookie/stoken');
      return;
    }
    final canGet = (state['can_get_points'] as num?)?.toInt() ?? 0;
    final received = (state['already_received_points'] as num?)?.toInt() ?? 0;
    final total = (state['total_points'] as num?)?.toInt() ?? 0;
    final flags = _taskFlags(state);
    final possibleToday = received + canGet;
    steps.add(
        '米游币今日进度：已获得 $received，还可获得 $canGet，预计总共可获得 $possibleToday');
    if (canGet == 0) {
      steps.add('今日任务已完成，今日已得 $received，当前总计 $total');
      return;
    }

    if (AppPrefs.mhySign && !flags.sign) {
      await _communitySign(steps);
      await _humanDelay(1, 3);
    } else if (flags.sign) {
      steps.add('社区签到已完成，跳过');
    }

    final needsPosts = (AppPrefs.mhyRead && !flags.read) ||
        (AppPrefs.mhyLike && !flags.like) ||
        (AppPrefs.mhyShare && !flags.share);
    if (needsPosts) {
      steps.add('正在获取帖子列表');
      final posts = await _posts();
      if (posts.isEmpty) {
        steps.add('获取帖子列表失败，无法执行看帖/点赞/分享');
        return;
      }
      if (AppPrefs.mhyRead && !flags.read) {
        await _readPosts(posts.take(flags.readNum).toList(), steps);
      } else if (AppPrefs.mhyRead) {
        steps.add('看帖任务已完成，跳过');
      }
      if (AppPrefs.mhyLike && !flags.like) {
        await _likePosts(posts.take(flags.likeNum).toList(), steps);
      } else if (AppPrefs.mhyLike) {
        steps.add('点赞任务已完成，跳过');
      }
      if (AppPrefs.mhyShare && !flags.share) {
        await _sharePost(posts.first, steps);
      } else if (AppPrefs.mhyShare) {
        steps.add('分享任务已完成，跳过');
      }
    } else {
      if (AppPrefs.mhyRead && flags.read) steps.add('看帖任务已完成，跳过');
      if (AppPrefs.mhyLike && flags.like) steps.add('点赞任务已完成，跳过');
      if (AppPrefs.mhyShare && flags.share) steps.add('分享任务已完成，跳过');
    }

    final after = await _taskState();
    final s2 = after.isNotEmpty ? after : state;
    final finalReceived =
        (s2['already_received_points'] as num?)?.toInt() ?? received;
    final finalTotal = (s2['total_points'] as num?)?.toInt() ?? total;
    final gained = max(finalReceived - received, 0);
    steps.add('社区任务结束：今日已得 $finalReceived，'
        '还能获得 ${max(possibleToday - finalReceived, 0)}，当前总计 $finalTotal，本次新增 $gained');
  }

  /// 任务状态（web 头，无 DS）；-100 时刷新 cookie_token 重试一次
  Future<Map<String, dynamic>> _taskState({bool retried = false}) async {
    final r = await _http.get(
      '$bbsApi/apihub/wapi/getUserMissionsState?point_sn=myb',
      headers: _miyoWebHeaders(),
    );
    final j = r.jsonSafe;
    if (j['retcode'] == -100 && !retried) {
      if (await _refreshCookieToken()) return _taskState(retried: true);
    }
    final d = j['data'];
    return j['retcode'] == 0 && d is Map<String, dynamic> ? d : {};
  }

  /// mission 58/59/60/61 → 签到/看帖/点赞/分享完成态与剩余次数
  ({bool sign, bool read, int readNum, bool like, int likeNum, bool share})
      _taskFlags(Map<String, dynamic> state) {
    var sign = false, read = false, like = false, share = false;
    var readNum = 3, likeNum = 5;
    for (final m in (state['states'] as List?) ?? []) {
      if (m is! Map) continue;
      final done = m['is_get_award'] == true;
      final happened = (m['happened_times'] as num?)?.toInt() ?? 0;
      switch (m['mission_id']) {
        case 58:
          if (done) sign = true;
        case 59:
          if (done) {
            read = true;
          } else {
            readNum = max(readNum - happened, 0);
          }
        case 60:
          if (done) {
            like = true;
          } else {
            likeNum = max(likeNum - happened, 0);
          }
        case 61:
          if (done) share = true;
      }
    }
    return (
      sign: sign,
      read: read,
      readNum: readNum,
      like: like,
      likeNum: likeNum,
      share: share,
    );
  }

  /// 讨论区社区签到（apihub/app/api/signIn，DS2/X6 + stoken app 头）
  Future<void> _communitySign(List<String> steps) async {
    for (final v in _configuredGids()) {
      final forum = _forums[v];
      if (forum == null) continue;
      steps.add('正在进行${forum.name}社区签到');
      // MiyoQian 传 {"gids": forum["id"]}，id 为字符串 → 带引号
      final bodyStr = '{"gids":"${forum.id}"}';
      final headers = _miyoAppHeaders(ds: DsSign.ds2(bodyStr, query: ''));
      final r = await _http.post('$bbsApi/apihub/app/api/signIn',
          headers: headers, bodyRaw: bodyStr);
      final j = r.jsonSafe;
      if (j['retcode'] == 0) {
        steps.add('${forum.name} 社区签到成功');
      } else if (j['retcode'] == 1034) {
        steps.add('${forum.name} 社区签到触发验证码，已跳过');
      } else if (j['retcode'] == -100) {
        steps.add('登录态过期，社区签到终止');
        return;
      } else {
        steps.add('${forum.name} 社区签到失败: ${j['message']}');
      }
      await _humanDelay(1, 3);
    }
  }

  List<String> _configuredGids() {
    final out = <String>[];
    for (final v in AppPrefs.mhyForums
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)) {
      final gid = forumIdToGids[v] ?? v; // 26→2；已是 gids 的原样保留
      if (_forums.containsKey(gid) && !out.contains(gid)) out.add(gid);
    }
    return out;
  }

  /// 候选帖子：第一个有效分区的列表（页大小 20），打乱后取前 5
  Future<List<_Post>> _posts() async {
    for (final gid in _configuredGids()) {
      final forum = _forums[gid];
      if (forum == null) continue;
      final r = await _http.get(
        '$bbsApi/post/api/getForumPostList'
        '?forum_id=${forum.forumId}&is_good=false&is_hot=false&page_size=20&sort_type=1',
        headers: _miyoAppHeaders(ds: DsSign.ds1(salt: DsSign.saltBbsV206)),
      );
      final j = r.jsonSafe;
      final list = j['data']?['list'] as List?;
      if (list == null || list.isEmpty) continue;
      final posts = <_Post>[];
      for (final item in list) {
        final post = item['post'];
        if (post is Map) {
          final id = post['post_id']?.toString() ?? '';
          final title = post['subject']?.toString() ?? '';
          if (id.isNotEmpty) posts.add(_Post(id: id, title: title, gids: gid));
        }
      }
      if (posts.isNotEmpty) {
        posts.shuffle(_rng);
        return posts.take(5).toList();
      }
    }
    return [];
  }

  Future<void> _readPosts(List<_Post> posts, List<String> steps) async {
    for (final p in posts) {
      steps.add('正在浏览: ${_short(p.title)}');
      final r = await _http.get(
        '$bbsApi/post/api/getPostFull?post_id=${p.id}',
        headers: _miyoAppHeaders(ds: DsSign.ds1(salt: DsSign.saltBbsV206)),
      );
      steps.add(r.jsonSafe['message'] == 'OK'
          ? '阅读成功: ${_short(p.title)}'
          : '阅读失败: ${_short(p.title)}');
      await _humanDelay(1, 3);
    }
  }

  Future<void> _likePosts(List<_Post> posts, List<String> steps) async {
    for (final p in posts) {
      steps.add('正在点赞: ${_short(p.title)}');
      final body =
          '{"post_id":"${p.id}","is_cancel":false,"gids":"${p.gids}"}';
      final r = await _http.post('$bbsApi/post/api/post/upvote',
          headers: _miyoAppHeaders(ds: DsSign.ds1(salt: DsSign.saltBbsV206)),
          bodyRaw: body);
      final j = r.jsonSafe;
      if (j['message'] == 'OK') {
        steps.add('点赞成功: ${_short(p.title)}');
        if (AppPrefs.mhyCancelLike) {
          await _humanDelay(1, 3);
          steps.add('正在取消点赞: ${_short(p.title)}');
          final bodyC =
              '{"post_id":"${p.id}","is_cancel":true,"gids":"${p.gids}"}';
          await _http.post('$bbsApi/post/api/post/upvote',
              headers:
                  _miyoAppHeaders(ds: DsSign.ds1(salt: DsSign.saltBbsV206)),
              bodyRaw: bodyC);
        }
      } else if (j['retcode'] == 1034) {
        steps.add('点赞触发验证码，已跳过: ${_short(p.title)}');
      } else {
        steps.add('点赞失败: ${_short(p.title)} (${j['message']})');
      }
      await _humanDelay(1, 3);
    }
  }

  Future<void> _sharePost(_Post p, List<String> steps) async {
    steps.add('正在分享: ${_short(p.title)}');
    var r = await _http.get(
      '$bbsApi/apihub/api/getShareConf?entity_id=${p.id}&entity_type=1',
      headers: _miyoWebHeaders(),
    );
    // 实测 web 裸头可能 403（非 JSON 响应）：退避一次用 app 通道（stoken+DS）
    if (r.jsonSafe['message'] != 'OK') {
      await _humanDelay(1, 2);
      r = await _http.get(
        '$bbsApi/apihub/api/getShareConf?entity_id=${p.id}&entity_type=1',
        headers: _miyoAppHeaders(ds: DsSign.ds1(salt: DsSign.saltBbsV206)),
      );
    }
    steps.add(r.jsonSafe['message'] == 'OK'
        ? '分享成功: ${_short(p.title)}'
        : '分享失败: ${_short(p.title)} (${r.jsonSafe['message']})');
  }

  /// stoken 刷新 web cookie_token（getCookieAccountInfoBySToken 老接口，
  /// 无需 DS）；成功即更新 _cookie 并持久化
  Future<bool> _refreshCookieToken() async {
    try {
      final r = await _http.get(
        '$takumiApi/auth/api/getCookieAccountInfoBySToken',
        headers: {'Cookie': _stokenCookie(), 'User-Agent': _miyoUa},
      );
      final j = r.jsonSafe;
      if (j['retcode'] != 0) return false;
      final ct = j['data']?['cookie_token']?.toString() ?? '';
      if (ct.isEmpty) return false;
      if (_cookie.contains('cookie_token=')) {
        _cookie =
            _cookie.replaceFirst(RegExp('cookie_token=[^;]*'), 'cookie_token=$ct');
      } else {
        _cookie = _cookie.isEmpty ? 'cookie_token=$ct' : '$_cookie; cookie_token=$ct';
      }
      await AppPrefs.setSecret('mhy.cookie', _cookie);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // 扫码登录（passport QR Login，实测逆向自米游社登录流程 2026-09）
  // createQRLogin → 用户在米游社 App/网页 扫码确认 → queryQRLoginStatus 轮询
  // Confirmed 后 tokens 填充（token_type=1 即 stoken v2）+ user_info(aid/mid)
  // ============================================================

  static String _randomUuid4() {
    const hex = '0123456789abcdef';
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      if (i == 8 || i == 12 || i == 16 || i == 20) sb.write('-');
      if (i == 12) {
        sb.write('4');
        continue;
      }
      if (i == 16) {
        sb.write(hex[8 + _rng.nextInt(4)]);
        continue;
      }
      sb.write(hex[_rng.nextInt(16)]);
    }
    return sb.toString();
  }

  Map<String, String> _qrHeaders(String deviceId) => {
        'Content-Type': 'application/json; charset=UTF-8',
        'User-Agent': 'okhttp/4.9.3',
        'x-rpc-app_id': 'bll8iq97cem8', // 米游社 app_id
        'x-rpc-app_version': appVersion,
        'x-rpc-client_type': clientTypeAndroid,
        'x-rpc-device_id': deviceId,
        'x-rpc-sys_version': '12',
        'x-rpc-channel': 'miyousheluodi',
      };

  /// 创建扫码登录会话，返回二维码内容 URL
  Future<({String url, String ticket, String deviceId})?> createQrLogin() async {
    final deviceId = _randomUuid4();
    final r = await _http.post(
      '$passportApi/account/ma-cn-passport/app/createQRLogin',
      headers: _qrHeaders(deviceId),
      bodyRaw: '{}',
    );
    final j = r.jsonSafe;
    if (j['retcode'] != 0) {
      AppLog.e('MHY', 'createQRLogin 失败: ${j['retcode']} ${j['message']}');
      return null;
    }
    final data = j['data'] as Map<String, dynamic>?;
    final ticket = data?['ticket']?.toString();
    final url = data?['url']?.toString();
    if (ticket == null || url == null) {
      AppLog.e('MHY', 'createQRLogin 响应缺字段: ${j.keys.toList()}');
      return null;
    }
    return (url: url, ticket: ticket, deviceId: deviceId);
  }

  /// 轮询扫码状态。返回：Created / Scanned / Confirmed / Expired / Error:xxx
  /// Confirmed 时自动解析 stoken 并保存验证。
  Future<String> pollQrLoginStatus({
    required String ticket,
    required String deviceId,
  }) async {
    final r = await _http.post(
      '$passportApi/account/ma-cn-passport/app/queryQRLoginStatus?ticket=$ticket',
      headers: _qrHeaders(deviceId),
      bodyRaw: '{}',
    );
    final j = r.jsonSafe;
    if (j['retcode'] != 0) {
      // -3001 参数不合法 = ticket 失效/过期
      if (j['retcode'] == -3001 || j['retcode'] == -106) return 'Expired';
      return 'Error:${j['message'] ?? 'unknown'}';
    }
    final data = j['data'] as Map<String, dynamic>?;
    final status = data?['status']?.toString() ?? 'Created';
    if (status != 'Confirmed') return status;

    // Confirmed：提取 stoken（token_type=1）+ uid/mid
    final userInfo = data?['user_info'] as Map<String, dynamic>?;
    final tokens = (data?['tokens'] as List?) ?? const [];
    // 结构留痕（只记类型与长度，不记 token 值）便于诊断「拿不到 stoken」类问题
    final tokenShape = tokens
        .map((t) => t is Map
            ? 'type=${t['token_type']} len=${(t['token']?.toString() ?? '').length}'
            : '?')
        .join(', ');
    AppLog.i('MHY', 'QR Confirmed: tokens=[$tokenShape] aid=${userInfo?['aid']} mid=${userInfo?['mid']}');
    String? stoken;
    for (final t in tokens) {
      if (t is Map && t['token_type'] == 1) {
        stoken = t['token']?.toString();
        break;
      }
    }
    if (stoken == null || stoken.isEmpty) {
      AppLog.e('MHY', 'QR Confirmed 但未找到 stoken（tokens=$tokens）');
      return 'Error:未从确认结果中取到 stoken，请改用 Cookie 登录';
    }
    _stoken = stoken;
    _stuid = userInfo?['aid']?.toString() ?? '';
    _mid = userInfo?['mid']?.toString() ?? '';
    // 验证时沿用二维码会话的 device_id（签发与验证保持同一设备），
    // 验证通过后继续用它作为本机稳定设备 id（device_fp 由它派生）
    _deviceId = deviceId;
    _deviceFp = Md5Like.fingerprint(_deviceId);

    final ok = await verifyStoken();
    if (!ok) {
      return 'Error:stoken 验证未通过，请改用 Cookie 登录';
    }

    await AppPrefs.setSecret('mhy.stoken', _stoken);
    await AppPrefs.setSecret('mhy.stuid', _stuid);
    await AppPrefs.setSecret('mhy.mid', _mid);
    AppLog.i('MHY', '扫码登录成功 (uid=$_stuid)');
    return 'Confirmed';
  }
}

class _Post {
  final String id;
  final String title;
  final String gids;
  _Post({required this.id, required this.title, required this.gids});
}

/// 伪 device_fp：真 fp 由设备指纹接口下发，这里用 md5(seed) 拼成 40 hex 的
/// 稳定替代值。服务端多数场景允许缺省，带上可提高接口通过率。
class Md5Like {
  static String fingerprint(String seed) {
    final h = Md5.hex(utf8.encode(seed));
    return h + h.substring(0, 8); // 40 hex
  }
}
