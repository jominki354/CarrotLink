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
        
        // Quick Actions Grid Removed

        const SizedBox(height: 24),
        Text(
          "녹화 영상",
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        const SizedBox(
          height: 260, // Adjusted height for horizontal list
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
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: () => _deleteBackup(slot),
            tooltip: "삭제",
          ),
        ],
      ),
    );
  }

  Future<void> _deleteBackup(int slot) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/params_backup_$slot.json');
      if (await file.exists()) {
        await file.delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("슬롯 $slot 백업이 삭제되었습니다.")),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("삭제할 백업 파일이 없습니다.")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("삭제 실패: $e")),
        );
      }
    }
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
      
      // 1. Fetch params using python script (Fleet Manager style)
      // manager.py의 get_default_params_key()를 사용하여 정의된 모든 파라미터를 가져옵니다.
      // Added PYTHONPATH and error handling. Also source launch_env.sh to ensure environment is correct.
      const cmd = "cd /data/openpilot && source launch_env.sh && export PYTHONPATH=\$PWD && python -c \"import json; import sys; sys.path.append('/data/openpilot'); from openpilot.common.params import Params; from openpilot.system.manager.manager import get_default_params_key; params = Params(); print(json.dumps({k: (params.get(k).decode('utf-8') if params.get(k) is not None else '0') for k in get_default_params_key()}))\"";
      final output = await ssh.executeCommand(cmd);
      
      if (output.trim().isEmpty) throw Exception("데이터를 가져오지 못했습니다.");
      if (output.trim().startsWith("Traceback") || output.contains("ModuleNotFoundError")) throw Exception("Python 스크립트 오류: $output");

      // 2. Parse JSON
      final Map<String, dynamic> params = jsonDecode(output.trim());
      
      // 3. Save to local
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/params_backup_$slot.json');
      await file.writeAsString(jsonEncode(params));
      
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("슬롯 $slot 백업 완료: ${params.length}개 항목")));
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

      // Use Python to restore (Fleet Manager style)
      final jsonStr = jsonEncode(params);
      // Escape single quotes for shell command
      final escapedJson = jsonStr.replaceAll("'", "'\\''");
      
      final cmd = "cd /data/openpilot && source launch_env.sh && export PYTHONPATH=\$PWD && python -c \"import json; import sys; sys.path.append('/data/openpilot'); from openpilot.common.params import Params; params = Params(); data = json.loads('$escapedJson'); [params.put(k, str(v)) for k,v in data.items()]\"";
      
      await ssh.executeCommand(cmd);

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("슬롯 $slot 복원 완료: ${params.length}개 항목")));
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
