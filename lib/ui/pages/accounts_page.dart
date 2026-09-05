/// 账号管理页（aShellYou settings-dsl 风格）。
///
/// - 米游社：扫码登录 / 网页登录（密码、短信验证码）/ Cookie 粘贴
/// - WorkBuddy：macOS 本机读取 / 手动粘贴 accessToken
/// - 所有令牌/Cookie 输入框旁均带复制按钮（复制成功显示对勾动效）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_prefs.dart';
import '../../services/mihoyobbs/mihoyobbs_service.dart';
import '../../services/workbuddy/workbuddy_service.dart';
import '../widgets/common.dart';
import '../widgets/settings_items.dart';
import '../../webview/mihoyo_web_login_page.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, this.wide = false});

  final bool wide;

  @override
  AccountsPageState createState() => AccountsPageState();
}

class AccountsPageState extends State<AccountsPage> {
  final _mhyCookieCtrl = TextEditingController();
  final _wbTokenCtrl = TextEditingController();
  final _wbUidCtrl = TextEditingController();

  bool _mhyHasLogin = false;
  bool _mhyHasStoken = false;
  bool _wbHasToken = false;
  String? _wbLocalFound;

  /// 主页在页面切换回来时调用（页面常驻保活后 initState 只跑一次）
  void refresh() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mhyCookieCtrl.dispose();
    _wbTokenCtrl.dispose();
    _wbUidCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final mhy = MihoyoBbsService();
    await mhy.loadSaved();
    final local =
        Platform.isMacOS ? WorkBuddyService.readLocalAuthMacos() : null;
    if (!mounted) return;
    setState(() {
      _mhyHasLogin = mhy.hasLogin;
      _mhyHasStoken = (AppPrefs.secret('mhy.stoken') ?? '').isNotEmpty;
      _wbTokenCtrl.text = AppPrefs.secret('wb.token') ?? '';
      _wbUidCtrl.text = AppPrefs.secret('wb.uid') ?? '';
      _wbHasToken = _wbTokenCtrl.text.isNotEmpty;
      _wbLocalFound = local != null
          ? '检测到桌面端登录态 (uid=${local.uid})'
          : (Platform.isMacOS ? '未在默认路径找到 WorkBuddy 桌面端登录态' : null);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 窄屏：内容在模糊顶栏/底栏下滚动，需留出相应边距
    final wide = widget.wide;
    final media = MediaQuery.of(context);
    final topPad = wide ? 8.0 : media.padding.top + kToolbarHeight + 8;
    final bottomPad = wide ? 32.0 : 104.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(15, topPad, 15, bottomPad),
      children: [
        const SettingsGroupHeader('米游社'),
        SettingsCardGroup(
          children: [
            SettingsStatusItem(
              title: _mhyHasLogin
                  ? (_mhyHasStoken ? '已配置登录态（stoken）' : '已配置登录态（web cookie）')
                  : '未配置',
              description: _mhyHasLogin
                  ? (_mhyHasStoken
                      ? '任务执行时使用已保存的登录态'
                      : '仅支持任务状态查询；签到/看帖任务需扫码登录')
                  : '选择下方任意一种方式登录',
              icon: _mhyHasLogin
                  ? Icons.check_circle_rounded
                  : Icons.person_outline_rounded,
            ),
            SettingsContentItem(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _qrLogin,
                          icon: const Icon(Icons.qr_code_2_rounded),
                          label: const Text('扫码登录'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const MihoyoWebLoginPage()));
                            await _load();
                          },
                          icon: const Icon(Icons.web_rounded),
                          label: const Text('网页登录'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '推荐「扫码登录」（免抓包、得到完整 stoken）；「网页登录」支持密码/'
                    '短信验证码；也可以直接粘贴抓包 Cookie。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  CopyableField(
                    controller: _mhyCookieCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'stoken=v2_...; stuid=...; mid=...; ...',
                      helperText: '仅存本机；输入时内容可见，请注意周围环境',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _importMhy,
                    icon: const Icon(Icons.login),
                    label: const Text('导入并验证'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SettingsGroupHeader('WorkBuddy'),
        SettingsCardGroup(
          children: [
            SettingsStatusItem(
              title: _wbHasToken ? '已配置 token' : '未配置',
              description: _wbLocalFound ?? '登录 WorkBuddy 桌面端或手动粘贴 accessToken',
              icon: _wbHasToken
                  ? Icons.check_circle_rounded
                  : Icons.workspace_premium_outlined,
            ),
            if (Platform.isMacOS)
              SettingsTapItem(
                title: '从本机读取',
                description: '读取桌面端明文登录态（v5.3.8+），token 仅存本机',
                icon: Icons.folder_open_rounded,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  final local = WorkBuddyService.readLocalAuthMacos();
                  if (local == null) {
                    _toast('未找到本机登录态文件');
                    return;
                  }
                  await WorkBuddyService().importToken(local.token,
                      uid: local.uid,
                      domain: local.domain,
                      enterpriseId: local.enterpriseId);
                  await _load();
                  _toast('已读取本机登录态');
                },
              ),
            SettingsContentItem(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Platform.isMacOS
                        ? '也可从桌面端复制 accessToken 手动粘贴：'
                        : '从桌面端复制 accessToken 粘贴到下面：',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  CopyableField(
                    controller: _wbTokenCtrl,
                    obscureText: true, // 单行字段，可遮蔽
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'accessToken（等同账号密码，仅存本机）',
                    ),
                  ),
                  const SizedBox(height: 8),
                  CopyableField(
                    controller: _wbUidCtrl,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'uid（可选）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () async {
                      await WorkBuddyService().importToken(
                          _wbTokenCtrl.text.trim(),
                          uid: _wbUidCtrl.text.trim());
                      await _load();
                      _toast('WorkBuddy token 已保存（仅本机）');
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ================= 米游社扫码登录 =================

  Future<void> _qrLogin() async {
    final svc = MihoyoBbsService();
    _toast('正在创建二维码…');
    final session = await svc.createQrLogin();
    if (!mounted) return;
    if (session == null) {
      _toast('创建二维码失败，详情见日志页');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QrLoginDialog(session: session, service: svc),
    );
    await _load();
  }

  Future<void> _importMhy() async {
    final cookie = _mhyCookieCtrl.text.trim();
    if (cookie.isEmpty) {
      _toast('请先粘贴 cookie');
      return;
    }
    _toast('验证中…');
    final r = await MihoyoBbsService().importCookie(cookie);
    await _load();
    _toast(r.summary);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 扫码登录对话框：展示二维码 + 每 2 秒轮询确认状态
class _QrLoginDialog extends StatefulWidget {
  const _QrLoginDialog({required this.session, required this.service});

  final ({String url, String ticket, String deviceId}) session;
  final MihoyoBbsService service;

  @override
  State<_QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends State<_QrLoginDialog> {
  String _status = '请用米游社 App 扫描二维码';
  Timer? _timer;
  bool _terminal = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    Timer(const Duration(minutes: 2), () {
      if (mounted && !_terminal) {
        _terminal = true;
        _timer?.cancel();
        setState(() => _status = '二维码已超时，请重新发起');
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_terminal) return;
    final s = await widget.service.pollQrLoginStatus(
      ticket: widget.session.ticket,
      deviceId: widget.session.deviceId,
    );
    if (!mounted || _terminal) return;
    switch (s) {
      case 'Created':
        break;
      case 'Scanned':
        setState(() => _status = '已扫码，请在手机上确认');
      case 'Confirmed':
        _terminal = true;
        _timer?.cancel();
        setState(() => _status = '登录成功 ✓');
        Navigator.of(context).pop();
      case 'Expired':
        _terminal = true;
        _timer?.cancel();
        setState(() => _status = '二维码已过期，请重新发起');
      default:
        if (s.startsWith('Error')) {
          _terminal = true;
          _timer?.cancel();
          setState(() => _status = s.replaceFirst('Error:', ''));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('米游社扫码登录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 注意：不能用 QrImageView（内部 LayoutBuilder 与 AlertDialog 的
          // intrinsic 测量冲突会崩溃），用固定尺寸的 QrPainter
          CustomPaint(
            size: const Size(220, 220),
            painter: QrPainter(
              data: widget.session.url,
              version: QrVersions.auto,
              gapless: true,
            ),
          ),
          const SizedBox(height: 16),
          Text(_status,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
