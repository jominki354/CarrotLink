import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../services/ssh_service.dart';
import '../../services/backup_service.dart';
import '../../services/google_drive_service.dart';
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

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;
  DateTime? _lastPressedAt;

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
    _tryAutoConnect();
    
    // Start global backup monitoring
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      
      // Start monitoring immediately. The service handles connection checks internally.
      backupService.startMonitoring(ssh, driveService);
    });
  }

  Future<void> _tryAutoConnect() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.isConnected) return;

    final storage = const FlutterSecureStorage();
    final ip = await storage.read(key: 'ssh_ip');
    final username = await storage.read(key: 'ssh_username');
    final key = await storage.read(key: 'user_private_key');
    final password = await storage.read(key: 'ssh_password');

    if (ip != null && username != null) {
      try {
        await ssh.connect(ip, username, password: password, privateKey: key);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('자동 연결됨: $ip')),
          );
        }
      } catch (e) {
        print("Auto-connect failed: $e");
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
