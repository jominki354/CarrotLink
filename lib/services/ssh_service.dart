import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SSHService extends ChangeNotifier {
  SSHClient? _client;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  bool get isConnected => _client != null && !_client!.isClosed;
  String _connectionStatus = "Disconnected";
  String get connectionStatus => _connectionStatus;
  String? _connectedIp;
  String? get connectedIp => _connectedIp;

  // IP Discovery
  final StreamController<String> _ipDiscoveryController = StreamController<String>.broadcast();
  Stream<String> get ipDiscoveryStream => _ipDiscoveryController.stream;
  RawDatagramSocket? _udpSocket;

  Future<void> connect(String ip, String username, {String? password, String? privateKey}) async {
    _connectionStatus = "Connecting...";
    _connectedIp = ip;
    notifyListeners();

    try {
      final socket = await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5));
      
      if (privateKey != null) {
        try {
          final keys = SSHKeyPair.fromPem(privateKey);
          print("Debug: Parsed ${keys.length} keys from PEM.");
          if (keys.isEmpty) {
             throw Exception("No valid keys found in the provided PEM.");
          }
          _client = SSHClient(
            socket,
            username: username,
            identities: keys,
          );
        } catch (e) {
          print("Debug: Key parsing failed: $e");
          rethrow;
        }
      } else {
        _client = SSHClient(
          socket,
          username: username,
          onPasswordRequest: () => password,
        );
      }

      await _client!.authenticated;
      _connectionStatus = "Connected";
      notifyListeners();
    } catch (e) {
      _connectionStatus = "Error: $e";
      _client = null;
      notifyListeners();
      rethrow;
    }
  }


  Future<String> executeCommand(String command) async {
    if (!isConnected) return "Not Connected";
    
    try {
      final result = await _client!.run(command);
      return utf8.decode(result);
    } catch (e) {
      return "Error executing command: $e";
    }
  }

  Future<SSHSession> startShell() async {
    if (!isConnected) throw Exception("Not Connected");
    final session = await _client!.shell(
      pty: SSHPtyConfig(
        width: 80,
        height: 24,
      ),
    );
    return session;
  }

  SftpClient? _sftp;

  Future<SftpClient> get sftp async {
    if (_sftp != null) return _sftp!;
    if (_client == null) throw Exception("Not connected");
    _sftp = await _client!.sftp();
    return _sftp!;
  }

  Future<List<SftpName>> listFiles(String path) async {
    final client = await sftp;
    final files = await client.listdir(path);
    // Sort: Directories first, then files
    files.sort((a, b) {
      final aIsDir = a.attr.isDirectory;
      final bIsDir = b.attr.isDirectory;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      return a.filename.compareTo(b.filename);
    });
    return files;
  }

  Future<void> renameFile(String oldPath, String newPath) async {
    final client = await sftp;
    await client.rename(oldPath, newPath);
  }

  Future<void> deleteFile(String path) async {
    final client = await sftp;
    // Check if it's a directory or file
    final stat = await client.stat(path);
    if (stat.isDirectory) {
      await client.rmdir(path);
    } else {
      await client.remove(path);
    }
  }

  Future<String> readTextFile(String path) async {
    final client = await sftp;
    final file = await client.open(path);
    final size = (await file.stat()).size ?? 0;
    final content = file.read(length: size);
    
    final List<int> bytes = [];
    await for (final chunk in content) {
      bytes.addAll(chunk);
    }
    
    await file.close();
    return utf8.decode(bytes);
  }

  Future<void> writeTextFile(String path, String content) async {
    final client = await sftp;
    final file = await client.open(path, mode: SftpFileOpenMode.write | SftpFileOpenMode.create | SftpFileOpenMode.truncate);
    await file.write(Stream.value(utf8.encode(content)));
    await file.close();
  }

  Future<Uint8List> readBinaryFile(String path) async {
    final client = await sftp;
    final file = await client.open(path);
    final stat = await client.stat(path);
    final size = stat.size ?? 0;
    final stream = file.read(length: size);
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  Future<void> disconnect() async {
    _sftp?.close();
    _sftp = null;
    _client?.close();
    _client = null;
    _connectionStatus = "Disconnected";
    notifyListeners();
  }
  
  Future<void> saveConnection(String ip, String username, String? password, String? keyPath) async {
    await _storage.write(key: 'ssh_ip', value: ip);
    await _storage.write(key: 'ssh_username', value: username);
    if (password != null) await _storage.write(key: 'ssh_password', value: password);
    if (keyPath != null) await _storage.write(key: 'ssh_key_path', value: keyPath);
  }

  // Helper methods for Dashboard
  Future<String> getBranch() async {
    return (await executeCommand("cd /data/openpilot && git rev-parse --abbrev-ref HEAD")).trim();
  }

  Future<String> getCpuTemp() async {
    // This path might vary depending on the device (C2/C3). Using a generic thermal zone.
    // Often thermal_zone0 is CPU.
    final result = await executeCommand("cat /sys/class/thermal/thermal_zone0/temp");
    try {
      final temp = int.parse(result.trim());
      return "${(temp / 1000).toStringAsFixed(1)}°C";
    } catch (e) {
      return "N/A";
    }
  }

  Future<String> getStorageUsage() async {
    final result = await executeCommand("df -h /data | awk 'NR==2 {print \$5}'");
    return result.trim();
  }

  Future<String> getCommitHash() async {
    return (await executeCommand("cd /data/openpilot && git rev-parse --short HEAD")).trim();
  }

  Future<String> getCarModel() async {
    // This is tricky, usually stored in params or log. 
    // Let's try to read a param if possible, or just return a placeholder.
    // For now, let's return "Unknown" or try to cat a file.
    return "Unknown"; 
  }

  Future<void> startDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 7705);
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              final data = json.decode(message);
              if (data is Map<String, dynamic> && data.containsKey('ip')) {
                final ip = data['ip'] as String;
                _ipDiscoveryController.add(ip);
              }
            } catch (e) {
              // Ignore malformed messages
            }
          }
        }
      });
    } catch (e) {
      print("Error binding UDP socket: $e");
    }
  }

  void stopDiscovery() {
    _udpSocket?.close();
    _udpSocket = null;
  }

  @override
  void dispose() {
    stopDiscovery();
    _ipDiscoveryController.close();
    super.dispose();
  }
}
