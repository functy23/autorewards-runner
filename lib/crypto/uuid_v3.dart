/// UUID v3（MD5 命名空间版）—— 米游社 device_id 生成用。
///
/// Python: uuid.uuid3(uuid.NAMESPACE_URL, cookie)
/// NAMESPACE_URL = 6ba7b811-9dad-11d1-80b4-00c04fd430c8
library;
import 'dart:convert';
import 'dart:typed_data';
import 'md5.dart';

class UuidV3 {
  static const _nsUrlBytes = [
    0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, //
    0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
  ];

  static String fromString(String name) {
    final nameBytes = utf8.encode(name);
    final data = [..._nsUrlBytes, ...nameBytes];
    final hash = Md5.digest(data);

    final b = Uint8List.fromList(hash.sublist(0, 16));
    b[6] = (b[6] & 0x0f) | 0x30; // version 3
    b[8] = (b[8] & 0x3f) | 0x80; // variant

    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
