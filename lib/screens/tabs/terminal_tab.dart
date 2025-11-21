import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/ssh_service.dart';
import '../../services/macro_service.dart';

class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  late final Terminal _terminal;
  final TerminalController _terminalController = TerminalController();
  SSHSession? _session;
  bool _isSessionActive = false;
  double _fontSize = 14.0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _terminal = Terminal(
      maxLines: 10000,
    );
    _startTerminal();
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

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _startTerminal() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) {
      _terminal.write('SSH 연결이 필요합니다.\r\n');
      return;
    }

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

  void _runMacro(String command) {
    if (_isSessionActive && _session != null) {
      _session!.write(utf8.encode("$command\n"));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("터미널 세션이 활성화되지 않았습니다.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final macros = Provider.of<MacroService>(context).macros;

    return Column(
      children: [
        // Toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              const Text("글자 크기: "),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: () => _updateFontSize(_fontSize - 1),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text("${_fontSize.toInt()}"),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _updateFontSize(_fontSize + 1),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
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
        
        // Macro Bar
        SizedBox(
          height: 50,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: macros.length,
            itemBuilder: (context, index) {
              final macro = macros[index];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(macro.name),
                  onPressed: () => _runMacro(macro.command),
                  avatar: const Icon(Icons.play_arrow, size: 16),
                ),
              );
            },
          ),
        ),

        if (!_isSessionActive)
          Container(
            color: Colors.red.withOpacity(0.1),
            padding: const EdgeInsets.all(8),
            width: double.infinity,
            child: const Text(
              "터미널 세션이 비활성 상태입니다.",
              style: TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ),
        Expanded(
          child: TerminalView(
            _terminal,
            controller: _terminalController,
            autofocus: true,
            backgroundOpacity: 0,
            textStyle: TerminalStyle(fontSize: _fontSize),
            theme: TerminalThemes.defaultTheme,
          ),
        ),
      ],
    );
  }
}
