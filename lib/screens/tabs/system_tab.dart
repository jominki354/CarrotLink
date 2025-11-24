import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../constants.dart';
import '../../widgets/design_components.dart';
import '../../widgets/custom_toast.dart';

class SystemTab extends StatefulWidget {
  const SystemTab({super.key});

  @override
  State<SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<SystemTab> {
  
  Future<void> _executeSafeCommand(BuildContext context, String command, String title, String message, {bool isDestructive = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("취소")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDestructive ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
              foregroundColor: isDestructive ? Theme.of(context).colorScheme.onError : Theme.of(context).colorScheme.onPrimary,
            ),
            child: const Text("확인"),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await ssh.executeCommand(command);
        if (mounted) {
          CustomToast.show(context, "명령어 전송 완료: $title");
        }
      } catch (e) {
        if (mounted) {
          CustomToast.show(context, "명령어 전송 실패: $e", isError: true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSection(context, "전원 및 프로세스", Icons.power_settings_new, [
          _buildActionButton(
            context, 
            "소프트 재시작 (Soft Restart)", 
            Icons.refresh, 
            "tmux kill-session -t tmp 2>/dev/null; tmux new -d -s tmp; tmux split-window -v -t tmp; tmux send-keys -t tmp.0 \"/data/openpilot/launch_openpilot.sh\" C-m; tmux send-keys -t tmp.1 \"tmux kill-session -t comma\" C-m; tmux send-keys -t tmp.1 \"tmux rename-session -t tmp comma\" C-m; tmux send-keys -t tmp.1 \"exit\" C-m",
            "UI를 재시작하시겠습니까?",
            Colors.orange,
          ),
          _buildActionButton(
            context, 
            "기기 재부팅 (Reboot)", 
            Icons.restart_alt, 
            "sudo reboot", 
            "기기를 재부팅하시겠습니까?",
            Colors.red,
            isDestructive: true,
          ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, "빌드 및 유지보수", Icons.build_circle_outlined, [
          _buildActionButton(
            context, 
            "오픈파일럿 재빌드 (Rebuild)", 
            Icons.build, 
            "cd /data/openpilot && scons -c && rm .sconsign.dblite && rm -rf /tmp/scons_cache && rm prebuilt && sudo reboot", 
            "재빌드를 시작하시겠습니까? 시간이 소요될 수 있습니다.",
            Colors.blue,
          ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, "데이터 관리", Icons.storage, [
          _buildActionButton(
            context, 
            "학습 데이터 초기화 (Live Params)", 
            Icons.tune, 
            "rm ${CarrotConstants.paramsPath}/LiveParameters", 
            "주행 학습 데이터를 초기화하시겠습니까?",
            Colors.grey,
          ),
          _buildActionButton(
            context, 
            "캘리브레이션 초기화 (Calibration)", 
            Icons.camera_alt, 
            "rm ${CarrotConstants.paramsPath}/CalibrationParams", 
            "카메라 캘리브레이션을 초기화하시겠습니까?",
            Colors.grey,
          ),
          _buildActionButton(
            context, 
            "녹화 영상 삭제 (Delete Videos)", 
            Icons.video_library, 
            "rm -rf /data/media/0/videos", 
            "모든 주행 녹화 영상을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.",
            Colors.red,
            isDestructive: true,
          ),
        ]),
        const SizedBox(height: 100),
      ],
    );
  }

  Widget _buildSection(BuildContext context, String title, IconData icon, List<Widget> children) {
    return DesignCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesignSectionHeader(
            icon: icon, 
            title: title,
            marginBottom: 8,
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon, String command, String confirmMessage, Color? color, {bool isDestructive = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (color ?? Theme.of(context).colorScheme.primary).withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color ?? Theme.of(context).colorScheme.primary, size: 20),
        ),
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
        trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
        onTap: () => _executeSafeCommand(
          context, 
          command, 
          label, 
          confirmMessage, 
          isDestructive: isDestructive
        ),
        onLongPress: () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(label),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("실행되는 명령어:", style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      command,
                      style: const TextStyle(fontFamily: 'monospace', color: Colors.white),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("닫기")),
              ],
            ),
          );
        },
      ),
    );
  }
}
