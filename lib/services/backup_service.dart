import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ssh_service.dart';
import 'google_drive_service.dart';

class BackupService extends ChangeNotifier {
  bool _isBackingUp = false;
  double _progress = 0.0;
  String _statusMessage = "";
  
  bool get isBackingUp => _isBackingUp;
  double get progress => _progress;
  String get statusMessage => _statusMessage;

  // Event to notify when a backup is completed so screens can refresh lists
  final StreamController<void> _backupCompleteController = StreamController<void>.broadcast();
  Stream<void> get onBackupComplete => _backupCompleteController.stream;

  Timer? _monitorTimer;
  String? _lastParamsHash;
  DateTime? _lastCheckTime;
  DateTime? get lastCheckTime => _lastCheckTime;

  void _updateNotification(String content) {
    final service = FlutterBackgroundService();
    service.invoke("updateNotification", {"content": content});
  }

  Future<void> startMonitoring(SSHService ssh, GoogleDriveService driveService) async {
    _monitorTimer?.cancel();
    
    // Start Background Service to keep app alive
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    _updateNotification("모니터링 시작됨");

    final prefs = await SharedPreferences.getInstance();
    final intervalMinutes = prefs.getInt('backup_interval_minutes') ?? 3;
    
    print("Starting backup monitoring with interval: $intervalMinutes minutes");

    _monitorTimer = Timer.periodic(Duration(minutes: intervalMinutes), (timer) async {
      if (!ssh.isConnected || _isBackingUp) return;
      
      try {
        // Check if params changed by hashing all files in /data/params/d/
        // Using md5sum on all files and then hashing the result
        // This command lists all files, calculates md5 for each, sorts them (for consistency), and hashes the result.
        final cmd = "find /data/params/d/ -type f -exec md5sum {} + | sort | md5sum";
        final result = await ssh.executeCommand(cmd);
        
        _lastCheckTime = DateTime.now();
        notifyListeners(); // Update UI with last check time
        _updateNotification("마지막 확인: ${DateFormat('HH:mm:ss').format(_lastCheckTime!)}");

        if (!result.startsWith("Error") && result.isNotEmpty) {
          final currentHash = result.trim();
          
          // Initialize hash if null (first run)
          if (_lastParamsHash == null) {
             _lastParamsHash = currentHash;
             return;
          }

          if (_lastParamsHash != currentHash) {
            print("Params changed! Auto-backing up...");
            await createBackup(ssh, driveService, isAuto: true);
            _lastParamsHash = currentHash; // Update hash after backup
          }
        }
      } catch (e) {
        print("Monitor error: $e");
      }
    });
  }

  void stopMonitoring() {
    _monitorTimer?.cancel();
    _monitorTimer = null;
    
    final service = FlutterBackgroundService();
    service.invoke("stopService");
  }

  Future<void> createBackup(SSHService ssh, GoogleDriveService driveService, {bool isAuto = false}) async {
    if (_isBackingUp) return;

    _isBackingUp = true;
    _progress = 0.0;
    _statusMessage = "파라미터 목록 가져오는 중...";
    notifyListeners();
    _updateNotification("백업 진행 중...");

    try {
      // Get branch name
      String branch = "unknown";
      try {
        final branchResult = await ssh.executeCommand("cd /data/openpilot && git rev-parse --abbrev-ref HEAD");
        if (!branchResult.startsWith("Error")) {
          branch = branchResult.trim();
        }
      } catch (_) {}

      final managerContent = await ssh.executeCommand("cat /data/openpilot/system/manager/manager.py");
      if (managerContent.isEmpty) throw Exception("manager.py를 읽을 수 없습니다.");

      final keys = <String>[];
      final defaultParamsRegex = RegExp(r'default_params\s*(?::[\s\S]*?)?=\s*\[([\s\S]*?)\]');
      final match = defaultParamsRegex.firstMatch(managerContent);

      if (match != null) {
        final listContent = match.group(1)!;
        final keyRegex = RegExp("\\(\\s*['\"]([^'\"]+)['\"]\\s*,");
        final keyMatches = keyRegex.allMatches(listContent);
        for (final m in keyMatches) {
          keys.add(m.group(1)!);
        }
      }

      final Map<String, String> backupData = {};
      int current = 0;
      final total = keys.length;

      // Optimize: Read all params in one go if possible, but for now keep loop or optimize later.
      // To speed up, we can try to read all at once, but let's stick to reliability for now or use the grep trick here too?
      // The user complained about comparison speed, not backup speed. But backup speed is also important.
      // Let's use the grep trick here too for speed!
      
      _statusMessage = "데이터 읽는 중...";
      notifyListeners();

      // Fetch all params at once using grep
      final allParamsResult = await ssh.executeCommand("grep -r . /data/params/d/");
      final Map<String, String> currentParams = {};
      
      if (!allParamsResult.startsWith("Error")) {
        final lines = allParamsResult.split('\n');
        for (final line in lines) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            final path = parts[0];
            final val = parts.sublist(1).join(':'); // Value might contain :
            final key = path.split('/').last;
            currentParams[key] = val;
          }
        }
      }

