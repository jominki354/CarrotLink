import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/ssh_service.dart';
import 'connection_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadSavedKey();
  }

  Future<void> _loadSavedKey() async {
    final key = await _storage.read(key: 'user_private_key');
    if (key != null) {
      setState(() {
        _keyController.text = key;
      });
    }
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isNotEmpty) {
      await _storage.write(key: 'user_private_key', value: key);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SSH 키가 저장되었습니다.')),
        );
      }
    } else {
      await _storage.delete(key: 'user_private_key');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SSH 키가 삭제되었습니다.')),
        );
      }
    }
  }

  Future<void> _logout() async {
    final sshService = Provider.of<SSHService>(context, listen: false);
    await sshService.disconnect();
    
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const ConnectionScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('설정'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'SSH 키 설정',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyController,
              maxLines: 8,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: '개인키 (PEM 형식)',
                hintText: '-----BEGIN RSA PRIVATE KEY-----\\n...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _saveKey,
              child: const Text('키 저장'),
            ),
            const Divider(height: 40),
            ElevatedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('로그아웃 (연결 끊기)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
