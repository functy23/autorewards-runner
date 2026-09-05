/// 统一 HTTP 客户端封装。
///
/// - 统一超时 / 重试（指数退避）
/// - 统一日志（不打 body 里的敏感字段，只记 URL + 状态码 + 耗时）
/// - gzip 自动解压（dart:http 默认处理）
library;
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_log.dart';

class HttpResult {
  final int status;
  final String body;
  final Map<String, String> headers;
  HttpResult(this.status, this.body, this.headers);

  Map<String, dynamic> get json =>
      jsonDecode(body) as Map<String, dynamic>;

  /// 安全解析：非 JSON 响应（如 403 的 HTML/纯文本）不抛异常，
  /// 返回合成的错误结构——任务流程据此记失败步骤而不是整体中断
  Map<String, dynamic> get jsonSafe {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      return {'retcode': -1, 'message': '响应格式异常 (HTTP $status)'};
    } on FormatException {
      final preview = body.length > 60 ? '${body.substring(0, 60)}…' : body;
      return {
        'retcode': -1,
        'message': '响应不是 JSON (HTTP $status): $preview',
      };
    }
  }

  bool get ok => status >= 200 && status < 300;
}

class HttpBox {
  static const _uaMobileChrome =
      'Mozilla/5.0 (Linux; Android 12; Unspecified Device) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/103.0.5060.129 Mobile Safari/537.36';
  static const _uaDesktop =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static String get uaMobileChrome => _uaMobileChrome;
  static String get uaDesktop => _uaDesktop;

  final http.Client _client = http.Client();
  final Duration timeout;
  final int retries;

  HttpBox({this.timeout = const Duration(seconds: 20), this.retries = 2});

  Future<HttpResult> get(
    String url, {
    Map<String, String>? headers,
    int retries = -1,
  }) =>
      _send('GET', url, headers: headers, retries: retries);

  Future<HttpResult> post(
    String url, {
    Map<String, String>? headers,
    Object? body,
    String? bodyRaw,
    int retries = -1,
  }) =>
      _send('POST', url,
          headers: headers, body: body, bodyRaw: bodyRaw, retries: retries);

  Future<HttpResult> _send(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? body,
    String? bodyRaw,
    int retries = -1,
  }) async {
    final tries = retries < 0 ? this.retries : retries;
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (e) {
      throw FormatException('URL 非法: $url');
    }

    var lastErr = '';
    for (var attempt = 0; attempt <= tries; attempt++) {
      final sw = Stopwatch()..start();
      try {
        final h = {...?headers};
        http.Response resp;
        if (method == 'GET') {
          resp = await _client
              .get(uri, headers: h)
              .timeout(timeout);
        } else {
          String payload;
          if (bodyRaw != null) {
            payload = bodyRaw;
          } else if (body != null) {
            payload = body is String ? body : jsonEncode(body);
            h.putIfAbsent('Content-Type', () => 'application/json; charset=UTF-8');
          } else {
            payload = '';
          }
          resp = await _client
              .post(uri, headers: h, body: payload)
              .timeout(timeout);
        }
        sw.stop();
        AppLog.d('HTTP',
            '$method $uri -> ${resp.statusCode} (${sw.elapsedMilliseconds}ms, ${resp.bodyBytes.length}B)');
        return HttpResult(
            resp.statusCode, utf8.decode(resp.bodyBytes, allowMalformed: true), resp.headers);
      } on TimeoutException {
        lastErr = 'timeout(${timeout.inSeconds}s)';
      } catch (e) {
        lastErr = e.toString();
      }
      sw.stop();
      if (attempt < tries) {
        final backoff = Duration(milliseconds: 600 * (1 << attempt));
        AppLog.w('HTTP', '$method $uri 第${attempt + 1}次失败($lastErr)，${backoff.inMilliseconds}ms 后重试');
        await Future.delayed(backoff);
      }
    }
    AppLog.e('HTTP', '$method $uri 最终失败: $lastErr');
    return HttpResult(0, '{"retcode":-1,"message":"network error: $lastErr"}', {});
  }

  void close() => _client.close();
}
