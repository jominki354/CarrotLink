import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
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

  Future<bool> uploadPublicKey(String title, String key) async {
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
      return true;
    } else {
      throw Exception("Failed to upload key: ${response.body}");
    }
  }

  // Simple RSA Key Generation using PointyCastle
  Future<Map<String, String>> generateRSAKeyPair() async {
    return await compute(_generateRSAKeyPairIsolate, null);
  }

  static Map<String, String> _generateRSAKeyPairIsolate(_) {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(255)))));

    final keyGen = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        secureRandom,
      ));

    final pair = keyGen.generateKeyPair();
    final public = pair.publicKey as RSAPublicKey;
    final private = pair.privateKey as RSAPrivateKey;

    return {
      'private': _encodePrivateKeyToPem(private),
      'public': _encodePublicKeyToSsh(public),
    };
  }

  static String _encodePrivateKeyToPem(RSAPrivateKey privateKey) {
    var version = BigInt.zero;
    var n = privateKey.modulus!;
    var e = privateKey.publicExponent!;
    var d = privateKey.privateExponent!;
    var p = privateKey.p!;
    var q = privateKey.q!;
    var dP = d % (p - BigInt.one);
    var dQ = d % (q - BigInt.one);
    var qInv = q.modInverse(p);

    var bytes = <int>[];
    
    // Sequence content
    var content = <int>[];
    content.addAll(_encodeASN1Integer(version));
    content.addAll(_encodeASN1Integer(n));
    content.addAll(_encodeASN1Integer(e));
    content.addAll(_encodeASN1Integer(d));
    content.addAll(_encodeASN1Integer(p));
    content.addAll(_encodeASN1Integer(q));
    content.addAll(_encodeASN1Integer(dP));
    content.addAll(_encodeASN1Integer(dQ));
    content.addAll(_encodeASN1Integer(qInv));

    // Sequence header
    bytes.add(0x30); 
    _writeASN1Length(bytes, content.length);
    bytes.addAll(content);

    var base64Data = base64.encode(bytes);
    var pem = "-----BEGIN RSA PRIVATE KEY-----\n";
    for (var i = 0; i < base64Data.length; i += 64) {
      pem += base64Data.substring(i, min(i + 64, base64Data.length)) + "\n";
    }
    pem += "-----END RSA PRIVATE KEY-----";
    return pem;
  }

  static List<int> _encodeASN1Integer(BigInt v) {
    var bytes = <int>[];
    bytes.add(0x02); // Integer tag
    var content = _encodeBigInt(v);
    _writeASN1Length(bytes, content.length);
    bytes.addAll(content);
    return bytes;
  }

  static void _writeASN1Length(List<int> bytes, int length) {
    if (length < 128) {
      bytes.add(length);
    } else {
      var lenBytes = <int>[];
      while (length > 0) {
        lenBytes.insert(0, length & 0xFF);
        length >>= 8;
      }
      bytes.add(0x80 | lenBytes.length);
      bytes.addAll(lenBytes);
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
