import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../constants.dart';

class SSHService extends ChangeNotifier {
  SSHClient? _client;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  SSHService() {
    _initServiceListener();
  }

  void _initServiceListener() {
    final service = FlutterBackgroundService();
    
    service.on('connectionState').listen((event) {
      if (event != null) {
        final isServiceConnected = event['isConnected'] == true;
        if (!isServiceConnected && isConnected) {
           disconnect(fromService: true);
        }
      }
    });

    service.on('status').listen((event) async {
      if (event != null && event['isConnected'] == true) {
        if (!isConnected && !_isConnecting) {
          print("Background service is connected. Attempting to sync foreground...");
          await _reconnectFromStorage();
        }
      }
    });

    // Ask for status on init
    service.invoke('getStatus');
  }

  Future<void> _reconnectFromStorage() async {
    final ip = await _storage.read(key: 'ssh_ip');
    final username = await _storage.read(key: 'ssh_username');
    final password = await _storage.read(key: 'ssh_password');
    final keyPath = await _storage.read(key: 'ssh_key_path');

    if (ip != null && username != null) {
      String? privateKey;
      if (keyPath != null) {
        try {
          privateKey = await File(keyPath).readAsString();
        } catch (e) {
          print("Failed to read key file: $e");
        }
      }
      // Reconnect using standard flow
      connect(ip, username, password: password, privateKey: privateKey);
    }
  }
  
  bool get isConnected => _client != null && !_client!.isClosed;
  String _connectionStatus = "Disconnected";
  String get connectionStatus => _connectionStatus;
  String? _connectedIp;
  String? get connectedIp => _connectedIp;
  
  String? _targetIp;
  String? get targetIp => _targetIp;

  // IP Discovery
  final StreamController<String> _ipDiscoveryController = StreamController<String>.broadcast();
  Stream<String> get ipDiscoveryStream => _ipDiscoveryController.stream;
  RawDatagramSocket? _udpSocket;
  Timer? _heartbeatTimer;

  bool _isConnecting = false;
  bool get isConnecting => _isConnecting;

