import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dashboard_screen.dart';
import 'permission_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _version = "";

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _checkFirstRun();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = "v${info.version}+${info.buildNumber}";
      });
    }
  }

  Future<void> _checkFirstRun() async {
    // Wait at least 1.5 seconds for splash effect
    await Future.delayed(const Duration(milliseconds: 1500));

    final prefs = await SharedPreferences.getInstance();
    final isFirstRun = prefs.getBool('is_first_run') ?? true;

    if (mounted) {
      if (isFirstRun) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const PermissionScreen()),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const DashboardScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo
            Image.asset(
              'assets/icon.png',
              width: 120,
              height: 120,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(Icons.directions_car, size: 120, color: Color(0xFFFF6D00));
              },
            ),
            const SizedBox(height: 24),
            // App Name
            Text(
              'CarrotLink',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: const Color(0xFFFF6D00),
              ),
            ),
            const SizedBox(height: 8),
            // Version
            Text(
              _version,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
