import 'dart:async';
import 'package:intl/intl.dart';
import 'package:carrot_pilot_manager/screens/backup_manager_screen.dart';
import 'package:carrot_pilot_manager/widgets/drive_list_widget.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../services/google_drive_service.dart';
import '../../services/backup_service.dart';
import '../../widgets/custom_toast.dart';

import 'package:carrot_pilot_manager/widgets/design_components.dart';
import 'package:carrot_pilot_manager/constants.dart';

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
  final GlobalKey _backupChipKey = GlobalKey();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _tooltipEntry;

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
    _tooltipEntry?.remove();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (ssh.isConnected) {
      try {
        final results = await Future.wait([
          ssh.getBranch(),
          ssh.getCommitHash(),
          ssh.getDongleId(),
          ssh.getSerial(),
        ]);

        if (mounted) {
          setState(() {
            _branch = results[0];
            _commit = results[1];
            _dongleId = results[2];
            _serial = results[3];
          });
        }
      } catch (e) {
        print("Status refresh failed: $e");
      }
    }
  }

  void _showBackupTooltip(BuildContext context, BackupService backup) {
    if (_tooltipEntry != null) {
      _tooltipEntry!.remove();
      _tooltipEntry = null;
      return;
    }

    _tooltipEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: 150, // Fixed width or calculate based on content
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, -50), // Position above the chip
          child: Material(
            color: Colors.transparent,
            child: _BackupTimerTooltip(
              targetTime: backup.nextCheckTime,
              onClose: () {
                _tooltipEntry?.remove();
                _tooltipEntry = null;
              },
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_tooltipEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SSHService>(
      builder: (context, ssh, child) {
        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Header Card
            DesignCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: (ssh.isConnected ? Theme.of(context).colorScheme.primary : Colors.grey).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.directions_car,
                          color: ssh.isConnected ? Theme.of(context).colorScheme.primary : Colors.grey,
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
                            GestureDetector(
                              onTap: () {
                                if (ssh.isConnected || ssh.connectionStatus.startsWith("Connecting")) {
                                  ssh.disconnect();
                                  CustomToast.show(context, "연결이 해제되었습니다.");
                                }
                              },
                              child: Text(
                                (ssh.isConnected || ssh.connectionStatus.startsWith("Connecting") || ssh.targetIp != null)
                                    ? (ssh.connectedIp ?? ssh.targetIp ?? "Unknown")
                                    : "연결 없음",
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: ssh.isConnected ? null : Colors.redAccent,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ssh.connectionStatus,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: ssh.isConnected 
                                    ? Colors.green 
                                    : (ssh.connectionStatus.startsWith("Connecting") ? Colors.orange : Colors.grey),
                                fontWeight: FontWeight.bold,
                              ),
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
            const SizedBox(height: 150), // Bottom padding for SnackBar
          ],
        );
      },
    );
  }

  Widget _buildBackupSection(BuildContext context) {
    final driveService = Provider.of<GoogleDriveService>(context);
    final isSignedIn = driveService.currentUser != null;

    return DesignCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesignSectionHeader(
            icon: Icons.cloud_sync_outlined,
            title: "당근 백업/복원",
            subtitle: "설정값을 날짜별로 백업하고, 변경된 부분만 선택하여 복원할 수 있습니다.",
          ),
          const SizedBox(height: 16),
          
          // Status Chips
          Consumer<BackupService>(
            builder: (context, backup, child) {
              final checkTime = backup.lastCheckTime != null 
                  ? DateFormat('MM.dd HH:mm:ss').format(backup.lastCheckTime!) 
                  : "--";
              final backupTime = backup.lastBackupTime != null 
                  ? DateFormat('MM.dd HH:mm:ss').format(backup.lastBackupTime!) 
                  : "--";
                  
              return Row(
                children: [
                  Expanded(
                    child: CompositedTransformTarget(
                      link: _layerLink,
                      child: DesignStatusChip(
                        key: _backupChipKey,
                        icon: Icons.sync, 
                        label: "백업 확인", 
                        value: checkTime, 
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        onTap: () => _showBackupTooltip(context, backup),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DesignStatusChip(
                      icon: Icons.save_outlined, 
                      label: "최근 백업", 
                      value: backupTime,
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                    ),
                  ),
                ],
              );
            },
          ),
          
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const BackupManagerScreen()),
                    );
                  },
                  icon: const Icon(Icons.history),
                  label: const Text("관리"),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
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
                          CustomToast.show(context, "Google Sign-In Failed: $e", isError: true);
                        }
                      }
                    }
                  },
                  icon: Icon(
                    isSignedIn ? Icons.check_circle : Icons.cloud_off,
                    color: isSignedIn ? Colors.green : null,
                    size: 18,
                  ),
                  label: Text(isSignedIn ? "연동됨" : "구글 연동"),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isSignedIn ? Colors.green : null,
                    side: isSignedIn ? const BorderSide(color: Colors.green) : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, IconData icon, String label, String time, Color bgColor, Color fgColor) {
    // Deprecated: Use DesignStatusChip instead
    return Container(); 
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

class _BackupTimerTooltip extends StatefulWidget {
  final DateTime? targetTime;
  final VoidCallback onClose;

  const _BackupTimerTooltip({
    required this.targetTime,
    required this.onClose,
  });

  @override
  State<_BackupTimerTooltip> createState() => _BackupTimerTooltipState();
}

class _BackupTimerTooltipState extends State<_BackupTimerTooltip> with SingleTickerProviderStateMixin {
  late Timer _timer;
  String _timeLeft = "";
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _updateTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateTime());
    
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(_controller);
    _controller.forward();

    // Auto close after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) {
        _controller.reverse().then((_) => widget.onClose());
      }
    });
  }

  void _updateTime() {
    if (widget.targetTime == null) {
      setState(() => _timeLeft = "예정 없음");
      return;
    }

    final now = DateTime.now();
    final diff = widget.targetTime!.difference(now);

    if (diff.isNegative) {
      setState(() => _timeLeft = "확인 중...");
    } else {
      final min = diff.inMinutes;
      final sec = diff.inSeconds % 60;
      setState(() => _timeLeft = "다음 확인: ${min}분 ${sec}초");
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _timeLeft,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
          CustomPaint(
            painter: _TrianglePainter(color: Colors.black87),
            size: const Size(10, 6),
          ),
        ],
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(size.width / 2, size.height);
    path.lineTo(size.width, 0);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
