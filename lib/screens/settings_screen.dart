import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart'; // Added for Clipboard
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ssh_service.dart';
import '../services/backup_service.dart';
import '../services/google_drive_service.dart';
import '../services/update_service.dart';
import '../services/github_service.dart';
import '../services/ssh_key_helper.dart';
import 'github_verification_screen.dart';
import 'github_login_screen.dart';
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
            leading: const Icon(Icons.share),
            title: const Text('공유'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareSettingsScreen())),
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
  final TextEditingController _portController = TextEditingController(text: '22');
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final GitHubService _githubService = GitHubService();
  bool _useKey = false;
  bool _isGitHubLoggedIn = false;
  List<Map<String, dynamic>> _keys = [];
  String? _currentPublicKey;
  StreamSubscription? _discoverySubscription;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkGitHubLogin();
    _startDiscovery();
    _keyController.addListener(_onKeyChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    final ssh = Provider.of<SSHService>(context, listen: false);
    ssh.stopDiscovery();
    _discoverySubscription?.cancel();
    _keyController.removeListener(_onKeyChanged);
    _ipController.dispose();
    _usernameController.dispose();
    _keyController.dispose();
    _passwordController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _onKeyChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _updateCurrentPublicKey();
    });
  }

  Future<void> _updateCurrentPublicKey() async {
    if (!mounted) return;
    if (_keyController.text.isEmpty) {
      if (_currentPublicKey != null) setState(() => _currentPublicKey = null);
      return;
    }
    
    final pub = await _githubService.getPublicKeyFromPrivateKey(_keyController.text);
    if (mounted && pub != _currentPublicKey) {
      setState(() => _currentPublicKey = pub);
    }
  }

  Future<void> _checkGitHubLogin() async {
    final loggedIn = await _githubService.isLoggedIn();
    if (mounted) {
      setState(() => _isGitHubLoggedIn = loggedIn);
      if (loggedIn) {
        _loadKeys();
      }
    }
  }

  Future<void> _loadKeys() async {
    try {
      final keys = await _githubService.listPublicKeys();
      if (mounted) {
        setState(() {
          _keys = keys;
        });
        _updateCurrentPublicKey();
      }
    } catch (e) {
      debugPrint("Failed to load keys: $e");
    }
  }

  Future<void> _deleteKey(int id) async {
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("키 삭제"),
          content: const Text("정말로 이 키를 GitHub에서 삭제하시겠습니까?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("취소")),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("삭제")),
          ],
        ),
      );

      if (confirm == true) {
        await _githubService.deletePublicKey(id);
        CustomToast.show(context, "키가 삭제되었습니다.");
        _loadKeys();
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "삭제 실패: $e", isError: true);
    }
  }

  Future<void> _loginToGitHub() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("GitHub 로그인 방식 선택"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.touch_app),
              title: const Text("간편 로그인 (권장)"),
              subtitle: const Text("브라우저 인증 (Device Flow)"),
              onTap: () {
                Navigator.pop(context);
                _startDeviceFlow();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.vpn_key),
              title: const Text("토큰 직접 입력"),
              subtitle: const Text("Personal Access Token (PAT)"),
              onTap: () {
                Navigator.pop(context);
                _showPatDialog();
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
        ],
      ),
    );
  }

  Future<void> _showPatDialog() async {
    final tokenController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("토큰 직접 입력"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("GitHub Personal Access Token (PAT)을 입력하세요.\n필수 권한: admin:public_key"),
            const SizedBox(height: 10),
            TextField(
              controller: tokenController,
              decoration: const InputDecoration(
                labelText: "Token",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => launchUrl(Uri.parse("https://github.com/settings/tokens/new?scopes=admin:public_key&description=CarrotLink")),
              child: const Text("토큰 생성 페이지 열기"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          FilledButton(
            onPressed: () async {
              if (tokenController.text.isNotEmpty) {
                await _githubService.saveToken(tokenController.text.trim());
                await _checkGitHubLogin();
                if (mounted) {
                  Navigator.pop(context);
                  CustomToast.show(context, "GitHub 로그인 성공");
                }
              }
            },
            child: const Text("로그인"),
          ),
        ],
      ),
    );
  }

  Future<void> _startDeviceFlow() async {
    final token = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => GithubLoginScreen(githubService: _githubService),
      ),
    );

    if (token != null && mounted) {
      _handleAuthSuccess(token);
    }
  }

  Future<void> _showKeyGenerationDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("SSH 키 생성 및 등록"),
        content: const Text("키를 생성후 앱과 온라인에 등록하시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("아니오"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _generateAndRegisterKey();
            },
            child: const Text("예"),
          ),
        ],
      ),
    );
  }

  Future<void> _generateAndRegisterKey() async {
    try {
      CustomToast.show(context, "키 생성 중... (시간이 걸릴 수 있습니다)");
      await Future.delayed(const Duration(milliseconds: 100));
      
      final keyPair = await _githubService.generateRSAKeyPair();
      
      if (mounted) CustomToast.show(context, "GitHub에 등록 중...");
      final title = "CarrotLink Key ${DateTime.now().millisecondsSinceEpoch}";
      await _githubService.uploadPublicKey(title, keyPair['public']!);
      await _loadKeys();
      
      if (mounted) {
        setState(() {
          _keyController.text = keyPair['private']!;
          _useKey = true;
        });
        
        // Ask to install key to device
        String targetIp = _ipController.text;
        String targetUser = _usernameController.text.isEmpty ? 'root' : _usernameController.text;
        
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("키 설치"),
            content: Text(
              "GitHub에 키가 등록되었습니다.\n\n"
              "기기에 바로 접속하려면 이 키를 기기에도 설치해야 합니다.\n\n"
              "대상: $targetUser@${targetIp.isEmpty ? '(IP 미설정)' : targetIp}\n"
              "비밀번호: ${_passwordController.text.isEmpty ? '(비어있음)' : '******'}\n\n"
              "현재 입력된 연결 정보를 사용하여 설치하시겠습니까?"
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("나중에"),
              ),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (targetIp.isEmpty) {
                    CustomToast.show(context, "IP 주소가 설정되지 않았습니다. 연결 설정에서 IP를 입력해주세요.", isError: true);
                    return;
                  }
                  await _installKeyToDevice(keyPair['public']!);
                },
                child: const Text("설치하기"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "오류: $e", isError: true);
    }
  }

  Future<void> _installKeyToDevice(String publicKey) async {
    if (_ipController.text.isEmpty) {
      CustomToast.show(context, "IP 주소를 입력해주세요.", isError: true);
      return;
    }

    // Use password from controller or default 'comma'
    String password = _passwordController.text;
    if (password.isEmpty) password = 'comma';

    CustomToast.show(context, "기기에 키 설치 중...");
    
    try {
      final helper = SSHKeyHelper();
      final success = await helper.installKey(
        _ipController.text,
        int.tryParse(_portController.text) ?? 22,
        _usernameController.text.isEmpty ? 'root' : _usernameController.text, // Default to root if empty, or use controller
        password, 
        publicKey
      );

      if (mounted) {
        if (success) {
          CustomToast.show(context, "키 설치 완료! 이제 연결할 수 있습니다.");
          // Optionally auto-connect here
        } else {
          CustomToast.show(context, "키 설치 실패. 비밀번호나 IP를 확인하세요.", isError: true);
        }
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "설치 오류: $e", isError: true);
    }
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

  // dispose removed (duplicate)

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

  Future<void> _handleAuthSuccess(String token) async {
    try {
      await _githubService.saveToken(token);
      await _checkGitHubLogin();
      if (mounted) {
        CustomToast.show(context, "GitHub 로그인 성공");
        _showKeyGenerationDialog();
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "로그인 처리 중 오류 발생: $e", isError: true);
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
          TextField(
            controller: _portController,
            decoration: const InputDecoration(labelText: '포트', prefixIcon: Icon(Icons.portable_wifi_off)),
            keyboardType: TextInputType.number,
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
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          Text("GitHub 연동 (SSH 키 관리)", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (!_isGitHubLoggedIn)
            ElevatedButton.icon(
              onPressed: _loginToGitHub,
              icon: const Icon(Icons.login),
              label: const Text("GitHub 로그인 (PAT)"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, foregroundColor: Colors.white),
            )
          else
            Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    const SizedBox(width: 8),
                    const Text("GitHub 로그인됨"),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await _githubService.clearToken();
                        await _checkGitHubLogin();
                      },
                      child: const Text("로그아웃"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _generateAndRegisterKey,
                    icon: const Icon(Icons.vpn_key),
                    label: const Text("새 SSH 키 생성 및 GitHub 등록"),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  "새로운 RSA 키 쌍을 생성하고 공개키를 GitHub 계정에 자동으로 등록합니다. 개인키는 위 입력창에 자동 입력됩니다.",
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          if (_isGitHubLoggedIn && _keys.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text("등록된 SSH 키 목록", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _keys.length,
              itemBuilder: (context, index) {
                final key = _keys[index];
                final keyString = key['key'] as String? ?? '';
                // Check if this key matches the current private key
                // The key string from GitHub is "ssh-rsa AAA... comment"
                // _currentPublicKey is also "ssh-rsa AAA... comment" (hopefully)
                // We should compare the key part (middle part)
                
                bool isActive = false;
                if (_currentPublicKey != null && keyString.isNotEmpty) {
                   final parts1 = _currentPublicKey!.split(' ');
                   final parts2 = keyString.split(' ');
                   if (parts1.length >= 2 && parts2.length >= 2) {
                     isActive = parts1[1] == parts2[1];
                   }
                }

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isActive ? Icons.vpn_key : Icons.vpn_key_outlined, 
                    size: 20,
                    color: isActive ? Colors.green : null,
                  ),
                  title: Text(
                    key['title'] ?? 'No Title', 
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive ? Colors.green : null,
                    ),
                  ),
                  subtitle: Text(
                    keyString.length > 20 
                        ? keyString.substring(0, 30) + '...' 
                        : keyString,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteKey(key['id']),
                  ),
                  dense: true,
                  onTap: () {
                    if (isActive) {
                      CustomToast.show(context, "현재 사용 중인 키입니다.");
                    } else {
                      CustomToast.show(context, "GitHub에는 공개키만 저장되어 있어 개인키를 가져올 수 없습니다.");
                    }
                  },
                );
              },
            ),
          ],
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
  void _showUpdateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => const UpdateDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updateService = context.watch<UpdateService>();

    return Scaffold(
      appBar: AppBar(title: const Text('정보')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('버전'),
            subtitle: Text(updateService.currentVersion.isEmpty ? 'Loading...' : updateService.currentVersion),
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
          ListTile(
            title: const Text('업데이트 채널'),
            subtitle: Text(updateService.channel == 'stable' ? 'Stable (안정 버전)' : 'Dev (개발 버전)'),
            trailing: DropdownButton<String>(
              value: updateService.channel,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'stable', child: Text('Stable')),
                DropdownMenuItem(value: 'dev', child: Text('Dev')),
              ],
              onChanged: (value) {
                if (value != null) {
                  context.read<UpdateService>().setChannel(value);
                }
              },
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: ElevatedButton(
              onPressed: updateService.isChecking
                  ? null
                  : () async {
                      if (updateService.isDownloading) {
                        _showUpdateDialog(context);
                        return;
                      }
                      final hasUpdate = await context.read<UpdateService>().checkForUpdate();
                      if (context.mounted) {
                        if (hasUpdate) {
                          _showUpdateDialog(context);
                        } else {
                          CustomToast.show(context, "최신 버전을 사용 중입니다.");
                        }
                      }
                    },
              child: updateService.isChecking
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('업데이트 확인'),
            ),
          ),
        ],
      ),
    );
  }
}

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final updateService = context.watch<UpdateService>();
    final release = updateService.latestRelease;

    if (release == null) return const SizedBox.shrink();

    final tagName = release['tag_name'];
    final body = release['body'];

    return AlertDialog(
      title: Text("업데이트: $tagName"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body ?? ""),
            const SizedBox(height: 20),
            if (updateService.isDownloading) ...[
              LinearProgressIndicator(value: updateService.downloadProgress),
              const SizedBox(height: 5),
              Text("${(updateService.downloadProgress * 100).toStringAsFixed(1)}%"),
              Text(updateService.statusMessage),
            ] else if (updateService.downloadedFilePath != null) ...[
              const Text("다운로드가 완료되었습니다."),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () => updateService.installUpdate(),
                child: const Text("설치하기"),
              ),
            ] else ...[
              const Text("지금 업데이트하시겠습니까?"),
            ]
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.maxFinite,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (!updateService.isDownloading)
                TextButton(
                  onPressed: () {
                    updateService.ignoreUpdateFor3Days();
                    Navigator.pop(context);
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(50, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                  ),
                  child: const Text("3일간 보지 않기", style: TextStyle(fontSize: 13, color: Colors.grey)),
                )
              else
                const SizedBox.shrink(),
              
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(50, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text("닫기"),
                  ),
                  if (!updateService.isDownloading && updateService.downloadedFilePath == null) ...[
                    const SizedBox(width: 4),
                    ElevatedButton(
                      onPressed: () => updateService.downloadUpdate(),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text("다운로드 및 설치", style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ShareSettingsScreen extends StatefulWidget {
  const ShareSettingsScreen({super.key});

  @override
  State<ShareSettingsScreen> createState() => _ShareSettingsScreenState();
}

class _ShareSettingsScreenState extends State<ShareSettingsScreen> {
  bool _convertToMp4 = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _convertToMp4 = prefs.getBool('share_convert_mp4') ?? false;
    });
  }

  Future<void> _toggleConvert(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('share_convert_mp4', value);
    setState(() {
      _convertToMp4 = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('공유 설정')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('MP4로 변환하여 공유'),
            subtitle: const Text('공유 시 .ts 파일을 .mp4로 변환합니다. (시간이 더 소요될 수 있습니다)'),
            value: _convertToMp4,
            onChanged: _toggleConvert,
          ),
        ],
      ),
    );
  }
}



