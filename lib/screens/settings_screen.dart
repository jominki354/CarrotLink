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
import '../widgets/update_dialog.dart';
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
  // 기본 연결 설정
  final TextEditingController _ipController = TextEditingController(text: '');
  final TextEditingController _usernameController = TextEditingController(text: 'comma');
  final TextEditingController _passwordController = TextEditingController(text: 'comma');
  final TextEditingController _portController = TextEditingController(text: '22');
  
  // 수동 키 입력용
  final TextEditingController _manualKeyController = TextEditingController();
  
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final GitHubService _githubService = GitHubService();
  
  bool _useKey = false;
  bool _isGitHubLoggedIn = false;
  List<Map<String, dynamic>> _keys = [];
  
  // 새로운 키 상태 관리
  String? _currentKeyType;       // "manual" | "generated" | null
  String? _currentPrivateKey;    // 현재 사용 중인 개인키
  String? _activeGeneratedId;    // 활성화된 자동 생성 키의 GitHub ID
  String? _activeGeneratedTitle; // 활성화된 자동 생성 키 제목 (UI 표시용)
  
  StreamSubscription? _discoverySubscription;

  @override
  void initState() {
    super.initState();
    _migrateAndLoadSettings();
    _checkGitHubLogin();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startDiscovery();
    });
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    try {
      final ssh = Provider.of<SSHService>(context, listen: false);
      ssh.stopDiscovery();
    } catch (e) {
      debugPrint("Failed to stop discovery: $e");
    }
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _portController.dispose();
    _manualKeyController.dispose();
    super.dispose();
  }

  // ========== 키 저장소 마이그레이션 및 로드 ==========
  
  Future<void> _migrateAndLoadSettings() async {
    // 기존 구조에서 새 구조로 마이그레이션
    final oldActiveId = await _storage.read(key: 'active_key_id');
    final newKeyType = await _storage.read(key: 'current_key_type');
    
    if (oldActiveId != null && newKeyType == null) {
      // 마이그레이션 필요
      final oldPrivateKey = await _storage.read(key: 'private_key_$oldActiveId');
      final oldPublicKey = await _storage.read(key: 'public_key_$oldActiveId');
      
      if (oldPrivateKey != null) {
        // 새 구조로 복사
        await _storage.write(key: 'generated_key_$oldActiveId', value: oldPrivateKey);
        if (oldPublicKey != null) {
          await _storage.write(key: 'generated_pub_$oldActiveId', value: oldPublicKey);
        }
        await _storage.write(key: 'current_key_type', value: 'generated');
        await _storage.write(key: 'current_private_key', value: oldPrivateKey);
        await _storage.write(key: 'active_generated_id', value: oldActiveId);
      }
    }
    
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    final ip = await _storage.read(key: 'ssh_ip');
    final username = await _storage.read(key: 'ssh_username');
    final password = await _storage.read(key: 'ssh_password');
    
    debugPrint('[Settings] Loaded IP: $ip, Username: $username');
    
    // 새 구조에서 키 로드
    final keyType = await _storage.read(key: 'current_key_type');
    final privateKey = await _storage.read(key: 'current_private_key');
    final generatedId = await _storage.read(key: 'active_generated_id');
    
    String? generatedTitle;
    if (generatedId != null) {
      // GitHub 키 목록에서 제목 찾기 (나중에 로드됨)
      generatedTitle = "CarrotLink 키";
    }
    
    if (mounted) {
      setState(() {
        if (ip != null) _ipController.text = ip;
        if (username != null) _usernameController.text = username;
        if (password != null) _passwordController.text = password;
        
        _currentKeyType = keyType;
        _currentPrivateKey = privateKey;
        _activeGeneratedId = generatedId;
        _activeGeneratedTitle = generatedTitle;
        _useKey = privateKey != null && privateKey.isNotEmpty;
      });
    }
  }

  // ========== 키 적용/해제 메서드 ==========
  
  Future<void> _applyManualKey() async {
    final privateKey = _manualKeyController.text.trim();
    
    if (privateKey.isEmpty) {
      CustomToast.show(context, "개인키를 입력하세요.", isError: true);
      return;
    }
    
    if (!privateKey.contains('-----BEGIN') || !privateKey.contains('PRIVATE KEY-----')) {
      CustomToast.show(context, "올바른 PEM 형식의 개인키를 입력하세요.", isError: true);
      return;
    }
    
    await _storage.write(key: 'current_key_type', value: 'manual');
    await _storage.write(key: 'current_private_key', value: privateKey);
    await _storage.delete(key: 'active_generated_id');
    await _storage.write(key: 'key_verified', value: 'false'); // 새 키이므로 검증 필요
    
    setState(() {
      _currentKeyType = 'manual';
      _currentPrivateKey = privateKey;
      _activeGeneratedId = null;
      _activeGeneratedTitle = null;
      _useKey = true;
      _manualKeyController.clear();
    });
    
    CustomToast.show(context, "수동 SSH 키가 적용되었습니다.");
  }

  Future<void> _applyGeneratedKey(String keyId, String title) async {
    final privateKey = await _storage.read(key: 'generated_key_$keyId');
    
    if (privateKey == null) {
      // 기존 구조에서 찾기 (마이그레이션 안 된 경우)
      final oldKey = await _storage.read(key: 'private_key_$keyId');
      if (oldKey != null) {
        await _storage.write(key: 'generated_key_$keyId', value: oldKey);
        await _applyGeneratedKey(keyId, title);
        return;
      }
      if (mounted) CustomToast.show(context, "이 키의 개인키가 저장되어 있지 않습니다.\n이 기기에서 생성한 키만 사용할 수 있습니다.", isError: true);
      return;
    }
    
    await _storage.write(key: 'current_key_type', value: 'generated');
    await _storage.write(key: 'current_private_key', value: privateKey);
    await _storage.write(key: 'active_generated_id', value: keyId);
    await _storage.write(key: 'key_verified', value: 'false'); // 새 키이므로 검증 필요
    
    setState(() {
      _currentKeyType = 'generated';
      _currentPrivateKey = privateKey;
      _activeGeneratedId = keyId;
      _activeGeneratedTitle = title;
      _useKey = true;
    });
    
    if (mounted) CustomToast.show(context, "SSH 키가 적용되었습니다: $title");
  }

  Future<void> _clearKey() async {
    await _storage.delete(key: 'current_key_type');
    await _storage.delete(key: 'current_private_key');
    
    setState(() {
      _currentKeyType = null;
      _currentPrivateKey = null;
      _activeGeneratedId = null;
      _activeGeneratedTitle = null;
      _useKey = false;
    });
    
    if (mounted) CustomToast.show(context, "SSH 키가 해제되었습니다.");
  }

  // ========== GitHub 관련 ==========
  
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
        setState(() => _keys = keys);
        
        // 활성화된 키의 제목 업데이트
        if (_activeGeneratedId != null) {
          for (final key in keys) {
            if (key['id']?.toString() == _activeGeneratedId) {
              setState(() => _activeGeneratedTitle = key['title'] ?? 'CarrotLink 키');
              break;
            }
          }
        }
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
        
        // 삭제된 키가 현재 사용 중이면 해제
        if (_activeGeneratedId == id.toString()) {
          await _clearKey();
        }
        
        // 저장된 키 데이터도 삭제
        await _storage.delete(key: 'generated_key_$id');
        await _storage.delete(key: 'generated_pub_$id');
        await _storage.delete(key: 'private_key_$id');
        await _storage.delete(key: 'public_key_$id');
        
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
    tokenController.dispose();
  }

  Future<void> _startDeviceFlow() async {
    final token = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => GithubLoginScreen(githubService: _githubService),
      ),
    );

    if (token != null && mounted) {
      await _githubService.saveToken(token);
      await _checkGitHubLogin();
      CustomToast.show(context, "GitHub 로그인 성공");
      _showKeyGenerationDialog();
    }
  }

  Future<void> _showKeyGenerationDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("SSH 키 생성"),
        content: const Text("GitHub 로그인이 완료되었습니다.\n\n새로운 SSH 키를 생성하고 GitHub에 등록하시겠습니까?\n\n이렇게 하면 기기에 비밀번호 없이 연결할 수 있습니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("나중에"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("키 생성"),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      await _generateAndRegisterKey();
    }
  }

  Future<void> _generateAndRegisterKey() async {
    try {
      CustomToast.show(context, "키 생성 중...");
      await Future.delayed(const Duration(milliseconds: 100));
      
      final helper = SSHKeyHelper();
      final keyPair = await helper.generateAndSaveKey();
      
      if (mounted) CustomToast.show(context, "GitHub에 등록 중...");
      final title = "CarrotLink_${DateTime.now().millisecondsSinceEpoch}";
      final keyId = await _githubService.uploadPublicKey(title, keyPair['public']!);
      
      if (keyId != null) {
        // 새 구조로 저장
        await _storage.write(key: 'generated_key_$keyId', value: keyPair['private']);
        await _storage.write(key: 'generated_pub_$keyId', value: keyPair['public']);
        
        // 기존 구조에도 저장 (호환성)
        await _storage.write(key: 'private_key_$keyId', value: keyPair['private']);
        await _storage.write(key: 'public_key_$keyId', value: keyPair['public']);
        
        debugPrint("Saved key with ID: $keyId");
        
        // 바로 적용
        await _applyGeneratedKey(keyId.toString(), title);
      }
      
      await _loadKeys();
      
      if (mounted) {
        CustomToast.show(context, "키 생성 완료!\n기기에서 GitHub 사용자명을 설정하면 자동으로 키를 가져옵니다.");
      }
    } catch (e) {
      if (mounted) CustomToast.show(context, "오류: $e", isError: true);
    }
  }

  // ========== 연결 관련 ==========
  
  void _startDiscovery() {
    try {
      final ssh = Provider.of<SSHService>(context, listen: false);
      ssh.startDiscovery();
      _discoverySubscription = ssh.ipDiscoveryStream.listen(
        (ip) {
          // 검색된 IP로 항상 업데이트 (자동 검색 우선)
          if (mounted && _ipController.text != ip) {
            setState(() => _ipController.text = ip);
            CustomToast.show(context, "기기 발견: $ip");
            // 새 IP 발견 시 저장
            _storage.write(key: 'ssh_ip', value: ip);
            debugPrint('[Settings] Auto-discovered IP: $ip (saved)');
          }
        },
        onError: (e) => debugPrint("Discovery error: $e"),
      );
    } catch (e) {
      debugPrint("Failed to start discovery: $e");
    }
  }

  Future<void> _connect() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    
    // 연결 시도 전에 IP 먼저 저장 (연결 실패해도 IP는 저장됨)
    final ipToSave = _ipController.text.trim();
    final usernameToSave = _usernameController.text.trim();
    debugPrint('[Settings] Saving IP before connect: $ipToSave');
    await _storage.write(key: 'ssh_ip', value: ipToSave);
    await _storage.write(key: 'ssh_username', value: usernameToSave);
    
    try {
      String? privateKey = _useKey ? _currentPrivateKey : null;
      String? password = !_useKey ? _passwordController.text : null;
      
      await ssh.connect(ipToSave, usernameToSave, password: password, privateKey: privateKey);
      
      debugPrint('[Settings] Connection successful, IP saved: $ipToSave');
      if (password != null) {
        await _storage.write(key: 'ssh_password', value: password);
      }

      if (mounted) {
        CustomToast.show(context, '연결 성공');
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('[Settings] Connection failed: $e (IP was saved: $ipToSave)');
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

  Future<void> _testCurrentKey() async {
    if (_ipController.text.isEmpty) {
      CustomToast.show(context, "IP 주소를 입력하세요", isError: true);
      return;
    }
    
    if (_currentPrivateKey == null || _currentPrivateKey!.isEmpty) {
      CustomToast.show(context, "SSH 키가 설정되지 않았습니다", isError: true);
      return;
    }
    
    CustomToast.show(context, "SSH 키 테스트 중...");
    
    final helper = SSHKeyHelper();
    final result = await helper.testKeyAuth(
      _ipController.text,
      int.tryParse(_portController.text) ?? 22,
      _usernameController.text,
      _currentPrivateKey!,
    );
    
    if (mounted) {
      if (result['success'] == true) {
        CustomToast.show(context, "✓ SSH 키 인증 성공!");
      } else {
        _showDiagnosticDialog(result['message'] ?? '알 수 없는 오류');
      }
    }
  }
  
  Future<void> _showDiagnosticDialog(String errorMessage) async {
    String? githubUsername;
    try {
      final userInfo = await _githubService.getUserInfo();
      githubUsername = userInfo?['login'];
    } catch (_) {}
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text("SSH 키 인증 실패"),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(errorMessage, style: const TextStyle(fontSize: 12, color: Colors.red))),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              
              // 기기 설정 안내
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.settings, size: 20, color: Colors.blue),
                        SizedBox(width: 8),
                        Text("기기에서 설정하기", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildStepItem("1", "오픈파일럿 메뉴"),
                    _buildStepItem("2", "개발자 → SSH 키"),
                    _buildStepItem("3", "GitHub 사용자 추가"),
                    const SizedBox(height: 8),
                    Text(
                      "GitHub 사용자명을 입력하면 기기가 자동으로 SSH 키를 가져옵니다.",
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 12),
              
              // 인식 안 될 때
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.lightbulb_outline, size: 20, color: Colors.orange),
                        SizedBox(width: 8),
                        Text("인식이 안 될 때", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      "GitHub 사용자명을 삭제했다가 다시 입력해보세요.\n기기가 최신 SSH 키를 다시 가져옵니다.",
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context), 
            child: const Text("확인"),
          ),
        ],
      ),
    );
  }
  
  Widget _buildStepItem(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Center(
              child: Text(number, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue)),
            ),
          ),
          const SizedBox(width: 10),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
  
  Widget _buildCheckItem(String title, bool isOk, String status) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(isOk ? Icons.check_circle : Icons.cancel, size: 16, color: isOk ? Colors.green : Colors.red),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 12))),
          Text(status, style: TextStyle(fontSize: 12, color: isOk ? Colors.green : Colors.red)),
        ],
      ),
    );
  }

  // ========== 빌드 ==========
  
  @override
  Widget build(BuildContext context) {
    final ssh = Provider.of<SSHService>(context);
    
    return Scaffold(
      appBar: AppBar(title: const Text('연결 설정')),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 기본 연결 정보
          TextField(
            controller: _ipController,
            readOnly: true,
            decoration: const InputDecoration(
              labelText: 'IP 주소', 
              prefixIcon: Icon(Icons.wifi),
              hintText: '기기를 자동으로 검색 중...',
            ),
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
          
          // SSH 키 사용 체크박스
          CheckboxListTile(
            title: const Text('SSH 키 사용'),
            value: _useKey,
            onChanged: (v) {
              if (v == true && _currentPrivateKey == null) {
                CustomToast.show(context, "먼저 SSH 키를 설정하세요.");
                return;
              }
              setState(() => _useKey = v ?? false);
            },
            secondary: _useKey && _currentPrivateKey != null
                ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                : null,
          ),
          
          // 현재 키 상태 표시
          _buildCurrentKeyStatus(),
          
          const SizedBox(height: 16),
          
          // 연결 버튼
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
          
          // 키 설정 섹션
          Text("SSH 키 설정", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          
          // 방법 1: 수동 입력
          _buildManualKeySection(),
          
          const SizedBox(height: 24),
          
          // 방법 2: GitHub 연동
          _buildGitHubSection(),
          
          // 하단 여백
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildCurrentKeyStatus() {
    if (_currentPrivateKey == null || _currentPrivateKey!.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.withOpacity(0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber, size: 20, color: Colors.orange),
            SizedBox(width: 8),
            Text('SSH 키가 설정되지 않음', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    
    final isManual = _currentKeyType == 'manual';
    final keyLabel = isManual ? '수동 입력 키' : (_activeGeneratedTitle ?? 'CarrotLink 키');
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.vpn_key, size: 16, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  keyLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green),
                ),
              ),
              TextButton(
                onPressed: _clearKey,
                child: const Text('키 해제', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isManual ? '수동으로 입력한 개인키' : 'GitHub에 등록된 자동 생성 키',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testCurrentKey,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('키 테스트', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _currentPrivateKey!));
                    CustomToast.show(context, '개인키가 복사되었습니다.');
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('키 복사', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildManualKeySection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.edit, size: 18),
              SizedBox(width: 8),
              Text("방법 1: 수동 입력", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          const Text("외부에서 생성한 개인키를 직접 입력합니다.", style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(
            controller: _manualKeyController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '개인키 (PEM)',
              hintText: '-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _applyManualKey,
              child: const Text("이 키 적용"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGitHubSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud, size: 18),
              SizedBox(width: 8),
              Text("방법 2: GitHub 연동", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          const Text("SSH 키를 자동 생성하고 GitHub에 등록합니다.", style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 12),
          
          if (!_isGitHubLoggedIn)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _loginToGitHub,
                icon: const Icon(Icons.login),
                label: const Text("GitHub 로그인"),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, foregroundColor: Colors.white),
              ),
            )
          else ...[
            Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 16),
                const SizedBox(width: 8),
                const Text("GitHub 로그인됨", style: TextStyle(fontSize: 12)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await _githubService.clearToken();
                    await _checkGitHubLogin();
                  },
                  child: const Text("로그아웃", style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _generateAndRegisterKey,
                icon: const Icon(Icons.add),
                label: const Text("새 SSH 키 생성 및 등록"),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "기기 설정에서 GitHub 사용자명을 입력하면 키가 자동으로 적용됩니다.",
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            
            // 등록된 키 목록
            if (_keys.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text("등록된 키 목록", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 4),
              const Text("탭하여 사용, 길게 눌러 개인키 복사", style: TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _keys.length,
                itemBuilder: (context, index) {
                  final key = _keys[index];
                  final keyTitle = key['title'] as String? ?? '';
                  final keyId = key['id']?.toString();
                  
                  final isCarrotLinkKey = keyTitle.startsWith('CarrotLink');
                  final isActive = _currentKeyType == 'generated' && _activeGeneratedId == keyId;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: isActive 
                        ? const Icon(Icons.check_circle, size: 20, color: Colors.green)
                        : Icon(Icons.vpn_key_outlined, size: 20, color: isCarrotLinkKey ? Colors.grey : Colors.grey[400]),
                    title: Text(
                      keyTitle.isEmpty ? 'No Title' : keyTitle, 
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                        color: isCarrotLinkKey ? null : Colors.grey,
                      ),
                    ),
                    subtitle: Text(
                      isActive 
                          ? "현재 사용 중" 
                          : (isCarrotLinkKey ? "탭하여 사용" : "외부에서 생성된 키"),
                      style: TextStyle(fontSize: 10, color: isActive ? Colors.green : Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => _deleteKey(key['id']),
                    ),
                    dense: true,
                    enabled: isCarrotLinkKey,
                    onTap: isCarrotLinkKey ? () => _applyGeneratedKey(keyId!, keyTitle) : () {
                      CustomToast.show(context, "외부에서 생성된 키는 개인키가 없어 사용할 수 없습니다.");
                    },
                    onLongPress: isCarrotLinkKey ? () async {
                      final privateKey = await _storage.read(key: 'generated_key_$keyId') 
                          ?? await _storage.read(key: 'private_key_$keyId');
                      if (privateKey != null) {
                        Clipboard.setData(ClipboardData(text: privateKey));
                        if (mounted) CustomToast.show(context, "개인키가 복사되었습니다.");
                      } else {
                        if (mounted) CustomToast.show(context, "개인키가 저장되어 있지 않습니다.", isError: true);
                      }
                    } : null,
                  );
                },
              ),
            ],
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
      builder: (ctx) => UpdateDialog(),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 8),
            Text("CarrotLink"),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.person, color: Colors.blue),
              title: Text("제작자"),
              subtitle: Text("kooingh354"),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.discord, color: Colors.indigo),
              title: Text("Discord"),
              subtitle: Text("kooingh354"),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("확인"),
          ),
        ],
      ),
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
            onTap: () => _showAboutDialog(context),
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
            title: const Text('업데이트 확인'),
            subtitle: updateService.latestRelease != null 
              ? Text('새 버전: ${updateService.latestRelease!['tag_name']}') 
              : const Text('최신 버전입니다'),
            trailing: updateService.latestRelease != null 
              ? const Icon(Icons.system_update, color: Colors.orange)
              : const Icon(Icons.check_circle, color: Colors.green),
            onTap: () => _showUpdateDialog(context),
          ),
          const Divider(),
          ListTile(
            title: const Text('업데이트 채널'),
            subtitle: Text(updateService.channel == 'stable' ? 'Stable (안정 버전)' : 'Dev (개발 버전)'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'stable', label: Text('Stable')),
                ButtonSegment(value: 'dev', label: Text('Dev')),
              ],
              selected: {updateService.channel},
              onSelectionChanged: (Set<String> selection) {
                updateService.setChannel(selection.first);
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
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



