/// MD5 摘要（米游社 DS 签名需要；crypto 包不暴露底层块操作，这里按 RFC 1321 实现）
library;
import 'dart:typed_data';

class Md5 {
  static const List<int> _s = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  static const List<int> _k = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
    0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
    0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
    0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
    0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
    0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  static Uint8List digest(List<int> input) {
    var msg = Uint8List.fromList(input);
    final origLen = msg.length;

    // padding
    final newLen = ((origLen + 8) ~/ 64) * 64 + 64;
    final padded = Uint8List(newLen);
    padded.setRange(0, origLen, msg);
    padded[origLen] = 0x80;
    final bits = origLen * 8;
    final bd = ByteData(8)..setUint64(0, bits, Endian.little);
    padded.setRange(newLen - 8, newLen, bd.buffer.asUint8List());

    var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

    final m = Uint32List(16);
    for (var chunk = 0; chunk < newLen; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        m[i] = ByteData.view(padded.buffer, chunk + i * 4, 4)
            .getUint32(0, Endian.little);
      }
      var a = a0, b = b0, c = c0, d = d0;
      for (var i = 0; i < 64; i++) {
        int f, g;
        if (i < 16) {
          f = (b & c) | (~b & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | (~d & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = (7 * i) % 16;
        }
        f = (f + a + _k[i] + m[g]) & 0xffffffff;
        a = d;
        d = c;
        c = b;
        b = (b + ((f << _s[i]) | (f >> (32 - _s[i])))) & 0xffffffff;
      }
      a0 = (a0 + a) & 0xffffffff;
      b0 = (b0 + b) & 0xffffffff;
      c0 = (c0 + c) & 0xffffffff;
      d0 = (d0 + d) & 0xffffffff;
    }

    final out = ByteData(16);
    out.setUint32(0, a0, Endian.little);
    out.setUint32(4, b0, Endian.little);
    out.setUint32(8, c0, Endian.little);
    out.setUint32(12, d0, Endian.little);
    return out.buffer.asUint8List();
  }

  static String hex(List<int> input) =>
      digest(input).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
