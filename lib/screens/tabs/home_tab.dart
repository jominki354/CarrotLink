import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:carrot_pilot_manager/widgets/drive_list_widget.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  String _branch = "--";
  String _commit = "--";
  String _carModel = "--";
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.isConnected) {
      final br = await ssh.getBranch();
      final cm = await ssh.getCommitHash();
      final car = await ssh.getCarModel();
      if (mounted) {
        setState(() {
          _branch = br;
          _commit = cm;
          _carModel = car;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        // Header Card
        Card(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.directions_car,
                        color: Theme.of(context).colorScheme.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Comma IP',
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            Provider.of<SSHService>(context).connectedIp ?? "Unknown",
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.call_split, size: 20, color: Colors.grey[400]),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('브랜치', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                              Text(_branch, style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.commit, size: 20, color: Colors.grey[400]),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('커밋', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                              Text(_commit, style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        
        const SizedBox(height: 24),
        Text(
          "빠른 실행",
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        
        // Quick Actions Grid
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 1.5,
          children: [
            _buildQuickActionCard(
              context,
              "Git Pull",
              Icons.download,
              () async {
                final ssh = Provider.of<SSHService>(context, listen: false);
                await ssh.executeCommand("cd /data/openpilot && git pull");
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Git Pull 실행됨")),
                  );
                }
              },
            ),
            _buildQuickActionCard(
              context,
              "재부팅",
              Icons.restart_alt,
              () async {
                 final ssh = Provider.of<SSHService>(context, listen: false);
                 await ssh.executeCommand("sudo reboot");
                 if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("재부팅 중...")),
                  );
                }
              },
              isDestructive: true,
            ),
          ],
        ),

        const SizedBox(height: 24),
        Text(
          "녹화 영상",
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        const SizedBox(
          height: 300,
          child: DriveListWidget(),
        ),

        const SizedBox(height: 24),
        Text(
          "설정 백업/복원",
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              _buildBackupSlot(1),
              const Divider(),
              _buildBackupSlot(2),
              const Divider(),
              _buildBackupSlot(3),
            ],
          ),
        ),
        const SizedBox(height: 80), // Bottom padding
      ],
    );
  }

  Widget _buildBackupSlot(int slot) {
    return ListTile(
      leading: CircleAvatar(child: Text("$slot")),
      title: Text("슬롯 $slot"),
      subtitle: const Text("Local Storage"),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.visibility),
            onPressed: () => _viewBackup(slot),
            tooltip: "보기",
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () => _backupSettings(slot),
            tooltip: "백업",
          ),
          IconButton(
            icon: const Icon(Icons.restore),
            onPressed: () => _restoreSettings(slot),
            tooltip: "복원",
          ),
        ],
      ),
    );
  }

  Future<void> _viewBackup(int slot) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/params_backup_$slot.json');
      if (!await file.exists()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("백업 파일이 없습니다.")));
        return;
      }
      final content = await file.readAsString();
      final Map<String, dynamic> params = jsonDecode(content);
      
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("슬롯 $slot 백업 내용"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: params.length,
              itemBuilder: (ctx, index) {
                final key = params.keys.elementAt(index);
                final value = params[key];
                return ListTile(
                  title: Text(key, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(value.toString()),
                  dense: true,
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("닫기"))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("읽기 실패: $e")));
    }
  }

  Future<void> _backupSettings(int slot) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }

    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      
      // 1. List params
      final output = await ssh.executeCommand("ls /data/params/d");
      final keys = output.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      
      // 2. Read values
      final Map<String, String> params = {};
      for (final key in keys) {
        final value = await ssh.executeCommand("cat /data/params/d/$key");
        params[key] = value;
      }
      
      // 3. Save to local
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/params_backup_$slot.json');
      await file.writeAsString(jsonEncode(params));
      
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("슬롯 $slot 백업 완료: ${keys.length}개 항목")));
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("백업 실패: $e")));
      }
    }
  }

  Future<void> _restoreSettings(int slot) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("연결되지 않음")));
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/params_backup_$slot.json');
      if (!await file.exists()) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("백업 파일이 없습니다.")));
        return;
      }

      final content = await file.readAsString();
      final Map<String, dynamic> params = jsonDecode(content);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      int count = 0;
      for (final entry in params.entries) {
        final key = entry.key;
        final value = entry.value.toString();
        final escapedValue = value.replaceAll("'", "'\\''");
        await ssh.executeCommand("echo -n '$escapedValue' > /data/params/d/$key");
        count++;
      }

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("슬롯 $slot 복원 완료: $count개 항목")));
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("복원 실패: $e")));
      }
    }
  }

  Widget _buildQuickActionCard(BuildContext context, String title, IconData icon, VoidCallback onTap, {bool isDestructive = false}) {
    final color = isDestructive ? Colors.red : Theme.of(context).colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: color),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isDestructive ? Colors.red : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
