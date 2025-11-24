import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/ssh_service.dart';
import '../../constants.dart';
import '../../widgets/design_components.dart';
import '../../widgets/custom_toast.dart';

class GitTab extends StatefulWidget {
  const GitTab({super.key});

  @override
  State<GitTab> createState() => _GitTabState();
}

class _GitTabState extends State<GitTab> {
  bool _isLoading = false;
  List<Map<String, String>> _logs = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? storedLogs = prefs.getString('git_logs');
    if (storedLogs != null) {
      try {
        final List<dynamic> decoded = jsonDecode(storedLogs);
        setState(() {
          _logs = decoded.map((e) {
            final map = Map<String, String>.from(e);
            map['isOld'] = 'true'; // Mark loaded logs as old
            return map;
          }).toList();
        });
        // Scroll to bottom after loading
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        });
      } catch (e) {
        print("Error loading logs: $e");
      }
    }
  }

  Future<void> _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    // Limit logs to last 100 entries to prevent overflow
    if (_logs.length > 100) {
      _logs = _logs.sublist(_logs.length - 100);
    }
    // Don't save 'isOld' property to disk, or just ignore it when loading
    // Actually, we can save it, but when we load next time, EVERYTHING becomes old.
    // So we should strip 'isOld' before saving, or just save as is and override on load.
    // Let's save as is.
    final String encoded = jsonEncode(_logs);
    await prefs.setString('git_logs', encoded);
  }

  void _addLog(String message) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _logs.add({'time': time, 'message': message, 'isOld': 'false'});
    });
    _saveLogs(); // Save on every log add
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _clearLogs() async {
    setState(() {
      _logs.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('git_logs');
  }

  Future<void> _runGitCommand(BuildContext context, String command, String successMessage) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    _addLog("명령어 실행: $command");

        final result = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && $command'");

    if (mounted) {
      setState(() => _isLoading = false);
      _addLog(result.trim());
      if (result.isNotEmpty) {
         CustomToast.show(context, successMessage);
      }
    }
  }

  Future<void> _selectBranch(BuildContext context) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    _addLog("브랜치 목록 가져오는 중...");
    
    try {
      // Fetch latest info from remote with prune to remove stale branches
      await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git fetch --all --prune'");

      // Get Repo URL
      String repoUrl = "";
      try {
        final urlOutput = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git config --get remote.origin.url'");
        repoUrl = urlOutput.trim();
        if (repoUrl.endsWith('.git')) {
          repoUrl = repoUrl.substring(0, repoUrl.length - 4);
        }
      } catch (_) {}

      // Get default branch
      String defaultBranch = "";
      try {
        final remoteShow = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git remote show origin'");
        final match = RegExp(r"HEAD branch: (.*)").firstMatch(remoteShow);
        if (match != null) {
          defaultBranch = match.group(1)?.trim() ?? "";
        }
      } catch (_) {}

      // Get current branch
      String currentBranch = "";
      try {
        currentBranch = (await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git rev-parse --abbrev-ref HEAD'")).trim();
      } catch (_) {}

      // Get all branches with date and commit hash
      final output = await ssh.executeCommand(
        "bash -l -c 'cd ${CarrotConstants.openpilotPath} && git for-each-ref --sort=-committerdate --format=\"%(refname:short)|%(committerdate:relative)|%(objectname)\" refs/remotes/origin'"
      );
      
      setState(() => _isLoading = false);

      if (!mounted) return;

      final branches = output.split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.contains('->'))
          .map((e) {
            final parts = e.split('|');
            final fullName = parts[0];
            // Remove 'origin/' prefix safely using regex
            final name = fullName.replaceFirst(RegExp(r'^origin\/'), '');
            final date = parts.length > 1 ? parts[1] : "";
            final hash = parts.length > 2 ? parts[2] : "";
            return {'name': name, 'date': date, 'hash': hash, 'fullName': fullName};
          })
          .where((b) => b['name'] != 'HEAD') // Filter out HEAD
          .toList();

      // Check for updates (ahead count) for each branch relative to local
      // This is expensive to do one by one. 
      // Instead, we can check if the remote hash is different from local hash for the *current* branch at least.
      // Or for all local branches.
      // Let's just check for the current branch for now to be fast, or maybe all if we can get local refs easily.
      
      // Get local refs
      final localRefsOutput = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git for-each-ref --format=\"%(refname:short)|%(objectname)\" refs/heads'");
      final localRefs = <String, String>{};
      for (final line in localRefsOutput.split('\n')) {
        final parts = line.trim().split('|');
        if (parts.length == 2) {
          localRefs[parts[0]] = parts[1];
        }
      }

      showDialog(
        context: context,
        builder: (ctx) => _BranchListDialog(
          branches: branches,
          defaultBranch: defaultBranch,
          currentBranch: currentBranch,
          localRefs: localRefs,
          repoUrl: repoUrl,
          onSelect: (name) {
            Navigator.pop(ctx);
            _runGitCommand(context, "git checkout $name", "$name 브랜치로 변경됨");
          },
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _addLog("브랜치 목록 실패: $e");
    }
  }

  Future<void> _performGitSync(BuildContext context) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      CustomToast.show(context, "기기와 연결되어 있지 않습니다.", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    _addLog("Git Sync 시작...");

    try {
      // 1. Get current branch
      final branchResult = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git rev-parse --abbrev-ref HEAD'");
      final currentBranch = branchResult.trim();
      
      if (currentBranch.isEmpty || currentBranch.contains("fatal")) {
        throw Exception("브랜치 정보를 가져올 수 없습니다: $branchResult");
      }
      _addLog("현재 브랜치: $currentBranch");

      // 2. Fetch all
      _addLog("원격 저장소 동기화 중 (Fetch)...");
      await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git fetch --all'");

      // 3. Reset hard to origin/branch
      _addLog("강제 리셋 중 (Reset --hard origin/$currentBranch)...");
      final resetResult = await ssh.executeCommand("bash -l -c 'cd ${CarrotConstants.openpilotPath} && git reset --hard origin/$currentBranch && git clean -fd'");
      
      _addLog(resetResult.trim());
      CustomToast.show(context, "Git Sync 완료");
    } catch (e) {
      _addLog("오류 발생: $e");
      CustomToast.show(context, "Git Sync 실패", isError: true);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top Section: Logs
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: DesignCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const DesignSectionHeader(
                        icon: Icons.terminal, 
                        title: "Git 로그",
                        marginBottom: 0,
                      ),
                      const Spacer(),
                      if (_isLoading)
                        const Padding(
                          padding: EdgeInsets.only(right: 8.0),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: _clearLogs,
                        tooltip: "로그 지우기",
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.withOpacity(0.2)),
                      ),
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          final isOld = log['isOld'] == 'true';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontFamily: 'monospace', 
                                  fontSize: 12, 
                                  color: isOld ? Colors.grey : Colors.white
                                ),
                                children: [
                                  TextSpan(
                                    text: "[${log['time']}] ",
                                    style: TextStyle(color: isOld ? Colors.grey[600] : Colors.greenAccent),
                                  ),
                                  TextSpan(text: log['message']),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Bottom Section: Fixed Buttons
        Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                offset: const Offset(0, -2),
                blurRadius: 8,
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.8,
                  children: [
                    _buildActionButton(
                      context,
                      "브랜치 선택",
                      Icons.list,
                      Colors.blue,
                      () => _selectBranch(context),
                    ),
                    _buildActionButton(
                      context,
                      "Git Pull",
                      Icons.download,
                      Colors.green,
                      () => _runGitCommand(context, "git pull", "Git Pull 완료"),
                    ),
                    _buildActionButton(
                      context,
                      "Git Reset",
                      Icons.restore,
                      Colors.orange,
                      () => _runGitCommand(context, "git reset --hard HEAD && git clean -fd", "Git Reset 완료"),
                    ),
                    _buildActionButton(
                      context,
                      "Git Sync",
                      Icons.sync,
                      Colors.red,
                      () => _performGitSync(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildActionButton(
                  context,
                  "Rebuild All",
                  Icons.build,
                  Colors.purple,
                  () => _runGitCommand(context, "scons -c && rm .sconsign.dblite", "Rebuild 시작됨"),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon, Color color, VoidCallback onTap) {
    return FilledButton.icon(
      onPressed: _isLoading ? null : onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: color.withOpacity(0.15),
        foregroundColor: color,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withOpacity(0.3)),
        ),
      ),
    );
  }
}

class _BranchListDialog extends StatefulWidget {
  final List<Map<String, String>> branches;
  final String defaultBranch;
  final String currentBranch;
  final Map<String, String> localRefs;
  final String repoUrl;
  final Function(String) onSelect;

  const _BranchListDialog({
    required this.branches,
    required this.defaultBranch,
    required this.currentBranch,
    required this.localRefs,
    required this.repoUrl,
    required this.onSelect,
  });

  @override
  State<_BranchListDialog> createState() => _BranchListDialogState();
}

class _BranchListDialogState extends State<_BranchListDialog> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final index = widget.branches.indexWhere((b) => b['name'] == widget.currentBranch);
      if (index != -1 && _scrollController.hasClients) {
        // Estimate item height ~72.0
        final offset = index * 72.0;
        // Clamp offset to maxScrollExtent
        final maxScroll = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(offset.clamp(0.0, maxScroll));
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("브랜치 선택"),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          controller: _scrollController,
          shrinkWrap: true,
          itemCount: widget.branches.length,
          itemBuilder: (ctx, index) {
            final branch = widget.branches[index];
            final name = branch['name']!;
            final date = branch['date']!;
            final hash = branch['hash']!;
            final isDefault = name == widget.defaultBranch;
            final isCurrent = name == widget.currentBranch;
            
            bool hasUpdate = false;
            if (widget.localRefs.containsKey(name)) {
              if (widget.localRefs[name] != hash) {
                hasUpdate = true;
              }
            }

            return ListTile(
              tileColor: isCurrent ? Theme.of(context).colorScheme.secondaryContainer : null,
              title: Row(
                children: [
                  Text(name, style: TextStyle(fontWeight: isDefault ? FontWeight.bold : FontWeight.normal)),
                  if (isDefault) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text("Default", style: TextStyle(fontSize: 10, color: Colors.blue)),
                    ),
                  ],
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.check, size: 16, color: Colors.green),
                  ],
                ],
              ),
              subtitle: Text(date, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              trailing: hasUpdate 
                ? IconButton(
                    icon: const Icon(Icons.priority_high, color: Colors.red, size: 20),
                    tooltip: "업데이트 가능",
                    onPressed: () async {
                        if (widget.repoUrl.isNotEmpty) {
                          final url = "${widget.repoUrl}/commits/$name";
                          final uri = Uri.parse(url);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          } else {
                            if (context.mounted) {
                              showDialog(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text("커밋 내역"),
                                  content: SelectableText(url),
                                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("닫기"))],
                                ),
                              );
                            }
                          }
                        }
                    },
                  ) 
                : null,
              onTap: () => widget.onSelect(name),
            );
          },
        ),
      ),
    );
  }
}
