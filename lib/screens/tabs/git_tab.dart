import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/ssh_service.dart';

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
          _logs = decoded.map((e) => Map<String, String>.from(e)).toList();
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
    final String encoded = jsonEncode(_logs);
    await prefs.setString('git_logs', encoded);
  }

  void _addLog(String message) {
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _logs.add({'time': time, 'message': message});
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

  Future<void> _runGitCommand(BuildContext context, String command, String successMessage) async {
    setState(() => _isLoading = true);
    _addLog("명령어 실행: $command");

    final ssh = Provider.of<SSHService>(context, listen: false);
    final result = await ssh.executeCommand("cd /data/openpilot && $command");

    if (mounted) {
      setState(() => _isLoading = false);
      _addLog(result.trim());
      if (result.isNotEmpty) {
         ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMessage)),
        );
      }
    }
  }

  Future<void> _selectBranch(BuildContext context) async {
    setState(() => _isLoading = true);
    _addLog("브랜치 목록 가져오는 중...");
    final ssh = Provider.of<SSHService>(context, listen: false);
    
    try {
      // Get Repo URL
      String repoUrl = "";
      try {
        final urlOutput = await ssh.executeCommand("cd /data/openpilot && git config --get remote.origin.url");
        repoUrl = urlOutput.trim();
        if (repoUrl.endsWith('.git')) {
          repoUrl = repoUrl.substring(0, repoUrl.length - 4);
        }
      } catch (_) {}

      // Get default branch
      String defaultBranch = "";
      try {
        final remoteShow = await ssh.executeCommand("cd /data/openpilot && git remote show origin");
        final match = RegExp(r"HEAD branch: (.*)").firstMatch(remoteShow);
        if (match != null) {
          defaultBranch = match.group(1)?.trim() ?? "";
        }
      } catch (_) {}

      // Get current branch
      String currentBranch = "";
      try {
        currentBranch = (await ssh.executeCommand("cd /data/openpilot && git rev-parse --abbrev-ref HEAD")).trim();
      } catch (_) {}

      // Get all branches with date and commit hash
      final output = await ssh.executeCommand(
        "cd /data/openpilot && git for-each-ref --sort=-committerdate --format='%(refname:short)|%(committerdate:relative)|%(objectname)' refs/remotes/origin"
      );
      
      setState(() => _isLoading = false);

      if (!mounted) return;

      final branches = output.split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.contains('->'))
          .map((e) {
            final parts = e.split('|');
            final fullName = parts[0];
            final name = fullName.replaceAll('origin/', '');
            final date = parts.length > 1 ? parts[1] : "";
            final hash = parts.length > 2 ? parts[2] : "";
            return {'name': name, 'date': date, 'hash': hash, 'fullName': fullName};
          })
          .toList();

      // Check for updates (ahead count) for each branch relative to local
      // This is expensive to do one by one. 
      // Instead, we can check if the remote hash is different from local hash for the *current* branch at least.
      // Or for all local branches.
      // Let's just check for the current branch for now to be fast, or maybe all if we can get local refs easily.
      
      // Get local refs
      final localRefsOutput = await ssh.executeCommand("cd /data/openpilot && git for-each-ref --format='%(refname:short)|%(objectname)' refs/heads");
      final localRefs = <String, String>{};
      for (final line in localRefsOutput.split('\n')) {
        final parts = line.trim().split('|');
        if (parts.length == 2) {
          localRefs[parts[0]] = parts[1];
        }
      }

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("브랜치 선택"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: branches.length,
              itemBuilder: (ctx, index) {
                final branch = branches[index];
                final name = branch['name']!;
                final date = branch['date']!;
                final hash = branch['hash']!;
                final isDefault = name == defaultBranch;
                final isCurrent = name == currentBranch;
                
                // Check if update available
                bool hasUpdate = false;
                if (localRefs.containsKey(name)) {
                  if (localRefs[name] != hash) {
                    hasUpdate = true;
                  }
                }

                return ListTile(
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
                        onPressed: () async {
                           if (repoUrl.isNotEmpty) {
                             final url = "$repoUrl/commits/$name";
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
                  onTap: () {
                    Navigator.pop(ctx);
                    _runGitCommand(context, "git checkout $name", "$name 브랜치로 변경됨");
                  },
                );
              },
            ),
          ),
        ),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      _addLog("브랜치 목록 실패: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Buttons Grid
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.5,
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
                () => _runGitCommand(context, "git reset --hard HEAD", "Git Reset 완료"),
              ),
              _buildActionButton(
                context,
                "Git Sync",
                Icons.sync,
                Colors.red,
                () => _runGitCommand(context, "git fetch --all && git reset --hard @{u}", "Git Sync 완료"),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildActionButton(
            context,
            "Rebuild All",
            Icons.build,
            Colors.purple,
            () => _runGitCommand(context, "scons -c && rm .sconsign.dblite", "Rebuild 시작됨"),
          ),

          const SizedBox(height: 20),
          Row(
            children: [
              const Text("로그:", style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 5),
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "[${log['time']}] ",
                          style: TextStyle(color: Colors.grey[500], fontSize: 12, fontFamily: 'monospace'),
                        ),
                        Expanded(
                          child: Text(
                            log['message']!,
                            style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, String label, IconData icon, Color color, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: _isLoading ? null : onTap,
      icon: Icon(icon, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withOpacity(0.8),
        foregroundColor: Colors.white,
        disabledBackgroundColor: color.withOpacity(0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
