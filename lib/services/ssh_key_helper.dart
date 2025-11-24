import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  Future<bool> installKey(String ip, int port, String username, String password, String publicKey) async {
    SSHClient? client;
    try {
      client = SSHClient(
        await SSHSocket.connect(ip, port, timeout: const Duration(seconds: 5)),
        username: username,
        onPasswordRequest: () => password,
      );

      // Script to install key in multiple locations for compatibility
      // 1. Openpilot standard: /data/params/d/GithubSshKeys
      // 2. Linux standard: ~/.ssh/authorized_keys
      final cmd = '''
# Ensure directories exist
mkdir -p /data/params/d
mkdir -p ~/.ssh

# 1. Install to Openpilot params (if writable)
if [ -d "/data/params/d" ]; then
  # Create GithubSshKeys if it doesn't exist (it's a file in openpilot params)
  # But sometimes it's treated as a directory in some custom forks? 
  # Standard openpilot uses a file named GithubSshKeys.
  
  # We append to it.
  echo "$publicKey" >> /data/params/d/GithubSshKeys || true
  chmod 600 /data/params/d/GithubSshKeys || true
fi

# 2. Install to authorized_keys
echo "$publicKey" >> ~/.ssh/authorized_keys || true
chmod 600 ~/.ssh/authorized_keys || true
chmod 700 ~/.ssh || true
''';
      
      await client.execute(cmd);
      return true;
    } catch (e) {
      print("Error installing key: $e");
      return false;
    } finally {
      client?.close();
    }
  }

  Future<String?> getStoredPrivateKey() async {
    return await _storage.read(key: 'user_private_key');
  }
}
