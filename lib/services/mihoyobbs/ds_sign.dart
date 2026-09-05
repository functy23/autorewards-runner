/// 米游社 DS 签名（Dart 实现，等价于 MihoyoBBSTools 的 tools.get_ds / get_ds2）。
///
/// 算法逆向结论（详见 docs/REVERSE_REPORT.md）：
///   DS1（K2 版本 salt，用于 GET 类接口，client_type=2 Android）:
///     t = 秒级时间戳
///     r = 从 [a-z0-9] 中随机取 6 个字符（sample，不重复）
///     c = md5("salt={SALT}&t={t}&r={r}")
///     DS = "{t},{r},{c}"
///
///   DS2（K2 的 X6 salt，用于 POST JSON 类接口，例如讨论区签到/点赞）:
///     t = 秒级时间戳
///     r = 100000~200000 之间的随机整数（Python randint 闭区间 → 100001..200000）
///     c = md5("salt={SALT_X6}&t={t}&r={r}&b={body}&q={query}")
///     DS = "{t},{r},{c}"
///     注意 b=完整请求体字符串（与服务端收到的字节严格一致，不要重新序列化），
///          q=URL query 字符串（无 query 时为空串）。
library;
import 'dart:math';
import '../../crypto/md5.dart';

class DsSign {
  /// 与米游社 App 版本对应的 salt（会随版本更新，失效时更新这里，见 setting.py 对应关系）
  static const saltK2 = '47f15f1b66bee46b816115d8e8e6ebb6';
  static const saltWeb = 'd9200c846b10886e8c874fc33c8f308b';
  static const saltX4 = 'xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs';
  static const saltX6 = 't0qEgfub6cvueAPgR5m9aQWWVciEer7v';
  /// MiyoQian 配对（BBS 2.106.2）：游戏签到 luna 的 web DS 与米游币任务 app DS。
  /// 与 saltK2/2.109.0 是并行的可用组合（不同版本区间）
  static const saltBbsV206 = 'idMMaGYmVgPzh3wxmWudUXKUPGidO7GM';
  static const saltBbsWebV206 = 'G1ktdwFL4IyGkHuuWSmz0wUe9Db9scyK';
  /// MiyoQian 使用的 BBS 版本号（与上面两个 salt 配对）
  static const bbsVersionV206 = '2.106.2';

  static final Random _rng = Random();
  static const _alphanum = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// DS1: 无参签名（GET）
  static String ds1({String salt = saltK2}) {
    final t = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    // random.sample 语义：不重复取样
    final pool = List.generate(_alphanum.length, (i) => i)..shuffle(_rng);
    final r = pool.take(6).map((i) => _alphanum[i]).join();
    final c = Md5.hex('salt=$salt&t=$t&r=$r'.codeUnits);
    return '$t,$r,$c';
  }

  /// DS2: 带 body/query 签名（POST JSON）
  static String ds2(String body, {String query = '', String salt = saltX6}) {
    final t = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final r = (100001 + _rng.nextInt(100000)).toString();
    final c = Md5.hex('salt=$salt&t=$t&r=$r&b=$body&q=$query'.codeUnits);
    return '$t,$r,$c';
  }
}
