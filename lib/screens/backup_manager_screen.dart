import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as path;
import 'package:googleapis/drive/v3.dart' as drive;
import '../../services/ssh_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/backup_service.dart';

class BackupManagerScreen extends StatefulWidget {
  const BackupManagerScreen({super.key});

  @override
  State<BackupManagerScreen> createState() => _BackupManagerScreenState();
}

class _BackupManagerScreenState extends State<BackupManagerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  // Local Backups State
  List<FileSystemEntity> _localBackups = [];
  bool _isLocalLoading = false;
  bool _localSortAscending = false;
  File? _comparingFile;
  String? _lastRestoredPath;
  final Set<String> _selectedLocalPaths = {};

  // Cloud Backups State
  List<drive.File> _cloudBackups = [];
  bool _isCloudLoading = false;
  bool _cloudSortAscending = false;
  final Set<String> _selectedCloudIds = {};

  // Common State
  bool _isSelectionMode = false;
  StreamSubscription? _backupSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabSelection);
    
    _loadLastRestored();
    _loadLocalBackups();
    // Cloud backups are loaded when tab is switched or manually refreshed to save API calls, 
    // but we can load them initially if signed in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser != null) {
        _loadCloudBackups();
        final backupService = Provider.of<BackupService>(context, listen: false);
        backupService.syncBackups(driveService);
      }
    });

    final backupService = Provider.of<BackupService>(context, listen: false);
    _backupSubscription = backupService.onBackupComplete.listen((_) {
      _loadLocalBackups();
      // Removed automatic snackbar to reduce annoyance
    });
  }

  void _handleTabSelection() {
    if (_tabController.indexIsChanging) {
      setState(() {
        _isSelectionMode = false;
        _selectedLocalPaths.clear();
        _selectedCloudIds.clear();
      });
      // Load cloud backups if switching to cloud tab and list is empty
      if (_tabController.index == 1 && _cloudBackups.isEmpty) {
        _loadCloudBackups();
      }
    } else {
      // Update UI when tab settles (for AppBar actions)
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _backupSubscription?.cancel();
    super.dispose();
  }

  // --- Local Backup Methods ---

  Future<void> _loadLocalBackups() async {
    if (_localBackups.isEmpty) setState(() => _isLocalLoading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!dir.existsSync()) dir.createSync();
      final files = dir.listSync();
      // Allow 12 to 14 digits for timestamp (minutes or seconds precision)
      final newFormatRegex = RegExp(r'^\d{12,14}\(.*\)(_auto)?\.json$');
      
      _localBackups = files.where((f) {
        final basename = path.basename(f.path);
        return (basename.startsWith('backup_') && basename.endsWith('.json')) || 
               newFormatRegex.hasMatch(basename);
      }).toList();
      
      _sortLocalBackups();
    } catch (e) {
      print("Error loading local backups: $e");
    } finally {
      if (mounted) setState(() => _isLocalLoading = false);
    }
  }

  void _sortLocalBackups() {
    _localBackups.sort((a, b) {
      final dateA = a.statSync().modified;
      final dateB = b.statSync().modified;
      return _localSortAscending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });
  }

  Future<void> _deleteSelectedLocalBackups() async {
    if (_selectedLocalPaths.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("선택 삭제"),
        content: Text("${_selectedLocalPaths.length}개의 로컬 백업을 삭제하시겠습니까?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("취소")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      int deletedCount = 0;
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      final pathsToDelete = List<String>.from(_selectedLocalPaths);
      
      // 1. Delete local files immediately and update UI
      for (final pathStr in pathsToDelete) {
        try {
          final file = File(pathStr);
          if (await file.exists()) {
            await file.delete();
            deletedCount++;
          }
        } catch (e) {
          print("Error deleting local file $pathStr: $e");
        }
      }

      // Update UI immediately
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$deletedCount개 삭제 완료. 클라우드 동기화 중...")));
        _toggleSelectionMode();
        _loadLocalBackups(); // Reload local list
      }

      // 2. Sync delete to cloud in background
      if (driveService.currentUser != null) {
        try {
          final cloudFiles = await driveService.listFiles();
          final futures = <Future>[];
          
          for (final pathStr in pathsToDelete) {
            final filename = path.basename(pathStr);
            try {
              final cloudFile = cloudFiles.firstWhere((f) => f.name == filename, orElse: () => drive.File());
              if (cloudFile.id != null) {
                futures.add(driveService.deleteFile(cloudFile.id!));
              }
            } catch (_) {}
          }
          
          if (futures.isNotEmpty) {
            await Future.wait(futures);
            if (mounted) {
               // Optional: Notify when cloud sync is done
               // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("클라우드 동기화 완료")));
            }
          }
        } catch (e) {
          print("Cloud sync error: $e");
        }
      }
    }
  }

  // --- Cloud Backup Methods ---

  Future<void> _loadCloudBackups() async {
    setState(() => _isCloudLoading = true);
    try {
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser == null) {
        _cloudBackups = [];
        return;
      }
      final files = await driveService.listFiles();
      _cloudBackups = files;
      _sortCloudBackups();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("클라우드 로드 실패: $e")));
    } finally {
      if (mounted) setState(() => _isCloudLoading = false);
    }
  }

  void _sortCloudBackups() {
    _cloudBackups.sort((a, b) {
      final dateA = a.createdTime ?? DateTime(1970);
      final dateB = b.createdTime ?? DateTime(1970);
      return _cloudSortAscending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });
  }

  Future<void> _deleteSelectedCloudBackups() async {
    if (_selectedCloudIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("선택 삭제"),
        content: Text("${_selectedCloudIds.length}개의 클라우드 백업을 삭제하시겠습니까?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("취소")),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      final idsToDelete = List<String>.from(_selectedCloudIds);
      
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("삭제 중...")));

      // Optimistic UI Update: Remove from list immediately
      setState(() {
        _cloudBackups.removeWhere((f) => f.id != null && idsToDelete.contains(f.id));
        _toggleSelectionMode(); // Exit selection mode
      });

      // Perform deletion in background (parallel)
      try {
        final futures = idsToDelete.map((id) => driveService.deleteFile(id));
        await Future.wait(futures);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${idsToDelete.length}개 삭제 완료")));
        }
      } catch (e) {
        print("Error deleting cloud files: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("일부 파일 삭제 실패: $e")));
          _loadCloudBackups(); // Revert/Reload on error
        }
      }
    }
  }

  // --- Common Methods ---

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      _selectedLocalPaths.clear();
      _selectedCloudIds.clear();
    });
  }

  void _toggleLocalSelection(String path) {
    setState(() {
      if (_selectedLocalPaths.contains(path)) {
        _selectedLocalPaths.remove(path);
      } else {
        _selectedLocalPaths.add(path);
      }
    });
  }

  void _toggleCloudSelection(String id) {
    setState(() {
      if (_selectedCloudIds.contains(id)) {
        _selectedCloudIds.remove(id);
      } else {
        _selectedCloudIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_tabController.index == 0) {
        _selectedLocalPaths.clear();
        for (var file in _localBackups) {
          _selectedLocalPaths.add(file.path);
        }
      } else {
        _selectedCloudIds.clear();
        for (var file in _cloudBackups) {
          if (file.id != null) _selectedCloudIds.add(file.id!);
        }
      }
    });
  }

  void _deselectAll() {
    setState(() {
      if (_tabController.index == 0) {
        _selectedLocalPaths.clear();
      } else {
        _selectedCloudIds.clear();
      }
    });
  }

  // ... Existing helper methods (_loadLastRestored, _setLastRestored, _createBackup, _deleteBackup, _restoreWithDiff, _performRestore, _uploadToDrive, _handleDriveConnection, _showBackupContents, _deleteCloudFile, _parseBackupInfo, _formatBackupName, _downloadFromDrive) ...
  // I need to keep these methods. I will copy them from the previous file content or just reference them if I'm using replace_string_in_file carefully.
  // Since I'm replacing the whole class structure, I need to include them.

  Future<void> _loadLastRestored() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _lastRestoredPath = prefs.getString('last_restored_backup');
    });
  }

  Future<void> _setLastRestored(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_restored_backup', path);
    setState(() {
      _lastRestoredPath = path;
    });
  }

  Future<void> _createBackup() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final backupService = Provider.of<BackupService>(context, listen: false);
    final driveService = Provider.of<GoogleDriveService>(context, listen: false);
    
    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }
    backupService.createBackup(ssh, driveService);
  }

  Future<void> _deleteBackup(File file) async {
    try {
      final filename = path.basename(file.path);
      await file.delete();
      
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      if (driveService.currentUser != null) {
        try {
          final files = await driveService.listFiles();
          final cloudFile = files.firstWhere((f) => f.name == filename, orElse: () => drive.File());
          if (cloudFile.id != null) {
            await driveService.deleteFile(cloudFile.id!);
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("클라우드 파일도 삭제되었습니다.")));
          }
        } catch (e) {
          print("Cloud delete sync failed: $e");
        }
      }

      await _loadLocalBackups();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("삭제되었습니다.")));
    } catch (e) {
      print("Delete error: $e");
    }
  }

  Future<void> _restoreWithDiff(File file) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }

    setState(() => _comparingFile = file);

    try {
      final content = await file.readAsString();
      final Map<String, dynamic> backupParams = jsonDecode(content);
      final Map<String, String> currentParams = {};
      
      final result = await ssh.executeCommand("grep -r . /data/params/d/");
      
      if (!result.startsWith("Error")) {
        final lines = result.split('\n');
        for (final line in lines) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            final path = parts[0];
            final val = parts.sublist(1).join(':');
            final key = path.split('/').last;
            currentParams[key] = val.trim();
          }
        }
      }

      final List<Map<String, String>> diffs = [];
      for (final key in backupParams.keys) {
        final backupVal = backupParams[key].toString();
        final currentVal = currentParams[key] ?? "(없음)";
        
        if (backupVal != currentVal) {
          diffs.add({
            'key': key,
            'backup': backupVal,
            'current': currentVal,
          });
        }
      }

      if (mounted) {
        setState(() => _comparingFile = null);
        
        if (diffs.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("변경된 설정이 없습니다.")));
          return;
        }

        showDialog(
          context: context,
          builder: (context) => _DiffRestoreDialog(diffs: diffs, onRestore: (selectedKeys) async {
            Navigator.pop(context);
            await _performRestore(backupParams, selectedKeys);
          }),
        );
      }

    } catch (e) {
      if (mounted) {
        setState(() => _comparingFile = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("비교 실패: $e")));
      }
    }
  }

  Future<void> _performRestore(Map<String, dynamic> backupParams, List<String> keysToRestore) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("복원 시작...")));

    try {
      int successCount = 0;
      for (final key in keysToRestore) {
        final value = backupParams[key];
        await ssh.executeCommand('echo -n "$value" > /data/params/d/$key');
        successCount++;
      }
      
      if (_comparingFile != null) {
        await _setLastRestored(_comparingFile!.path);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$successCount개 항목 복원 완료")));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("복원 실패: $e")));
      }
    }
  }

  Future<void> _uploadToDrive(File file) async {
    final driveService = Provider.of<GoogleDriveService>(context, listen: false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("구글 드라이브 업로드 중...")));
    try {
      await driveService.uploadFile(file);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("업로드 완료")));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("업로드 실패: $e")));
    }
  }

  Future<void> _showBackupContents(File file) async {
    try {
      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);
      final keys = data.keys.toList()..sort();

      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_formatBackupName(path.basename(file.path))),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("총 ${keys.length}개 항목"),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: keys.length,
                    itemBuilder: (context, index) {
                      final key = keys[index];
                      final value = data[key];
                      return ListTile(
                        title: Text(key, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: Text(value.toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("닫기")),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("파일 읽기 실패: $e")));
    }
  }

  Future<void> _downloadFromDrive(String fileId, String fileName) async {
    final driveService = Provider.of<GoogleDriveService>(context, listen: false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("다운로드 중...")));
    try {
      final dir = await getApplicationDocumentsDirectory();
      await driveService.downloadFile(fileId, '${dir.path}/$fileName');
      await _loadLocalBackups();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("다운로드 완료")));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("다운로드 실패: $e")));
    }
  }

  Future<void> _deleteCloudFile(String fileId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("삭제 확인"),
        content: const Text("정말 삭제하시겠습니까?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("취소")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("삭제")),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final driveService = Provider.of<GoogleDriveService>(context, listen: false);
        await driveService.deleteFile(fileId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("삭제되었습니다.")));
          _loadCloudBackups();
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("삭제 실패: $e")));
      }
    }
  }

  Map<String, dynamic> _parseBackupInfo(String name) {
    String dateStr = "";
    String branchName = "";
    bool isAuto = name.contains("_auto.json");
    
    String nameForParsing = name.replaceAll('.json', '').replaceAll('_auto', '');

    if (name.startsWith("backup_")) {
       final parts = nameForParsing.split('_');
       if (parts.length >= 3) {
         dateStr = "${parts[1]}${parts[2]}";
         if (parts.length > 3) branchName = parts.sublist(3).join('_');
       }
    } else {
       // Match 12 or 14 digits
       final regex = RegExp(r'^(\d{12,14})\((.*)\)$');
       final match = regex.firstMatch(nameForParsing);
       if (match != null) {
         dateStr = match.group(1)!;
         branchName = match.group(2)!;
       } else {
         final dateRegex = RegExp(r'^(\d{12,14})');
         final dateMatch = dateRegex.firstMatch(nameForParsing);
         if (dateMatch != null) {
            dateStr = dateMatch.group(1)!;
         }
       }
    }

    String displayName = name;
    try {
      if (dateStr.length == 14) {
        String yy = dateStr.substring(2, 4);
        String mm = dateStr.substring(4, 6);
        String dd = dateStr.substring(6, 8);
        String hh = dateStr.substring(8, 10);
        String min = dateStr.substring(10, 12);
        String sec = dateStr.substring(12, 14);
        displayName = "$yy년 $mm월 $dd일 $hh시 $min분 $sec초";
      } else if (dateStr.length == 12) {
        String yy = dateStr.substring(2, 4);
        String mm = dateStr.substring(4, 6);
        String dd = dateStr.substring(6, 8);
        String hh = dateStr.substring(8, 10);
        String min = dateStr.substring(10, 12);
        displayName = "$yy년 $mm월 $dd일 $hh시 $min분";
      } else if (dateStr.length == 14 || (dateStr.length == 15 && dateStr.contains('_'))) {
         String cleanDate = dateStr.replaceAll('_', '');
         if (cleanDate.length >= 12) {
            String yy = cleanDate.substring(2, 4);
            String mm = cleanDate.substring(4, 6);
            String dd = cleanDate.substring(6, 8);
            String hh = cleanDate.substring(8, 10);
            String min = cleanDate.substring(10, 12);
            displayName = "$yy년 $mm월 $dd일 $hh시 $min분";
         }
      }
    } catch (e) {
      displayName = name;
    }
    
    return {
      'displayName': displayName,
      'branch': branchName,
      'isAuto': isAuto,
    };
  }

  String _formatBackupName(String name) {
    final info = _parseBackupInfo(name);
    String result = info['branch'].isNotEmpty 
        ? "${info['displayName']} (${info['branch']})" 
        : info['displayName'];
        
    if (info['isAuto']) {
      result += " [자동]";
    }
    return result;
  }

  Future<void> _handleDriveConnection() async {
    final driveService = Provider.of<GoogleDriveService>(context, listen: false);
    if (driveService.currentUser == null) {
      await driveService.signIn();
    } else {
      await driveService.signOut();
    }
    setState(() {});
    if (driveService.currentUser != null) {
      _loadCloudBackups();
    }
  }

  @override
  Widget build(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final backupService = Provider.of<BackupService>(context);
    final isSignedIn = driveService.currentUser != null;
    final isLocalTab = _tabController.index == 0;
    
    final selectedCount = isLocalTab ? _selectedLocalPaths.length : _selectedCloudIds.length;
    final totalCount = isLocalTab ? _localBackups.length : _cloudBackups.length;

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_isSelectionMode) {
          _toggleSelectionMode();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _isSelectionMode 
              ? Text("$selectedCount개 선택됨")
              : const Text("백업 관리"),
          leading: _isSelectionMode 
              ? IconButton(icon: const Icon(Icons.close), onPressed: _toggleSelectionMode)
              : const BackButton(), // Explicitly set BackButton to avoid layout shift
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: "로컬 저장소"),
              Tab(text: "구글 드라이브"),
            ],
          ),
          actions: [
            if (_isSelectionMode) ...[
              IconButton(
                icon: const Icon(Icons.select_all),
                onPressed: selectedCount == totalCount ? _deselectAll : _selectAll,
                tooltip: "전체 선택/해제",
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: selectedCount == 0 ? null : (isLocalTab ? _deleteSelectedLocalBackups : _deleteSelectedCloudBackups),
                tooltip: "선택 삭제",
              ),
            ] else ...[
              IconButton(
                icon: const Icon(Icons.checklist),
                onPressed: _toggleSelectionMode,
                tooltip: "선택 모드",
              ),
              if (!isLocalTab)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadCloudBackups,
                  tooltip: "새로고침",
                ),
            ],
          ],
        ),
        body: Column(
          children: [
            if (backupService.isBackingUp)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(backupService.statusMessage, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: backupService.progress),
                  ],
                ),
              ),
            // Sort Toggle & Last Check Time
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Left: Last Check Time
                  if (backupService.lastCheckTime != null)
                    Row(
                      children: [
                        const Icon(Icons.access_time, size: 14, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          "확인: ${DateFormat('HH:mm:ss').format(backupService.lastCheckTime!)}",
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    )
                  else
                    const SizedBox(), // Placeholder to keep alignment if needed

                  // Right: Sort Button
                  TextButton.icon(
                    onPressed: _isSelectionMode ? null : () {
                      setState(() {
                        if (isLocalTab) {
                          _localSortAscending = !_localSortAscending;
                          _sortLocalBackups();
                        } else {
                          _cloudSortAscending = !_cloudSortAscending;
                          _sortCloudBackups();
                        }
                      });
                    },
                    icon: Icon((isLocalTab ? _localSortAscending : _cloudSortAscending) ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
                    label: Text((isLocalTab ? _localSortAscending : _cloudSortAscending) ? "오래된 순" : "최신 순"),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLocalList(),
                  _buildCloudList(isSignedIn),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: isLocalTab 
            ? FloatingActionButton(
                onPressed: backupService.isBackingUp ? null : _createBackup,
                child: const Icon(Icons.add),
              )
            : null,
      ),
    );
  }

  Widget _buildLocalList() {
    if (_isLocalLoading) return const Center(child: CircularProgressIndicator());
    if (_localBackups.isEmpty) return const Center(child: Text("백업 기록이 없습니다."));

    return ListView.builder(
      itemCount: _localBackups.length,
      itemBuilder: (context, index) {
        final file = _localBackups[index] as File;
        final name = path.basename(file.path);
        
        final info = _parseBackupInfo(name);
        final displayName = info['displayName'];
        final branch = info['branch'];
        final isAuto = info['isAuto'];

        final isComparing = _comparingFile == file;
        final isLastRestored = _lastRestoredPath == file.path;
        final number = index + 1;
        final isSelected = _selectedLocalPaths.contains(file.path);
        final isSignedIn = Provider.of<GoogleDriveService>(context).currentUser != null;

        return ListTile(
          onTap: _isSelectionMode 
              ? () => _toggleLocalSelection(file.path)
              : () => _showBackupContents(file),
          onLongPress: () {
            if (!_isSelectionMode) {
              _toggleSelectionMode();
              _toggleLocalSelection(file.path);
            }
          },
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: _isSelectionMode
                  ? Checkbox(
                      value: isSelected,
                      onChanged: (val) => _toggleLocalSelection(file.path),
                    )
                  : CircleAvatar(
                      backgroundColor: isLastRestored 
                          ? Colors.green 
                          : Theme.of(context).colorScheme.primaryContainer,
                      child: isLastRestored
                          ? const Icon(Icons.check, color: Colors.white)
                          : Text(
                              "$number",
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
            ),
          ),
          title: Text(
            displayName,
            style: TextStyle(
              fontWeight: isLastRestored ? FontWeight.bold : FontWeight.normal,
              color: isLastRestored ? Colors.green : null,
              fontSize: 14,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (branch.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(right: 8, top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(branch, style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  if (isAuto)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange[900],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text("자동", style: TextStyle(fontSize: 10, color: Colors.white)),
                    )
                  else
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange[900],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text("수동", style: TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                ],
              ),
              FutureBuilder<String>(
                future: file.length().then((len) => "${(len / 1024).toStringAsFixed(1)} KB"),
                builder: (context, snapshot) => Text(snapshot.data ?? "...", style: const TextStyle(fontSize: 11)),
              ),
            ],
          ),
          trailing: _isSelectionMode 
              ? null 
              : isComparing
                  ? const SizedBox(
                      width: 24, 
                      height: 24, 
                      child: CircularProgressIndicator(strokeWidth: 2)
                    )
                  : PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'upload') {
                          if (isSignedIn) _uploadToDrive(file);
                          else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("구글 로그인 필요")));
                        } else if (value == 'restore') {
                          _restoreWithDiff(file);
                        } else if (value == 'delete') {
                          _deleteBackup(file);
                        }
                      },
                      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'upload',
                          enabled: isSignedIn,
                          child: const Row(
                            children: [
                              Icon(Icons.cloud_upload, size: 20),
                              SizedBox(width: 8),
                              Text('업로드'),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'restore',
                          child: Row(
                            children: [
                              Icon(Icons.restore, size: 20),
                              SizedBox(width: 8),
                              Text('복원 (비교)'),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline, color: Colors.red, size: 20),
                              SizedBox(width: 8),
                              Text('삭제', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _buildCloudList(bool isSignedIn) {
    if (!isSignedIn) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("구글 드라이브에 연결되어 있지 않습니다."),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _handleDriveConnection,
              child: const Text("연결하기"),
            ),
          ],
        ),
      );
    }

    if (_isCloudLoading) return const Center(child: CircularProgressIndicator());
    if (_cloudBackups.isEmpty) return const Center(child: Text("클라우드 백업이 없습니다."));

    return ListView.builder(
      itemCount: _cloudBackups.length,
      itemBuilder: (context, index) {
        final file = _cloudBackups[index];
        final info = _parseBackupInfo(file.name ?? "Unknown");
        final displayName = info['displayName'];
        final branch = info['branch'];
        final isAuto = info['isAuto'];
        final number = index + 1;
        final isSelected = _selectedCloudIds.contains(file.id);

        return ListTile(
          onTap: _isSelectionMode 
              ? () => _toggleCloudSelection(file.id!)
              : null,
          onLongPress: () {
            if (!_isSelectionMode) {
              _toggleSelectionMode();
              _toggleCloudSelection(file.id!);
            }
          },
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: _isSelectionMode
                  ? Checkbox(
                      value: isSelected,
                      onChanged: (val) => _toggleCloudSelection(file.id!),
                    )
                  : CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                      child: Text(
                        "$number",
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
          ),
          title: Text(displayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (branch.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(right: 8, top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(branch, style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  if (isAuto)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange[900],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text("자동", style: TextStyle(fontSize: 10, color: Colors.white)),
                    )
                  else
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.deepOrange[900],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text("수동", style: TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                ],
              ),
              if (file.size != null)
                Text("${(int.parse(file.size!) / 1024).toStringAsFixed(1)} KB", style: const TextStyle(fontSize: 11)),
            ],
          ),
          trailing: _isSelectionMode 
              ? null 
              : PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'download') {
                      _downloadFromDrive(file.id!, file.name!);
                    } else if (value == 'delete') {
                      _deleteCloudFile(file.id!);
                    }
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'download',
                      child: Row(
                        children: [
                          Icon(Icons.download, size: 20),
                          SizedBox(width: 8),
                          Text('다운로드'),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          SizedBox(width: 8),
                          Text('삭제', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _DiffRestoreDialog extends StatefulWidget {
  final List<Map<String, String>> diffs;
  final Function(List<String>) onRestore;

  const _DiffRestoreDialog({required this.diffs, required this.onRestore});

  @override
  State<_DiffRestoreDialog> createState() => _DiffRestoreDialogState();
}

class _DiffRestoreDialogState extends State<_DiffRestoreDialog> {
  final Set<String> _selectedKeys = {};

  @override
  void initState() {
    super.initState();
    // Default select all
    for (var diff in widget.diffs) {
      _selectedKeys.add(diff['key']!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("변경 사항 비교"),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("총 ${widget.diffs.length}개 항목"),
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selectedKeys.length == widget.diffs.length) {
                        _selectedKeys.clear();
                      } else {
                        for (var diff in widget.diffs) {
                          _selectedKeys.add(diff['key']!);
                        }
                      }
                    });
                  },
                  child: Text(_selectedKeys.length == widget.diffs.length ? "전체 해제" : "전체 선택"),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: widget.diffs.length,
                itemBuilder: (context, index) {
                  final diff = widget.diffs[index];
                  final key = diff['key']!;
                  final backupVal = diff['backup']!;
                  final currentVal = diff['current']!;
                  final isSelected = _selectedKeys.contains(key);

                  return CheckboxListTile(
                    value: isSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedKeys.add(key);
                        } else {
                          _selectedKeys.remove(key);
                        }
                      });
                    },
                    title: Text(key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("백업: $backupVal", style: const TextStyle(color: Colors.green, fontSize: 12)),
                        Text("현재: $currentVal", style: const TextStyle(color: Colors.red, fontSize: 12)),
                      ],
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("취소"),
        ),
        ElevatedButton(
          onPressed: _selectedKeys.isEmpty ? null : () => widget.onRestore(_selectedKeys.toList()),
          child: Text("${_selectedKeys.length}개 복원"),
        ),
      ],
    );
  }
}
