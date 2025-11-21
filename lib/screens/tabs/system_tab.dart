import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';

class SystemTab extends StatefulWidget {
  const SystemTab({super.key});

  @override
  State<SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<SystemTab> {
  
  Future<void> _executeSafeCommand(BuildContext context, String command, String title, String message, {bool isDestructive = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: isDestructive ? Colors.red : null),
            child: const Text("Confirm"),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      await ssh.executeCommand(command);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("$title Command Sent")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSection(context, "Power & Process", [
          _buildActionButton(
            context, 
            "Soft Restart", 
            Icons.refresh, 
            "pkill -f selfdrive.manager && python /data/openpilot/selfdrive/manager/manager.py &",
            "Restarting Openpilot UI...",
            Colors.orange,
          ),
          _buildActionButton(
            context, 
            "Reboot Device", 
            Icons.restart_alt, 
            "sudo reboot", 
            "Rebooting Device...",
            Colors.red,
            isDestructive: true,
            confirmMessage: "Are you sure you want to reboot the device?",
          ),
        ]),
        _buildSection(context, "Build & Maintenance", [
          _buildActionButton(
            context, 
            "Rebuild Openpilot", 
            Icons.build, 
            "cd /data/openpilot && scons -c && scons -j\$(nproc)", 
            "Rebuilding... This may take a while.",
            Colors.blue,
          ),
        ]),
        _buildSection(context, "Data Management", [
          _buildActionButton(
            context, 
            "Reset Live Params", 
            Icons.tune, 
            "rm /data/params/d/LiveParameters", 
            "Live Parameters Reset.",
            Colors.grey,
            confirmMessage: "Reset learning parameters?",
          ),
          _buildActionButton(
            context, 
            "Remove Calibration", 
            Icons.camera_alt, 
            "rm /data/params/d/CalibrationParams", 
            "Calibration Reset.",
            Colors.grey,
            confirmMessage: "Reset camera calibration?",
          ),
          _buildActionButton(
            context, 
            "Delete Videos", 
            Icons.video_library, 
            "rm -rf /data/media/0/videos", 
            "Videos Deleted.",
            Colors.red,
            isDestructive: true,
            confirmMessage: "Delete all recorded driving videos?",
          ),
        ]),
      ],
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).primaryColor)),
        ),
        Card(
          child: Column(children: children),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon, String command, String successMsg, Color? color, {bool isDestructive = false, String? confirmMessage}) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color?.withOpacity(0.2),
        child: Icon(icon, color: color),
      ),
      title: Text(label),
      onTap: () => _executeSafeCommand(
        context, 
        command, 
        label, 
        confirmMessage ?? "Execute $label?", 
        isDestructive: isDestructive
      ),
    );
  }
}