  Future<void> connect(String ip, String username, {String? password, String? privateKey}) async {
    if (_isConnecting) return;
    
    _isConnecting = true;
    _targetIp = ip; // Set target IP immediately
    _connectionStatus = "Connecting to $ip...";
    // _connectedIp = ip; // Do not set IP until connected to avoid "Ghost IP"
    
    notifyListeners();

    try {
      final socket = await SSHSocket.connect(ip, 22, timeout: const Duration(seconds: 5));
      
      // Check if disconnected while connecting
      if (!_isConnecting) {
        socket.destroy();
        return;
      }

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

      await _client!.authenticated.timeout(const Duration(seconds: 10));

      // Check if disconnected while authenticating
      if (!_isConnecting) {
        _client?.close();
        _client = null;
        return;
      }

      _connectionStatus = "Connected";
      _connectedIp = ip; // Set IP only after successful connection
      
      // Start Background Service Connection
      FlutterBackgroundService().invoke('connect', {
        'ip': ip,
        'username': username,
        'password': password,
        'privateKey': privateKey,
      });
      
      // Listen for immediate disconnection events from the socket
      _client!.done.then((_) {
        print("SSH Connection closed by OS/Remote");
        disconnect();
      });

      _startHeartbeat();
    } catch (e) {
      print("Connection failed: $e");
      _connectionStatus = _mapErrorToMessage(e);
      _client = null;
      _connectedIp = null; // Clear IP on error
      rethrow;
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  String _mapErrorToMessage(dynamic error) {
    final e = error.toString();
    if (e.contains("SocketException") || e.contains("Connection refused") || e.contains("Network is unreachable")) {
      return "연결 실패 (네트워크)";
    } else if (e.contains("TimeoutException")) {
      return "연결 시간 초과";
    } else if (e.contains("Authentication failed") || e.contains("password")) {
      return "인증 실패";
    } else if (e.contains("No valid keys")) {
      return "키 오류";
    }
    return "오류 발생";
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 2 seconds interval for faster detection
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_client == null) {
        timer.cancel();
        return;
      }
      
      if (_client!.isClosed) {
        print("Heartbeat: Client is closed");
        disconnect();
        return;
      }

      try {
        // Fallback to lightweight command since sendIgnore is not available in this version
        // Use a short timeout (1.5s) to detect dead connections quickly
        await _client!.run('true').timeout(const Duration(milliseconds: 1500));
      } catch (e) {
        print("Heartbeat failed: $e");
        disconnect();
      }
    });
  }


  Future<String> executeCommand(String command) async {
    if (!isConnected) return "Not Connected";
    
    try {
      final result = await _client!.run(command);
      return utf8.decode(result);
    } catch (e) {
      print("Command execution failed: $e");
      if (e.toString().contains("SocketException") || 
          e.toString().contains("Connection closed") || 
          e.toString().contains("Broken pipe")) {
        disconnect();
      }
      return "Error executing command: $e";
    }
  }

  /// Executes a command and streams stdout/stderr.
  /// Returns the exit code.
  Stream<List<int>> executeCommandStream(String command, {Function(int)? onExit}) async* {
    if (!isConnected) throw Exception("Not Connected");

    final session = await _client!.execute(command);
    
    // Merge stdout and stderr
    // Note: This is a simple merge. For strict separation, we'd need a different return type.
    // But for a terminal-like view, merging is usually fine or we can prefix.
    
    // We can't easily merge two streams into one generator without a controller or complex logic,
    // but dartssh2 sessions expose stdout and stderr streams.
    
    final controller = StreamController<List<int>>();
    
    session.stdout.listen((data) {
      controller.add(data);
    }, onError: (e) {
      controller.addError(e);
    });

    session.stderr.listen((data) {
      controller.add(data);
    }, onError: (e) {
      controller.addError(e);
    });

    session.done.then((_) {
      if (onExit != null && session.exitCode != null) {
        onExit(session.exitCode!);
      }
      controller.close();
    });

    yield* controller.stream;
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

  Future<void> disconnect({bool fromService = false}) async {
    _isConnecting = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _sftp?.close();
    _sftp = null;
    _client?.close();
    _client = null;
    _connectionStatus = "Disconnected";
    _connectedIp = null; // Clear IP on disconnect
    
    if (!fromService) {
      FlutterBackgroundService().invoke('disconnect');
    }

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
    return (await executeCommand(CarrotConstants.gitBranchCmd)).trim();
  }

  Future<String> getDongleId() async {
    try {
      return (await executeCommand(CarrotConstants.dongleIdCmd)).trim();
    } catch (e) {
      return "Unknown";
    }
  }

  Future<String> getSerial() async {
    try {
      return (await executeCommand(CarrotConstants.serialCmd)).trim();
    } catch (e) {
      return "Unknown";
    }
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
    return (await executeCommand(CarrotConstants.gitCommitCmd)).trim();
  }

  Future<String> getCarModel() async {
    // This is tricky, usually stored in params or log. 
    // Let's try to read a param if possible, or just return a placeholder.
    // For now, let's return "Unknown" or try to cat a file.
    return "Unknown"; 
  }

  Future<void> startDiscovery() async {
    // 1. Start UDP Listener (Passive)
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

    // 2. Start Active Subnet Scan
    _scanSubnet();
  }

  Future<void> _scanSubnet() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.isLoopback) continue;
          
          final ip = addr.address;
          final parts = ip.split('.');
          if (parts.length != 4) continue;

          final prefix = "${parts[0]}.${parts[1]}.${parts[2]}";
          
          // Scan 1-254 in batches to avoid FD limits
          for (int i = 1; i < 255; i += 20) {
            final futures = <Future>[];
            for (int j = 0; j < 20 && (i + j) < 255; j++) {
              final targetIp = "$prefix.${i + j}";
              if (targetIp == ip) continue; // Skip self
              futures.add(_checkPort(targetIp, 22));
            }
            await Future.wait(futures);
          }
        }
      }
    } catch (e) {
      print("Subnet scan error: $e");
    }
  }

  Future<void> _checkPort(String ip, int port) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 500));
      socket.destroy();
      _ipDiscoveryController.add(ip);
      print("Found openpilot at $ip");
    } catch (e) {
      // Connection failed or timed out
    }
  }

  void stopDiscovery() {
    _udpSocket?.close();
    _udpSocket = null;
  }

  // Git Status
  bool _hasGitUpdate = false;
  bool get hasGitUpdate => _hasGitUpdate;

  Future<void> checkGitUpdates() async {
    if (!isConnected) return;
    try {
      // Fetch latest info
      await executeCommand(CarrotConstants.gitFetchCmd);
      
      // Get current branch
      final currentBranch = (await executeCommand(CarrotConstants.gitBranchCmd)).trim();
      
      // Get local hash
      final localHash = (await executeCommand("cd ${CarrotConstants.openpilotPath} && git rev-parse HEAD")).trim();
      
      // Get remote hash
      final remoteHash = (await executeCommand("cd ${CarrotConstants.openpilotPath} && git rev-parse origin/$currentBranch")).trim();

      if (localHash.isNotEmpty && remoteHash.isNotEmpty && localHash != remoteHash) {
        _hasGitUpdate = true;
      } else {
        _hasGitUpdate = false;
      }
      notifyListeners();
    } catch (e) {
      print("Git update check failed: $e");
    }
  }

  @override
  void dispose() {
    stopDiscovery();
    _ipDiscoveryController.close();
    super.dispose();
  }
}
