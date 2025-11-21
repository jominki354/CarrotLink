import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/ssh_service.dart';
import 'dashboard_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final TextEditingController _ipController = TextEditingController(text: '192.168.0.1');
  final TextEditingController _usernameController = TextEditingController(text: 'comma');
  final TextEditingController _passwordController = TextEditingController(text: '');
  final TextEditingController _keyController = TextEditingController();
  bool _useKey = false;
  
  StreamSubscription? _ipSubscription;

  @override
  void initState() {
    super.initState();
    _loadSavedConnection();
    _startAutoDiscovery();
  }

  Future<void> _loadSavedConnection() async {
    final storage = const FlutterSecureStorage();
    
    final ip = await storage.read(key: 'ssh_ip');
    final username = await storage.read(key: 'ssh_username');
    final key = await storage.read(key: 'user_private_key');
    
    if (ip != null) {
      setState(() {
        _ipController.text = ip;
      });
    }
    if (username != null) {
      setState(() {
        _usernameController.text = username;
      });
    }
    
    if (key != null) {
      setState(() {
        _useKey = true;
        _keyController.text = key;
      });
      // Auto-connect attempt
      if (ip != null && mounted) {
        _connect(ip, username ?? 'root', key: key);
      }
    }
  }

  void _startAutoDiscovery() {
    final sshService = Provider.of<SSHService>(context, listen: false);
    sshService.startDiscovery();
    _ipSubscription = sshService.ipDiscoveryStream.listen((ip) {
      if (mounted && _ipController.text == '192.168.0.1') { 
        setState(() {
          _ipController.text = ip;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('기기 발견: $ip')),
        );
      }
    });
  }

  @override
  void dispose() {
    _ipSubscription?.cancel();
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _keyController.dispose();
    Provider.of<SSHService>(context, listen: false).stopDiscovery();
    super.dispose();
  }

  Future<void> _connect(String ip, String username, {String? password, String? key}) async {
    final sshService = Provider.of<SSHService>(context, listen: false);
    try {
      await sshService.connect(
        ip,
        username,
        password: password,
        privateKey: key,
      );
      
      if (sshService.isConnected) {
        final storage = const FlutterSecureStorage();
        await storage.write(key: 'ssh_ip', value: ip);
        await storage.write(key: 'ssh_username', value: username);
        if (key != null) {
          await storage.write(key: 'user_private_key', value: key);
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const DashboardScreen()),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('연결 실패: $e')),
        );
      }
    }
  }
    
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.link, size: 80, color: Color(0xFFFF6D00)),
                const SizedBox(height: 24),
                Text(
                  'CarrotLink',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFFFF6D00),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Openpilot Manager',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 48),
                
                // IP address field
                TextField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    labelText: 'IP 주소',
                    prefixIcon: Icon(Icons.wifi),
                    hintText: '192.168.0.1',
                  ),
                ),
                
                // Hidden username field
                Visibility(
                  visible: false,
                  child: TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: '사용자 이름 (ID)',
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),
                
                // SSH Key Checkbox
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).inputDecorationTheme.fillColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: CheckboxListTile(
                    title: const Text('SSH 키 사용'),
                    subtitle: const Text('개인키를 사용하여 접속합니다'),
                    value: _useKey,
                    onChanged: (val) {
                      setState(() {
                        _useKey = val ?? false;
                      });
                    },
                    secondary: const Icon(Icons.vpn_key),
                    activeColor: const Color(0xFFFF6D00),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),

                if (_useKey) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _keyController,
                    maxLines: 5,
                    minLines: 3,
                    decoration: const InputDecoration(
                      labelText: '개인키 (PEM 형식)',
                      hintText: '-----BEGIN RSA PRIVATE KEY-----\\n...',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(Icons.text_fields),
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ],

                const SizedBox(height: 32),
                
                ElevatedButton(
                  onPressed: () {
                    String? privateKey;
                    if (_useKey) {
                      privateKey = _keyController.text.trim();
                      if (privateKey.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('개인키를 입력해주세요.')),
                        );
                        return;
                      }
                    }
                    _connect(
                      _ipController.text,
                      _usernameController.text,
                      password: _passwordController.text,
                      key: privateKey,
                    );
                  },
                  child: const Text('연결하기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

