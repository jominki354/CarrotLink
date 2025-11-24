import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/google_drive_service.dart';
import '../../widgets/custom_toast.dart';
import 'tabs/home_tab.dart';
import 'tabs/git_tab.dart';
import 'tabs/system_tab.dart';
import 'tabs/terminal_tab.dart';

import 'tabs/macro_tab.dart';
import 'tabs/file_explorer_tab.dart';
import 'settings_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  DateTime? _lastPressedAt;
  Timer? _reconnectTimer;

  final List<Widget> _tabs = const [
    HomeTab(),
    GitTab(),
    SystemTab(),
    TerminalTab(),
    FileExplorerTab(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _tryAutoConnect();
    _startReconnectLoop();
    
    // Start global backup monitoring
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      
      // Start monitoring immediately. The service handles connection checks internally.
      backupService.startMonitoring(ssh, driveService);
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Request Notification Permission (Android 13+)
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      
      final service = FlutterBackgroundService();
      // Ensure service is running
      if (!await service.isRunning()) {
        service.startService();
      }
      
      // Refresh service notification after permission grant
      service.invoke('updateContent', {'title': 'CarrotLink', 'content': '연결 대기 중...'});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to foreground, check connection
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected) {
        print("App resumed: Connection lost, trying to reconnect...");
        _tryAutoConnect();
      }
    }
  }

  void _startReconnectLoop() {
    _reconnectTimer?.cancel();
    // Check every 2 seconds
    _reconnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      final ssh = Provider.of<SSHService>(context, listen: false);
      if (!ssh.isConnected && !ssh.isConnecting) {
        await _tryAutoConnect(silent: true);
      }
    });
  }

  Future<void> _tryAutoConnect({bool silent = false}) async {
    if (!silent) {
      // Small delay to allow UI to settle and user to see initial state
      await Future.delayed(const Duration(milliseconds: 500));
    }

    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.isConnected || ssh.isConnecting) return;

    final storage = const FlutterSecureStorage();
    final ip = await storage.read(key: 'ssh_ip');
    final username = await storage.read(key: 'ssh_username');
    final key = await storage.read(key: 'user_private_key');
    final password = await storage.read(key: 'ssh_password');

    if (ip != null && username != null) {
      // Quick ping check before full connect attempt
      try {
        final socket = await Socket.connect(ip, 22, timeout: const Duration(milliseconds: 1000));
        socket.destroy();
        
        // If reachable, try full connection
        await ssh.connect(ip, username, password: password, privateKey: key);
        if (mounted && !silent) {
          CustomToast.show(context, '자동 연결됨: $ip');
        }
      } catch (e) {
        // Silent fail if unreachable
        if (!silent) print("Auto-connect failed: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("종료 확인"),
            content: const Text("앱을 종료하시겠습니까?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text("취소"),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text("종료"),
              ),
            ],
          ),
        );
        return shouldExit ?? false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('CarrotLink'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: _tabs,
        ),
        bottomNavigationBar: Consumer<SSHService>(
          builder: (context, ssh, child) {
            return NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (idx) {
                setState(() => _currentIndex = idx);
                if (idx == 1) ssh.checkGitUpdates();
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '홈',
                ),
                NavigationDestination(
                  icon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.source_outlined),
                  ),
                  selectedIcon: Badge(
                    isLabelVisible: ssh.hasGitUpdate,
                    label: const Text("!"),
                    child: const Icon(Icons.source),
                  ),
                  label: 'Git',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_system_daydream_outlined),
                  selectedIcon: Icon(Icons.settings_system_daydream),
                  label: '관리',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.terminal_outlined),
                  selectedIcon: Icon(Icons.terminal),
                  label: '터미널',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '파일',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
