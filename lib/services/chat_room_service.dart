import 'dart:convert';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';

String navoraGenerateRoomPasswordSalt() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Future<String> navoraHashRoomPassword(String password, String salt) async {
  final algorithm = Pbkdf2.hmacSha256(iterations: 120000, bits: 256);
  final derivedKey = await algorithm.deriveKeyFromPassword(
    password: password,
    nonce: utf8.encode(salt),
  );
  final bytes = await derivedKey.extractBytes();
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
