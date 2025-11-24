import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ssh_service.dart';
import '../services/backup_service.dart';
import '../services/google_drive_service.dart';
import '../widgets/custom_toast.dart';
import 'permission_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('연결'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ConnectionSettingsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('백업'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupSettingsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('권한'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PermissionScreen(fromSettings: true))),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('정보'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InfoSettingsScreen())),
          ),
        ],
      ),
    );
  }
}

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  int _interval = 3;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _interval = prefs.getInt('backup_interval_minutes') ?? 3;
    });
  }

  Future<void> _saveSettings(int newValue) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('backup_interval_minutes', newValue);
    setState(() {
      _interval = newValue;
    });
    
    // Restart monitoring with new interval
    if (mounted) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final backupService = Provider.of<BackupService>(context, listen: false);
      final driveService = Provider.of<GoogleDriveService>(context, listen: false);
      backupService.startMonitoring(ssh, driveService);
      
      CustomToast.show(context, "설정이 저장되었습니다.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('백업 설정')),
      body: ListView(
        children: [
          ListTile(
            title: const Text("자동 백업 주기"),
            subtitle: Text("$_interval분 마다 변경 사항을 확인합니다."),
            trailing: DropdownButton<int>(
              value: _interval,
              items: const [
                DropdownMenuItem(value: 1, child: Text("1분")),
                DropdownMenuItem(value: 3, child: Text("3분")),
                DropdownMenuItem(value: 5, child: Text("5분")),
                DropdownMenuItem(value: 10, child: Text("10분")),
                DropdownMenuItem(value: 30, child: Text("30분")),
                DropdownMenuItem(value: 60, child: Text("1시간")),
              ],
              onChanged: (value) {
                if (value != null) {
                  _saveSettings(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ConnectionSettingsScreen extends StatefulWidget {
  const ConnectionSettingsScreen({super.key});

  @override
  State<ConnectionSettingsScreen> createState() => _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  final TextEditingController _ipController = TextEditingController(text: '');
  final TextEditingController _usernameController = TextEditingController(text: 'comma');
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController(text: 'comma');
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  bool _useKey = false;
  StreamSubscription? _discoverySubscription;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _startDiscovery();
  }

  void _startDiscovery() {
    final ssh = Provider.of<SSHService>(context, listen: false);
    ssh.startDiscovery();
    _discoverySubscription = ssh.ipDiscoveryStream.listen((ip) {
      if (mounted && _ipController.text.isEmpty) {
        setState(() {
          _ipController.text = ip;
        });
        CustomToast.show(context, "기기 발견: $ip");
      }
    });
  }

  @override
  void dispose() {
    final ssh = Provider.of<SSHService>(context, listen: false);
    ssh.stopDiscovery();
    _discoverySubscription?.cancel();
    _ipController.dispose();
    _usernameController.dispose();
    _keyController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final ip = await _storage.read(key: 'ssh_ip');
    final username = await _storage.read(key: 'ssh_username');
    final key = await _storage.read(key: 'user_private_key');
    final password = await _storage.read(key: 'ssh_password');
    
    if (mounted) {
      setState(() {
        if (ip != null) _ipController.text = ip;
        if (username != null) _usernameController.text = username;
        if (key != null) {
          _keyController.text = key;
          _useKey = true;
        }
        if (password != null) _passwordController.text = password;
      });
    }
  }

  Future<void> _connect() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      String? key = _useKey ? _keyController.text.trim() : null;
      String? password = !_useKey ? _passwordController.text : null;
      
      await ssh.connect(_ipController.text, _usernameController.text, password: password, privateKey: key);
      
      await _storage.write(key: 'ssh_ip', value: _ipController.text);
      await _storage.write(key: 'ssh_username', value: _usernameController.text);
      if (key != null) {
        await _storage.write(key: 'user_private_key', value: key);
      }
      if (password != null) {
        await _storage.write(key: 'ssh_password', value: password);
      }

      if (mounted) {
        CustomToast.show(context, '연결 성공');
        Navigator.pop(context); // Go back to settings menu or dashboard? Maybe stay here.
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, '연결 실패: $e', isError: true);
      }
    }
  }

  Future<void> _disconnect() async {
    await Provider.of<SSHService>(context, listen: false).disconnect();
    if (mounted) {
      CustomToast.show(context, '연결 해제됨');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ssh = Provider.of<SSHService>(context);
    
    return Scaffold(
      appBar: AppBar(title: const Text('연결 설정')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          TextField(
            controller: _ipController,
            decoration: const InputDecoration(labelText: 'IP 주소', prefixIcon: Icon(Icons.wifi)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: '사용자 이름', prefixIcon: Icon(Icons.person)),
          ),
          const SizedBox(height: 10),
          CheckboxListTile(
            title: const Text('SSH 키 사용'),
            value: _useKey,
            onChanged: (v) => setState(() => _useKey = v ?? false),
          ),
          if (_useKey)
            TextField(
              controller: _keyController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: '개인키 (PEM)', hintText: '-----BEGIN...'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            )
          else
             TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '비밀번호', prefixIcon: Icon(Icons.lock)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: ssh.isConnected ? null : _connect,
                  child: const Text('연결'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: ssh.isConnected ? _disconnect : null,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.withOpacity(0.2)),
                  child: const Text('연결 해제'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class InfoSettingsScreen extends StatefulWidget {
  const InfoSettingsScreen({super.key});

  @override
  State<InfoSettingsScreen> createState() => _InfoSettingsScreenState();
}

class _InfoSettingsScreenState extends State<InfoSettingsScreen> {
  String _currentVersion = "";
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _currentVersion = "${info.version}+${info.buildNumber}";
    });
  }

  Future<void> _checkForUpdate() async {
    setState(() => _isChecking = true);
    try {
      // Assuming the repo is jominki354/CarrotLink based on context
      final url = Uri.parse('https://api.github.com/repos/jominki354/CarrotLink/releases/latest');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String tagName = data['tag_name'] ?? "";
        // Simple version comparison (assuming tag is like v1.0.0 or 1.0.0)
        // This is a basic check. For robust semver, use a package.
        final latestVersion = tagName.replaceAll('v', '');
        final currentVersionBase = _currentVersion.split('+')[0];

        if (latestVersion != currentVersionBase && latestVersion.isNotEmpty) {
           if (!mounted) return;
           _showUpdateDialog(data);
        } else {
           if (!mounted) return;
           CustomToast.show(context, "최신 버전을 사용 중입니다.");
        }
      } else {
        if (mounted) CustomToast.show(context, "업데이트 확인 실패: ${response.statusCode}", isError: true);
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "오류 발생: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  void _showUpdateDialog(Map<String, dynamic> releaseData) {
    final String tagName = releaseData['tag_name'] ?? "Unknown";
    final String body = releaseData['body'] ?? "";
    final String htmlUrl = releaseData['html_url'] ?? "";
    final List assets = releaseData['assets'] ?? [];
    String? downloadUrl;
    
    // Find apk asset
    for (var asset in assets) {
      if (asset['name'].toString().endsWith('.apk')) {
        downloadUrl = asset['browser_download_url'];
        break;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("새로운 업데이트: $tagName"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(body),
              const SizedBox(height: 10),
              if (downloadUrl != null)
                const Text("APK 파일을 다운로드하여 설치할 수 있습니다.")
              else
                const Text("GitHub에서 릴리즈를 확인하세요."),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("닫기")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final url = Uri.parse(downloadUrl ?? htmlUrl);
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text("다운로드"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('정보')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('버전'),
            subtitle: Text(_currentVersion.isEmpty ? 'Loading...' : _currentVersion),
          ),
          ListTile(
            title: const Text('GitHub'),
            subtitle: const Text('당근파일럿'),
            onTap: () async {
              final url = Uri.parse('https://github.com/jominki354/CarrotLink');
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: ElevatedButton(
              onPressed: _isChecking ? null : _checkForUpdate,
              child: _isChecking 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
                : const Text('업데이트 확인'),
            ),
          ),
        ],
      ),
    );
  }
}

