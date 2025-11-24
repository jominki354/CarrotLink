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
  double _fontSize = 14.0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialContent);
    _focusNode = FocusNode();
    _scrollController = ScrollController();
    _controller.addListener(() {
      if (!_isDirty) {
        setState(() => _isDirty = true);
      }
      // Rebuild to update line numbers if line count changes
      setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
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
      // Save main file
      await ssh.writeTextFile(widget.filePath, _controller.text);
      
      // Save backup if requested
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
    // Start searching from current position + 1
    int index = text.indexOf(query, currentPos + 1);
    
    if (index == -1) {
      // Wrap around
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

    // Check if current selection matches query
    final selection = _controller.selection;
    if (selection.isValid && 
        selection.textInside(text) == query) {
      
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        replacement,
      );
      
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: selection.start + replacement.length),
      );
      
      // Find next
      _findNext();
    } else {
      // If not selected, find first then user clicks replace again
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

  @override
  Widget build(BuildContext context) {
    // Calculate line count
    final lines = _controller.text.split('\n');
    final lineCount = lines.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filePath.split('/').last),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease),
            onPressed: () => setState(() => _fontSize = (_fontSize - 1).clamp(8.0, 32.0)),
            tooltip: "글자 작게",
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            onPressed: () => setState(() => _fontSize = (_fontSize + 1).clamp(8.0, 32.0)),
            tooltip: "글자 크게",
          ),
          IconButton(
            icon: Icon(_showFind ? Icons.search_off : Icons.search),
            onPressed: () {
              setState(() {
                _showFind = !_showFind;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _isDirty ? _save : null,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showFind)
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                border: Border(
                  bottom: BorderSide(color: Theme.of(context).dividerColor),
                ),
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
                            prefixIcon: const Icon(Icons.search, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                          onSubmitted: (_) => _findNext(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        icon: const Icon(Icons.arrow_downward),
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
                            prefixIcon: const Icon(Icons.edit, size: 20),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _replace,
                        child: const Text("바꾸기"),
                      ),
                      TextButton(
                        onPressed: _replaceAll,
                        child: const Text("모두"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: Container(
              color: Theme.of(context).colorScheme.surface,
              child: SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Line Numbers
                    Container(
                      width: 40,
                      padding: const EdgeInsets.only(top: 16, right: 4), // Match TextField padding
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Column(
                        children: List.generate(lineCount, (index) {
                          return SizedBox(
                            height: _fontSize * 1.2, // Approximate height matching TextStyle height
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: _fontSize,
                                color: Colors.grey,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          );
                        }),
                      ),
                    ),
                    // Vertical Divider
                    Container(width: 1, color: Colors.grey.withOpacity(0.5)),
                    // Text Field
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null, // Allow growing
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                          height: 1.2,
                        ),
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.all(16),
                          border: InputBorder.none, // Remove border
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
