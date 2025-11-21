import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
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

  final List<Widget> _tabs = const [
    HomeTab(),
    GitTab(),
    SystemTab(),
    TerminalTab(),
    MacroTab(),
    FileExplorerTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.source_outlined),
            selectedIcon: Icon(Icons.source),
            label: 'Git',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_system_daydream_outlined),
            selectedIcon: Icon(Icons.settings_system_daydream),
            label: '시스템',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: '터미널',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_button_outlined),
            selectedIcon: Icon(Icons.smart_button),
            label: '매크로',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '파일',
          ),
        ],
      ),
    );
  }
}
