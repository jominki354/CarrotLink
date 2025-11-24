import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dashboard_screen.dart';

class PermissionScreen extends StatefulWidget {
  final bool fromSettings;

  const PermissionScreen({super.key, this.fromSettings = false});

  @override
  State<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends State<PermissionScreen> {
  bool _notificationGranted = false;
  bool _batteryGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final notificationStatus = await Permission.notification.status;
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;

    if (mounted) {
      setState(() {
        _notificationGranted = notificationStatus.isGranted;
        _batteryGranted = batteryStatus.isGranted;
      });
    }
  }

  Future<void> _requestNotification() async {
    final status = await Permission.notification.request();
    if (mounted) {
      setState(() {
        _notificationGranted = status.isGranted;
      });
    }
  }

  Future<void> _requestBattery() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    if (mounted) {
      setState(() {
        _batteryGranted = status.isGranted;
      });
    }
  }

  Future<void> _finish() async {
    if (!widget.fromSettings) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_first_run', false);
      
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const DashboardScreen()),
        );
      }
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.fromSettings 
          ? AppBar(title: const Text("권한 설정")) 
          : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.fromSettings) ...[
                const SizedBox(height: 40),
                const Icon(Icons.security, size: 80, color: Color(0xFFFF6D00)),
                const SizedBox(height: 24),
                Text(
                  "필수 권한 요청",
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  "안정적인 백그라운드 연결과 백업을 위해\n다음 권한들이 필요합니다.",
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
              ],
              
              _buildPermissionItem(
                icon: Icons.notifications_active,
                title: "알림 권한",
                description: "백그라운드 서비스 상태를 표시하기 위해 필요합니다.",
                isGranted: _notificationGranted,
                onTap: _requestNotification,
              ),
              const SizedBox(height: 16),
              _buildPermissionItem(
                icon: Icons.battery_alert,
                title: "배터리 최적화 제외",
                description: "화면이 꺼져도 연결이 끊기지 않도록 합니다.",
                isGranted: _batteryGranted,
                onTap: _requestBattery,
              ),

              const Spacer(),
              
              ElevatedButton(
                onPressed: _finish,
                child: Text(widget.fromSettings ? "완료" : "시작하기"),
              ),
              if (!widget.fromSettings)
                TextButton(
                  onPressed: _finish,
                  child: const Text("나중에 설정하기", style: TextStyle(color: Colors.grey)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionItem({
    required IconData icon,
    required String title,
    required String description,
    required bool isGranted,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: isGranted 
            ? Border.all(color: Colors.green.withOpacity(0.5)) 
            : null,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isGranted ? Colors.green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isGranted ? Icons.check : icon,
              color: isGranted ? Colors.green : Colors.grey,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ],
            ),
          ),
          if (!isGranted)
            TextButton(
              onPressed: onTap,
              child: const Text("허용"),
            ),
        ],
      ),
    );
  }
}