      // Filter only keys present in manager.py
      for (final key in keys) {
        if (currentParams.containsKey(key)) {
          backupData[key] = currentParams[key]!;
        }
      }
      
      // If grep failed or returned nothing (e.g. no permissions?), fallback to loop?
      // But grep should work if cat works.
      // If backupData is empty, maybe try the loop method as fallback.
      if (backupData.isEmpty && keys.isNotEmpty) {
         for (final key in keys) {
          current++;
          _progress = current / total;
          _statusMessage = "백업 중 (Fallback)... ($current/$total)";
          notifyListeners();

          final value = await ssh.executeCommand("cat /data/params/d/$key");
          if (!value.startsWith("Error")) {
            backupData[key] = value.trim();
          }
        }
      }

      final dir = await getApplicationDocumentsDirectory();

      // Check for duplicates (Skip if identical to last backup)
      if (backupData.isNotEmpty) {
        try {
          final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
          if (files.isNotEmpty) {
            files.sort((a, b) => b.path.compareTo(a.path)); // Newest first
            final lastFile = files.first;
            final lastContent = await lastFile.readAsString();
            final Map<String, dynamic> lastJson = jsonDecode(lastContent);
            
            bool isSame = true;
            if (lastJson.length != backupData.length) {
              isSame = false;
            } else {
              for (final key in backupData.keys) {
                if (lastJson[key] != backupData[key]) {
                  isSame = false;
                  break;
                }
              }
            }

            if (isSame) {
              print("Backup skipped: Content identical to last backup (${lastFile.path})");
              return;
            }
          }
        } catch (e) {
          print("Duplicate check failed: $e");
        }
      }

      // New format: 20251212173055(BranchName).json or 20251212173055(BranchName)_auto.json
      // Added seconds to prevent overwriting if multiple backups are made within a minute
      final timestamp = DateFormat('yyyyMMddHHmmss').format(DateTime.now());
      final safeBranch = branch.replaceAll(RegExp(r'[^\w\-]'), '_');
      final suffix = isAuto ? "_auto" : "";
      final fileName = '$timestamp($safeBranch)$suffix.json';
      final file = File('${dir.path}/$fileName');
      
      // Ensure we don't write if something went wrong or empty
      if (backupData.isNotEmpty) {
        await file.writeAsString(jsonEncode(backupData));
        
        // Auto Upload
        // Try to ensure we are signed in if possible, or just check current state
        if (driveService.currentUser != null) {
          _statusMessage = "클라우드 업로드 중...";
          notifyListeners();
          try {
            await driveService.uploadFile(file);
          } catch (e) {
            print("Auto upload failed: $e");
            // Don't fail the whole backup just because upload failed
          }
        } else {
           print("Auto upload skipped: Not signed in");
        }

        _backupCompleteController.add(null); // Notify listeners
      }

    } catch (e) {
      _statusMessage = "백업 실패: $e";
      print("Backup error: $e");
    } finally {
      _isBackingUp = false;
      _progress = 0.0;
      _statusMessage = "";
      notifyListeners();
      if (_lastCheckTime != null) {
        _updateNotification("대기 중 (마지막 확인: ${DateFormat('HH:mm:ss').format(_lastCheckTime!)})");
      } else {
        _updateNotification("대기 중");
      }
    }
  }

  Future<void> syncBackups(GoogleDriveService driveService) async {
    if (_isBackingUp) return;
    if (driveService.currentUser == null) return;

    _isBackingUp = true;
    _statusMessage = "동기화 중...";
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!dir.existsSync()) dir.createSync();
      
      // 1. List Local Files
      final localFiles = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      final localFileNames = localFiles.map((f) => f.path.split(Platform.pathSeparator).last).toSet();

      // 2. List Cloud Files
      final cloudFiles = await driveService.listFiles();
      final cloudFileNames = cloudFiles.map((f) => f.name).whereType<String>().toSet();

      // 3. Download Missing (Cloud -> Local)
      for (final cloudFile in cloudFiles) {
        if (cloudFile.name != null && !localFileNames.contains(cloudFile.name)) {
          _statusMessage = "다운로드 중: ${cloudFile.name}";
          notifyListeners();
          try {
            await driveService.downloadFile(cloudFile.id!, '${dir.path}/${cloudFile.name}');
          } catch (e) {
            print("Sync download failed for ${cloudFile.name}: $e");
          }
        }
      }

      // 4. Upload Missing (Local -> Cloud)
      for (final localFile in localFiles) {
        final name = localFile.path.split(Platform.pathSeparator).last;
        if (!cloudFileNames.contains(name)) {
          _statusMessage = "업로드 중: $name";
          notifyListeners();
          try {
            await driveService.uploadFile(localFile);
          } catch (e) {
            print("Sync upload failed for $name: $e");
          }
        }
      }
      
      _backupCompleteController.add(null); // Refresh UI

    } catch (e) {
      print("Sync error: $e");
    } finally {
      _isBackingUp = false;
      _statusMessage = "";
      notifyListeners();
    }
  }
}
