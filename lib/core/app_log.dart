/// 全局日志系统。
///
/// 所有模块统一走 [AppLog]，写入内存环形缓冲（UI 显示）+ 应用支持目录下的
/// `logs/app-YYYYMMDD.log` 文件（最近 7 天自动清理）。
/// 敏感信息（cookie/token）永远不会写入日志。
library;
import 'dart:async';
import 'dart:io';
import 'dart:collection';

class AppLog {
  static final StreamController<LogLine> _stream =
      StreamController<LogLine>.broadcast();
  static final Queue<LogLine> _buffer = Queue<LogLine>();
  static const int maxBuffer = 500;
  static Directory? _logDir;

  static Stream<LogLine> get stream => _stream.stream;
  static List<LogLine> get lines => _buffer.toList(growable: false);

  static Future<void> init(Directory supportDir) async {
    _logDir = Directory('${supportDir.path}/logs');
    if (!_logDir!.existsSync()) _logDir!.createSync(recursive: true);
    _cleanupOldLogs();
    i('AppLog', '日志系统初始化完成');
  }

  static void _cleanupOldLogs() {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      for (final f in _logDir!.listSync()) {
        if (f is File &&
            f.path.endsWith('.log') &&
            f.statSync().modified.isBefore(cutoff)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  static void _write(String level, String tag, String message) {
    final line = LogLine(
      DateTime.now(),
      level,
      tag,
      // 防御性兜底：任何模块都不该把 token 打进来
      message.replaceAll(RegExp(r'(stoken|access_token|accessToken|Bearer)=[A-Za-z0-9_\-\.]+'), r'$1=***'),
    );
    _buffer.add(line);
    if (_buffer.length > maxBuffer) _buffer.removeFirst();
    _stream.add(line);
    _appendFile(line);
  }

  static void _appendFile(LogLine line) {
    final dir = _logDir;
    if (dir == null) return;
    try {
      final name =
          'app-${DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '')}.log';
      final f = File('${dir.path}/$name');
      f.writeAsStringSync('${line.formatted}\n', mode: FileMode.append);
    } catch (_) {}
  }

  static void d(String tag, String msg) => _write('DEBUG', tag, msg);
  static void i(String tag, String msg) => _write('INFO ', tag, msg);
  static void w(String tag, String msg) => _write('WARN ', tag, msg);
  static void e(String tag, String msg) => _write('ERROR', tag, msg);
}

class LogLine {
  final DateTime time;
  final String level;
  final String tag;
  final String message;
  LogLine(this.time, this.level, this.tag, this.message);

  String get formatted => '[${time.toIso8601String()}] $level [$tag] $message';

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}
