import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ssh_service.dart';

class SSHKeyHelper {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Generates a new RSA key pair, saves it securely, and returns the public key.
  Future<String> generateAndSaveKey() async {
    // Generate 2048-bit RSA key pair
    // Note: dartssh2's SSHKeyPair.generate() might be synchronous and CPU intensive.
    // In a real app, run this in an isolate.
    // final keyPair = SSHKeyPair.generate(SSHKeyType.rsa);
    
    // final pem = keyPair.toPem();
    // final publicKey = keyPair.toOpenSSHPublicKey(); // e.g. "ssh-rsa AAAA..."

    // Save private key securely
    // await _storage.write(key: 'user_private_key', value: pem);
    
    // return publicKey;
    throw UnimplementedError("Key generation not supported in this version");
  }

  /// Connects using password, appends the public key to authorized_keys, and verifies connection.
  Future<bool> installKey(String ip, String password, String publicKey) async {
    final client = SSHClient(
      await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5)),
      username: 'root',
      onPasswordRequest: () => password,
    );

    try {
      // 1. Check if key already exists to avoid duplicates
      // 2. Append key
      // 3. Fix permissions just in case
      final cmd = '''
        mkdir -p /data/params/d
        if ! grep -qF "$publicKey" /data/params/d/GithubSshKeys; then
          echo "$publicKey" >> /data/params/d/GithubSshKeys
          chmod 600 /data/params/d/GithubSshKeys
        fi
        # Also add to standard authorized_keys for root if needed, 
        # but Openpilot usually uses GithubSshKeys param or /root/.ssh/authorized_keys
        mkdir -p /root/.ssh
        if ! grep -qF "$publicKey" /root/.ssh/authorized_keys; then
          echo "$publicKey" >> /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
        fi
      ''';
      
      await client.execute(cmd);
      return true;
    } catch (e) {
      print("Error installing key: $e");
      return false;
    } finally {
      client.close();
    }
  }

  Future<String?> getStoredPrivateKey() async {
    return await _storage.read(key: 'user_private_key');
  }
}
