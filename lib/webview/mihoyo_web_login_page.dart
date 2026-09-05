/// 米游社网页登录页：加载官方登录页，支持密码/短信验证码/扫码等一切官方方式。
/// 登录完成后由用户点「提取并保存 Cookie」，从各相关域合并 Cookie 导入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/app_log.dart';
import '../services/mihoyobbs/mihoyobbs_service.dart';

class MihoyoWebLoginPage extends StatefulWidget {
  const MihoyoWebLoginPage({super.key});

  @override
  State<MihoyoWebLoginPage> createState() => _MihoyoWebLoginPageState();
}

class _MihoyoWebLoginPageState extends State<MihoyoWebLoginPage> {
  bool _saving = false;

  static const _captureUrls = [
    'https://user.mihoyo.com/',
    'https://bbs.miyoushe.com/',
    'https://www.miyoushe.com/',
    'https://api-takumi.mihoyo.com/',
  ];

  Future<void> _extractAndSave() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final cm = CookieManager.instance();
      final pairs = <String, String>{};
      for (final u in _captureUrls) {
        try {
          final cookies = await cm.getCookies(url: WebUri(u));
          for (final c in cookies) {
            final name = c.name.trim();
            final value = c.value;
            if (name.isEmpty || value.isEmpty) continue;
            pairs.putIfAbsent(name, () => value);
          }
        } catch (e) {
          AppLog.w('MHY-WEB', '读取 $u cookie 失败: $e');
        }
      }
      if (pairs.isEmpty) {
        _toast('未提取到任何 Cookie，请先在页面里完成登录');
        return;
      }
      final cookieStr = pairs.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
      final r = await MihoyoBbsService().importCookie(cookieStr);
      AppLog.i('MHY-WEB', '网页登录导入: ${r.summary}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${r.summary}\n${r.steps.isEmpty ? '' : r.steps.last}')),
      );
      if (r.ok) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('米游社网页登录'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _extractAndSave,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_rounded),
            label: const Text('提取并保存'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              '在下方页面使用官方任意方式登录（密码 / 短信验证码 / 扫码），'
              '完成后点右上角「提取并保存」。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri('https://user.mihoyo.com/#/login')),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                incognito: false,
                isInspectable: true,
                userAgent: null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
