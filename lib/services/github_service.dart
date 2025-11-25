import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

class GitHubService {
  static const String _baseUrl = 'https://api.github.com';
  // Homepage URL: http://localhost
  // Authorization callback URL: http://localhost
  static const String _clientId = 'Ov23lis2qk24z3GryKlt'; 
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<Map<String, dynamic>> initiateDeviceFlow() async {
    final response = await http.post(
      Uri.parse('https://github.com/login/device/code'),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': _clientId,
        'scope': 'admin:public_key',
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      try {
        final errorData = jsonDecode(response.body);
        if (errorData['error'] == 'device_flow_disabled') {
          throw Exception('GitHub 앱 설정에서 Device Flow가 활성화되지 않았습니다. 개발자에게 문의하거나 설정을 확인하세요.');
        }
        throw Exception(errorData['error_description'] ?? response.body);
      } catch (e) {
        if (e.toString().contains('Device Flow')) rethrow;
        throw Exception('Failed to initiate device flow: ${response.body}');
      }
    }
  }

  Future<String?> pollForToken(String deviceCode) async {
    final response = await http.post(
      Uri.parse('https://github.com/login/oauth/access_token'),
      headers: {'Accept': 'application/json'},
      body: {
        'client_id': _clientId,
        'device_code': deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data.containsKey('access_token')) {
        return data['access_token'];
      } else if (data['error'] == 'authorization_pending') {
        return null;
      } else if (data['error'] == 'slow_down') {
        throw Exception('slow_down');
      } else if (data['error'] == 'expired_token') {
        throw Exception('expired_token');
      } else {
        // access_denied or other errors
        throw Exception(data['error_description'] ?? data['error']);
      }
    } else {
      throw Exception('Failed to poll token: ${response.body}');
    }
  }
  
  Future<void> saveToken(String token) async {
    await _storage.write(key: 'github_token', value: token);
  }

  Future<String?> getToken() async {
    return await _storage.read(key: 'github_token');
  }

  Future<void> clearToken() async {
    await _storage.delete(key: 'github_token');
  }

  Future<bool> isLoggedIn() async {
    return (await getToken()) != null;
  }

  Future<Map<String, dynamic>?> getUserInfo() async {
    final token = await getToken();
    if (token == null) return null;

    final response = await http.get(
      Uri.parse('$_baseUrl/user'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> listPublicKeys() async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final response = await http.get(
      Uri.parse('$_baseUrl/user/keys'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception("Failed to list keys: ${response.body}");
    }
  }

  /// Uploads a public key and returns the created key's ID, or null on failure.
  Future<int?> uploadPublicKey(String title, String key) async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final response = await http.post(
      Uri.parse('$_baseUrl/user/keys'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'title': title,
        'key': key,
      }),
    );

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body);
      return data['id'] as int?;
    } else {
      throw Exception("Failed to upload key: ${response.body}");
    }
  }

  // Key generation moved to SSHKeyHelper

  Future<bool> deletePublicKey(int keyId) async {
    final token = await getToken();
    if (token == null) throw Exception("Not logged in");

    final response = await http.delete(
      Uri.parse('$_baseUrl/user/keys/$keyId'),
      headers: {
        'Authorization': 'token $token',
        'Accept': 'application/vnd.github.v3+json',
      },
    );

    if (response.statusCode == 204) {
      return true;
    } else {
      throw Exception("Failed to delete key: ${response.body}");
    }
  }

  Future<String?> getPublicKeyFromPrivateKey(String privateKeyPem) async {
    try {
      return await compute(_getPublicKeyFromPrivateKeyIsolate, privateKeyPem);
    } catch (e) {
      return null;
    }
  }

  static String _getPublicKeyFromPrivateKeyIsolate(String privateKeyPem) {
    try {
      final keys = SSHKeyPair.fromPem(privateKeyPem);
      if (keys.isEmpty) return '';
      
      // Use dynamic to access properties of RsaPrivateKey from dartssh2
      // dartssh2 RsaPrivateKey usually has n and e (BigInt)
      final dynamic key = keys.first;
      
      // Check if it has n and e
      try {
        final n = key.n as BigInt;
        final e = key.e as BigInt;
        final public = RSAPublicKey(n, e); // pointycastle RSAPublicKey
        return _encodePublicKeyToSsh(public);
      } catch (e) {
        // Not RSA or properties not found
        return '';
      }
    } catch (e) {
      debugPrint("Error parsing key: $e");
      return '';
    }
  }

  static String _encodePublicKeyToSsh(RSAPublicKey publicKey) {
    final keyType = 'ssh-rsa';
    final e = publicKey.publicExponent!;
    final n = publicKey.modulus!;

    final bytes = <int>[];
    _writeString(bytes, keyType);
    _writeBigInt(bytes, e);
    _writeBigInt(bytes, n);

    return '$keyType ${base64.encode(bytes)} CarrotLink';
  }

  static void _writeString(List<int> buffer, String s) {
    final bytes = utf8.encode(s);
    _writeInt(buffer, bytes.length);
    buffer.addAll(bytes);
  }

  static void _writeInt(List<int> buffer, int v) {
    buffer.add((v >> 24) & 0xFF);
    buffer.add((v >> 16) & 0xFF);
    buffer.add((v >> 8) & 0xFF);
    buffer.add(v & 0xFF);
  }

  static void _writeBigInt(List<int> buffer, BigInt v) {
    var bytes = _encodeBigInt(v);
    _writeInt(buffer, bytes.length);
    buffer.addAll(bytes);
  }
  
  static List<int> _encodeBigInt(BigInt number) {
    if (number == BigInt.zero) return [0];

    var hex = number.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    
    var bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }

    // If MSB is set, prepend 0x00 to indicate positive number in 2's complement
    if ((bytes[0] & 0x80) != 0) {
      bytes.insert(0, 0x00);
    }
    return bytes;
  }
}
