import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ssh_service.dart';
import '../../widgets/custom_toast.dart';

class FileEditorScreen extends StatefulWidget {
  final String filePath;
  final String initialContent;

  const FileEditorScreen({
    super.key,
    required this.filePath,
    required this.initialContent,
  });

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late ScrollController _scrollController;
  bool _isDirty = false;
  bool _showFind = false;
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  double _fontSize = 13.0;
  int _currentLine = 1;
  int _currentColumn = 1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
    _focusNode = FocusNode();
    _scrollController = ScrollController();
    
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (!_isDirty) {
      setState(() => _isDirty = true);
    }
    _updateCursorPosition();
  }

  void _updateCursorPosition() {
    final text = _controller.text;
    final cursorPos = _controller.selection.baseOffset;
    
    if (cursorPos < 0 || cursorPos > text.length) {
      setState(() {
        _currentLine = 1;
        _currentColumn = 1;
      });
      return;
    }
    
    final textBeforeCursor = text.substring(0, cursorPos);
    final lines = textBeforeCursor.split('\n');
    
    setState(() {
      _currentLine = lines.length;
      _currentColumn = lines.last.length + 1;
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    if (!_isDirty) return true;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("저장하지 않은 변경사항"),
        content: const Text("변경사항을 저장하지 않고 나가시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("저장 안 함"),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context, false);
              await _save();
              if (mounted && !_isDirty) {
                Navigator.pop(context);
              }
            },
            child: const Text("저장"),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _save() async {
    bool createBackup = false;
    
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text("파일 저장"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("변경 사항을 저장하시겠습니까?"),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    title: const Text("백업본 만들기 (.backup)"),
                    value: createBackup,
                    onChanged: (value) {
                      setState(() => createBackup = value ?? false);
                    },
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text("취소"),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text("저장"),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave != true) return;

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      await ssh.writeTextFile(widget.filePath, _controller.text);
      
      if (createBackup) {
        await ssh.writeTextFile("${widget.filePath}.backup", _controller.text);
      }

      setState(() => _isDirty = false);
      if (mounted) {
        CustomToast.show(context, createBackup ? "저장 및 백업 완료" : "저장되었습니다.");
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, "저장 실패: $e", isError: true);
      }
    }
  }

  void _findNext() {
    final text = _controller.text;
    final query = _findController.text;
    if (query.isEmpty) return;

    final currentPos = _controller.selection.baseOffset;
    int index = text.indexOf(query, currentPos + 1);
    
    if (index == -1) {
      index = text.indexOf(query);
    }

    if (index != -1) {
      _controller.selection = TextSelection(
        baseOffset: index,
        extentOffset: index + query.length,
      );
      _focusNode.requestFocus();
    } else {
      CustomToast.show(context, "찾을 수 없습니다.", isError: true);
    }
  }

  void _replace() {
    final text = _controller.text;
    final query = _findController.text;
    final replacement = _replaceController.text;
    
    if (query.isEmpty) return;

    final selection = _controller.selection;
    if (selection.isValid && selection.textInside(text) == query) {
      final newText = text.replaceRange(selection.start, selection.end, replacement);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: selection.start + replacement.length),
      );
      _findNext();
    } else {
      _findNext();
    }
  }

  void _replaceAll() {
    final text = _controller.text;
    final query = _findController.text;
    final replacement = _replaceController.text;
    
    if (query.isEmpty) return;

    final newText = text.replaceAll(query, replacement);
    if (newText != text) {
      _controller.text = newText;
      CustomToast.show(context, "모두 바꾸기 완료");
    }
  }

  void _goToLine() async {
    final lineCount = _controller.text.split('\n').length;
    final controller = TextEditingController();
    
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("줄 이동"),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: "1 - $lineCount",
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            final line = int.tryParse(value);
            Navigator.pop(context, line);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          FilledButton(
            onPressed: () {
              final line = int.tryParse(controller.text);
              Navigator.pop(context, line);
            },
            child: const Text("이동"),
          ),
        ],
      ),
    );
    
    if (result != null && result >= 1 && result <= lineCount) {
      final lines = _controller.text.split('\n');
      int offset = 0;
      for (int i = 0; i < result - 1; i++) {
        offset += lines[i].length + 1;
      }
      _controller.selection = TextSelection.collapsed(offset: offset);
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _controller.text.split('\n');
    final lineCount = lines.length;
    final lineHeight = _fontSize * 1.5;
    final lineNumberWidth = (lineCount.toString().length * 10.0 + 24).clamp(40.0, 80.0);
    
    // 하단 네비바 높이 + 상태바 높이 계산
    final bottomPadding = MediaQuery.of(context).padding.bottom + 80;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.filePath.split('/').last,
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                "줄 $_currentLine, 열 $_currentColumn",
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.text_decrease, size: 20),
              onPressed: () => setState(() => _fontSize = (_fontSize - 1).clamp(8.0, 24.0)),
              tooltip: "글자 작게",
            ),
            IconButton(
              icon: const Icon(Icons.text_increase, size: 20),
              onPressed: () => setState(() => _fontSize = (_fontSize + 1).clamp(8.0, 24.0)),
              tooltip: "글자 크게",
            ),
            IconButton(
              icon: const Icon(Icons.format_list_numbered, size: 20),
              onPressed: _goToLine,
              tooltip: "줄 이동",
            ),
            IconButton(
              icon: Icon(_showFind ? Icons.search_off : Icons.search, size: 20),
              onPressed: () => setState(() => _showFind = !_showFind),
              tooltip: "찾기/바꾸기",
            ),
            IconButton(
              icon: Icon(Icons.save, size: 20, color: _isDirty ? Colors.orange : null),
              onPressed: _isDirty ? _save : null,
              tooltip: "저장",
            ),
          ],
        ),
        body: Column(
          children: [
            // 찾기/바꾸기 패널
            if (_showFind)
              Container(
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _findController,
                            decoration: InputDecoration(
                              hintText: "찾기",
                              isDense: true,
                              prefixIcon: const Icon(Icons.search, size: 18),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            style: const TextStyle(fontSize: 14),
                            onSubmitted: (_) => _findNext(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          onPressed: _findNext,
                          tooltip: "다음 찾기",
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replaceController,
                            decoration: InputDecoration(
                              hintText: "바꾸기",
                              isDense: true,
                              prefixIcon: const Icon(Icons.find_replace, size: 18),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(onPressed: _replace, child: const Text("바꾸기")),
                        TextButton(onPressed: _replaceAll, child: const Text("모두")),
                      ],
                    ),
                  ],
                ),
              ),
            
            // 에디터 본체 - CustomScrollView 사용으로 동기화 문제 해결
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    controller: _scrollController,
                    child: Padding(
                      // 하단에 여유 공간 추가 (네비바에 가려지지 않도록)
                      padding: EdgeInsets.only(bottom: bottomPadding),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 줄 번호 (같은 스크롤 컨테이너 안에 있으므로 자동 동기화)
                            Container(
                              width: lineNumberWidth,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                border: Border(
                                  right: BorderSide(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                              ),
                              child: Column(
                                children: List.generate(lineCount, (index) {
                                  final isCurrentLine = index + 1 == _currentLine;
                                  return Container(
                                    height: lineHeight,
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 8, left: 4),
                                    decoration: isCurrentLine ? BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                                    ) : null,
                                    child: Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: _fontSize,
                                        height: 1.5,
                                        color: isCurrentLine 
                                            ? Theme.of(context).colorScheme.primary
                                            : Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                        fontWeight: isCurrentLine ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ),
                            // 텍스트 에디터
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minWidth: constraints.maxWidth - lineNumberWidth,
                                  ),
                                  child: IntrinsicWidth(
                                    child: TextField(
                                      controller: _controller,
                                      focusNode: _focusNode,
                                      maxLines: null,
                                      keyboardType: TextInputType.multiline,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: _fontSize,
                                        height: 1.5,
                                      ),
                                      decoration: const InputDecoration(
                                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                        border: InputBorder.none,
                                        isDense: true,
                                      ),
                                      onTap: _updateCursorPosition,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            
            // 상태바 (항상 화면 하단에 고정)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: 14, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                    const SizedBox(width: 6),
                    Text(
                      "줄 $lineCount",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.text_fields, size: 14, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                    const SizedBox(width: 6),
                    Text(
                      "${_controller.text.length}자",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const Spacer(),
                    if (_isDirty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.circle, size: 8, color: Colors.orange),
                            SizedBox(width: 4),
                            Text(
                              "수정됨",
                              style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
