import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Small, dependency-free SHA-256 implementation used by the PC server.
///
/// This avoids adding a crypto package to the Flutter application just for the
/// optional desktop server. It supports streaming so large uploads do not have
/// to be loaded into memory.
final class Sha256 {
  Sha256();

  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final List<int> _state = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final Uint8List _buffer = Uint8List(64);
  var _bufferLength = 0;
  var _byteLength = 0;
  var _closed = false;

  void add(List<int> bytes) {
    if (_closed) {
      throw StateError('Cannot add data after digest()');
    }
    _byteLength += bytes.length;
    var offset = 0;
    while (offset < bytes.length) {
      final take = (64 - _bufferLength).clamp(0, bytes.length - offset);
      _buffer.setRange(_bufferLength, _bufferLength + take, bytes, offset);
      _bufferLength += take;
      offset += take;
      if (_bufferLength == 64) {
        _processBlock(_buffer);
        _bufferLength = 0;
      }
    }
  }

  Uint8List digest() {
    if (_closed) {
      throw StateError('digest() may only be called once');
    }
    _closed = true;
    final bitLength = _byteLength * 8;
    _buffer[_bufferLength++] = 0x80;
    if (_bufferLength > 56) {
      _buffer.fillRange(_bufferLength, 64, 0);
      _processBlock(_buffer);
      _bufferLength = 0;
    }
    _buffer.fillRange(_bufferLength, 56, 0);
    for (var index = 0; index < 8; index++) {
      _buffer[63 - index] = (bitLength >> (index * 8)) & 0xff;
    }
    _processBlock(_buffer);

    final result = Uint8List(32);
    for (var index = 0; index < _state.length; index++) {
      final value = _state[index];
      result[index * 4] = (value >> 24) & 0xff;
      result[index * 4 + 1] = (value >> 16) & 0xff;
      result[index * 4 + 2] = (value >> 8) & 0xff;
      result[index * 4 + 3] = value & 0xff;
    }
    return result;
  }

  String hexDigest() => hexEncode(digest());

  void _processBlock(Uint8List block) {
    final words = Uint32List(64);
    for (var index = 0; index < 16; index++) {
      final offset = index * 4;
      words[index] =
          (block[offset] << 24) |
          (block[offset + 1] << 16) |
          (block[offset + 2] << 8) |
          block[offset + 3];
    }
    for (var index = 16; index < 64; index++) {
      final x = words[index - 15];
      final y = words[index - 2];
      final s0 = _rotateRight(x, 7) ^ _rotateRight(x, 18) ^ (x >> 3);
      final s1 = _rotateRight(y, 17) ^ _rotateRight(y, 19) ^ (y >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];
    for (var index = 0; index < 64; index++) {
      final upper =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 =
          (h + upper + choose + _roundConstants[index] + words[index]) &
          0xffffffff;
      final lower =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (lower + majority) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }

  static int _rotateRight(int value, int count) =>
      ((value >> count) | (value << (32 - count))) & 0xffffffff;

  static Future<String> fileHex(File file) async {
    final hash = Sha256();
    await for (final chunk in file.openRead()) {
      hash.add(chunk);
    }
    return hash.hexDigest();
  }
}

String sha256Hex(List<int> bytes) {
  final hash = Sha256()..add(bytes);
  return hash.hexDigest();
}

String hexEncode(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

bool constantTimeEquals(String left, String right) {
  final leftBytes = utf8.encode(left);
  final rightBytes = utf8.encode(right);
  var difference = leftBytes.length ^ rightBytes.length;
  final length = leftBytes.length > rightBytes.length
      ? leftBytes.length
      : rightBytes.length;
  for (var index = 0; index < length; index++) {
    final a = index < leftBytes.length ? leftBytes[index] : 0;
    final b = index < rightBytes.length ? rightBytes[index] : 0;
    difference |= a ^ b;
  }
  return difference == 0;
}
