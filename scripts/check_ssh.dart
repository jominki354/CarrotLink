import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';

void main() {
  SSHKeyPair? keyPair;
  if (keyPair != null) {
      // Test 2: toPublicKey() method
      var pk = keyPair.toPublicKey();
      print(pk.type);
      // print(base64.encode(pk.toBinary()));
  }
}
