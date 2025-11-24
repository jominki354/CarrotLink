import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Check SSHPublicKey API', () async {
    // Generate a key pair
    final keyPair = await SSHKeyPair.generate(SSHKeyType.rsa);
    final publicKey = keyPair.first.publicKey;
    
    print('Type: ${publicKey.type}');
    // Check if toBinary exists
    // print('Binary: ${base64.encode(publicKey.toBinary())}'); 
    // If toBinary() doesn't exist, this will fail compilation/runtime.
    
    // Let's try to print what we think is the correct way
    // Based on the previous file read, it suggested:
    // '${publicKey.type} ${base64.encode(publicKey.toBinary())}'
    
    // I'll try to run this test.
  });
}
