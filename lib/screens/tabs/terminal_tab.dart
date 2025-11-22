import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart' as xterm;
import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ssh_service.dart';
import '../../services/macro_service.dart';
import 'macro_tab.dart';
// import 'system_tab.dart'; // Removed

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: "터미널", icon: Icon(Icons.terminal)),
            Tab(text: "매크로 관리", icon: Icon(Icons.edit_note)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              TerminalScreen(),
              MacroTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with AutomaticKeepAliveClientMixin {
  late final xterm.Terminal _terminal;
  final xterm.TerminalController _terminalController = xterm.TerminalController();
  SSHSession? _session;
  bool _isSessionActive = false;
  double _fontSize = 14.0;
  bool _showVirtualKeys = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _terminal = xterm.Terminal(
      maxLines: 10000,
    );
    // _startTerminal(); // Auto-connect removed
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fontSize = prefs.getDouble('terminal_font_size') ?? 14.0;
    });
  }

  Future<void> _updateFontSize(double newSize) async {
    final size = newSize.clamp(8.0, 32.0);
    setState(() => _fontSize = size);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('terminal_font_size', size);
  }

  void _sendMacro(String command) {
    if (_session != null) {
      _session!.write(utf8.encode("$command\n"));
      _terminal.write("\r\n> $command\r\n");
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("터미널이 연결되지 않았습니다.")),
      );
    }
  }

  void _sendKey(String key) {
    if (_session != null) {
      _session!.write(utf8.encode(key));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Auto-connect removed
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _startTerminal() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      _terminal.write('SSH 연결 대기 중...\r\n');
      return;
    }

    if (_isSessionActive) return;

    try {
      _terminal.write('터미널 세션 시작 중...\r\n');
      _session = await ssh.startShell();
      setState(() => _isSessionActive = true);

      _terminal.onOutput = (data) {
        _session?.write(utf8.encode(data));
      };

      _session!.stdout.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _session!.stderr.listen((data) {
        _terminal.write(utf8.decode(data));
      });

      _session!.done.then((_) {
        if (mounted) {
          setState(() => _isSessionActive = false);
          _terminal.write('\r\n세션이 종료되었습니다.\r\n');
        }
      });
    } catch (e) {
      _terminal.write('오류 발생: $e\r\n');
    }
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection != null) {
      final text = _terminal.buffer.getText(selection);
      if (text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("복사되었습니다."), duration: Duration(milliseconds: 500)),
          );
        }
        _terminalController.clearSelection();
      }
    } else {
       if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("선택된 텍스트가 없습니다."), duration: Duration(milliseconds: 500)),
          );
        }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _session?.write(utf8.encode(data!.text!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("붙여넣기 완료"), duration: Duration(milliseconds: 500)),
        );
      }
    }
  }

  Widget _buildVirtualKey(String label, String code) {
    return InkWell(
      onTap: () => _sendKey(code),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.withOpacity(0.3)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: () => _updateFontSize(_fontSize - 2),
                tooltip: "글자 작게",
              ),
              Text("${_fontSize.toInt()}pt"),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _updateFontSize(_fontSize + 2),
                tooltip: "글자 크게",
              ),
              Container(
                height: 24,
                width: 1,
                color: Colors.grey.withOpacity(0.5),
                margin: const EdgeInsets.symmetric(horizontal: 8),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: _copySelection,
                tooltip: "복사",
              ),
              IconButton(
                icon: const Icon(Icons.paste),
                onPressed: _paste,
                tooltip: "붙여넣기",
              ),
              IconButton(
                icon: Icon(_showVirtualKeys ? Icons.keyboard_hide : Icons.keyboard),
                onPressed: () => setState(() => _showVirtualKeys = !_showVirtualKeys),
                tooltip: "가상 키보드",
              ),
              const Spacer(),
              if (!_isSessionActive)
                ElevatedButton.icon(
                  onPressed: _startTerminal,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text("연결"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                )
              else
                ElevatedButton.icon(
                  onPressed: () {
                    _session?.close();
                    setState(() => _isSessionActive = false);
                  },
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text("끊기"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: xterm.TerminalView(
            _terminal,
            controller: _terminalController,
            textStyle: xterm.TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace'),
            readOnly: false,
          ),
        ),
        // Virtual Keypad
        if (_showVirtualKeys)
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildVirtualKey("ESC", "\x1b"),
                _buildVirtualKey("TAB", "\t"),
                _buildVirtualKey("▲", "\x1b[A"),
                _buildVirtualKey("▼", "\x1b[B"),
                _buildVirtualKey("◀", "\x1b[D"),
                _buildVirtualKey("▶", "\x1b[C"),
              ],
            ),
          ),
        // Quick Macro Bar
        Consumer<MacroService>(
          builder: (context, macroService, child) {
            if (macroService.macros.isEmpty) return const SizedBox.shrink();
            return Container(
              height: 50,
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                itemCount: macroService.macros.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final macro = macroService.macros[index];
                  return ActionChip(
                    label: Text(macro.name),
                    onPressed: () => _sendMacro(macro.command),
                    tooltip: macro.command,
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

