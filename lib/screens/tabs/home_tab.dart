import 'dart:async';
import 'package:carrot_pilot_manager/screens/backup_manager_screen.dart';
import 'package:carrot_pilot_manager/widgets/drive_list_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/backup_service.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  String _branch = "--";
  String _commit = "--";
  String _dongleId = "--";
  String _serial = "--";
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshStatus());
    
    // Start auto-backup monitor
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      final drive = Provider.of<GoogleDriveService>(context, listen: false);
      final backup = Provider.of<BackupService>(context, listen: false);
      backup.startMonitoring(ssh, drive);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    if (ssh.isConnected && _branch == "--") {
      _refreshStatus();
    }
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
      final did = await ssh.getDongleId();
      final ser = await ssh.getSerial();
      if (mounted) {
        setState(() {
          _branch = br;
          _commit = cm;
          _dongleId = did;
          _serial = ser;
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
                // Info Grid
                Row(
                  children: [
                    Expanded(child: _buildInfoItem(Icons.call_split, "브랜치", _branch)),
                    Expanded(child: _buildInfoItem(Icons.commit, "커밋", _commit)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: _buildInfoItem(Icons.fingerprint, "Dongle ID", _dongleId)),
                    Expanded(child: _buildInfoItem(Icons.qr_code, "Serial", _serial)),
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
        _buildBackupSection(context),
        const SizedBox(height: 80), // Bottom padding
      ],
    );
  }

  Widget _buildBackupSection(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final isSignedIn = driveService.currentUser != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "당근 백업/복원 (히스토리)",
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              "설정값을 날짜별로 백업하고, 변경된 부분만 선택하여 복원할 수 있습니다.",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const BackupManagerScreen()),
                      );
                    },
                    icon: const Icon(Icons.history),
                    label: const Text("관리"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      elevation: 0,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (isSignedIn) {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text("구글 드라이브 연동 해제"),
                            content: const Text("구글 드라이브 연동을 해제하시겠습니까?"),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("취소")),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("해제")),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await driveService.signOut();
                        }
                      } else {
                        try {
                          await driveService.signIn();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text("Google Sign-In Failed: $e"),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      }
                    },
                    icon: Icon(
                      isSignedIn ? Icons.check_circle : Icons.cloud_off,
                      color: isSignedIn ? Colors.green : null,
                    ),
                    label: Text(isSignedIn ? "연동됨" : "구글 연동"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      elevation: 0,
                      backgroundColor: isSignedIn 
                          ? Colors.green.withOpacity(0.1) 
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      foregroundColor: isSignedIn 
                          ? Colors.green 
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[400]),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ],
    );
  }
}
