import 'package:carrot_pilot_manager/screens/tabs/file_editor_screen.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import '../../services/ssh_service.dart';
import '../../constants.dart';
import '../../widgets/custom_toast.dart';

class FileExplorerTab extends StatefulWidget {
  const FileExplorerTab({super.key});

  @override
  State<FileExplorerTab> createState() => _FileExplorerTabState();
}

class _FileExplorerTabState extends State<FileExplorerTab> {
  String _currentPath = CarrotConstants.openpilotPath; // Default openpilot path
  List<SftpName> _files = [];
  List<SftpName> _filteredFiles = [];
  bool _isLoading = false;
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  List<String> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
    // _loadFiles(); // Removed to prevent "Not connected" error on startup
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ssh = Provider.of<SSHService>(context);
    if (ssh.isConnected && _files.isEmpty && !_isLoading) {
      _loadFiles();
    }
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _bookmarks = prefs.getStringList('file_bookmarks') ?? [CarrotConstants.openpilotPath, CarrotConstants.mediaPath];
    });
  }

  Future<void> _addBookmark() async {
    if (!_bookmarks.contains(_currentPath)) {
      final prefs = await SharedPreferences.getInstance();
      final newBookmarks = List<String>.from(_bookmarks)..add(_currentPath);
      await prefs.setStringList('file_bookmarks', newBookmarks);
      setState(() {
        _bookmarks = newBookmarks;
      });
      if (mounted) {
        CustomToast.show(context, "북마크 추가됨");
      }
    }
  }

  Future<void> _removeBookmark(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final newBookmarks = List<String>.from(_bookmarks)..remove(path);
    await prefs.setStringList('file_bookmarks', newBookmarks);
    setState(() {
      _bookmarks = newBookmarks;
    });
  }

  void _showBookmarks() {
    showModalBottomSheet(
      context: context,
      builder: (context) => ListView(
        children: [
          const ListTile(title: Text("북마크", style: TextStyle(fontWeight: FontWeight.bold))),
          ..._bookmarks.map((path) => ListTile(
            leading: const Icon(Icons.bookmark),
            title: Text(path),
            onTap: () {
              Navigator.pop(context);
              _navigate(path);
            },
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                Navigator.pop(context);
                _removeBookmark(path);
              },
            ),
          )),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text("현재 위치 추가"),
            onTap: () {
              Navigator.pop(context);
              _addBookmark();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) return;

    setState(() => _isLoading = true);
    try {
      final files = await ssh.listFiles(_currentPath);
      if (mounted) {
        setState(() {
          _files = files.where((f) => f.filename != '.' && f.filename != '..').toList();
          _filterFiles();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        // Don't show toast for connection closed if we are navigating away
        if (!e.toString().contains("Connection closed")) {
           CustomToast.show(context, "오류: $e", isError: true);
        }
      }
    }
  }

  void _filterFiles() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      _filteredFiles = List.from(_files);
    } else {
      _filteredFiles = _files.where((f) => f.filename.toLowerCase().contains(query)).toList();
    }
    // Sort: Directories first, then files
    _filteredFiles.sort((a, b) {
      if (a.attr.isDirectory && !b.attr.isDirectory) return -1;
      if (!a.attr.isDirectory && b.attr.isDirectory) return 1;
      return a.filename.compareTo(b.filename);
    });
  }

  Future<void> _navigate(String path) async {
    setState(() => _isLoading = true);
    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      // Normalize path to avoid double slashes or weird segments
      final normalizedPath = p.posix.normalize(path);
      final files = await ssh.listFiles(normalizedPath);
      if (mounted) {
        setState(() {
          _currentPath = normalizedPath;
          _files = files.where((f) => f.filename != '.' && f.filename != '..').toList();
          _filterFiles();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        
        // Check if it's a "No such file" error
        final errorStr = e.toString();
        if (errorStr.contains("No such file") || errorStr.contains("code 2")) {
           _showPathNotFoundError(path);
        } else {
           CustomToast.show(context, "이동 실패: $path\n$e", isError: true);
        }
      }
    }
  }

  void _showPathNotFoundError(String path) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("경로를 찾을 수 없음"),
        content: Text("'$path' 경로가 존재하지 않습니다.\n북마크에서 제거하시겠습니까?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          if (_bookmarks.contains(path))
            TextButton(
              onPressed: () {
                _removeBookmark(path);
                Navigator.pop(context);
                CustomToast.show(context, "북마크가 제거되었습니다.");
              },
              child: const Text("북마크 제거", style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }

  void _goUp() {
    if (_currentPath == "/") return;
    final newPath = p.posix.dirname(_currentPath);
    _navigate(newPath);
  }

  void _goHome() {
    _navigate("/data/openpilot");
  }

  Future<void> _deleteItem(SftpName item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("삭제 확인"),
        content: Text("${item.filename} 파일을 삭제하시겠습니까?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("취소")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("삭제"),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      try {
        final fullPath = p.posix.join(_currentPath, item.filename);
        await ssh.deleteFile(fullPath);
        _loadFiles();
        if (mounted) {
          CustomToast.show(context, "삭제됨");
        }
      } catch (e) {
        if (mounted) {
          CustomToast.show(context, "삭제 실패: $e", isError: true);
        }
      }
    }
  }

  Future<void> _editFile(SftpName item) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final fullPath = p.posix.join(_currentPath, item.filename);
    
    try {
      // Check file size first. If too big, warn or skip.
      if ((item.attr.size ?? 0) > 1024 * 1024) { // 1MB limit for text editing
         CustomToast.show(context, "파일이 너무 커서 편집할 수 없습니다.", isError: true);
         return;
      }

      final content = await ssh.readTextFile(fullPath);
      if (!mounted) return;
      
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FileEditorScreen(
            filePath: fullPath,
            initialContent: content,
          ),
        ),
      );
      // Reload after edit
      _loadFiles();
      
    } catch (e) {
      if (mounted) {
        String title = "파일 열기 실패";
        String message = "파일을 읽는 도중 오류가 발생했습니다.";
        
        final errorStr = e.toString();
        if (errorStr.contains("code 4") || errorStr.contains("Failure")) {
          if (item.attr.isSymbolicLink) {
             message = "심볼릭 링크가 가리키는 원본 파일을 찾을 수 없거나 접근할 수 없습니다.";
          } else {
             message = "파일을 읽을 수 없습니다. (시스템 오류)";
          }
        } else if (errorStr.contains("Permission denied")) {
           message = "파일에 접근할 권한이 없습니다.";
        }

        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 8),
                const Text("상세 오류:", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                Text(errorStr, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("확인")),
            ],
          ),
        );
      }
    }
  }

  Future<void> _renameItem(SftpName item) async {
    final controller = TextEditingController(text: item.filename);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("이름 바꾸기"),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: "새 이름")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text("확인")),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != item.filename) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      try {
        final oldPath = p.posix.join(_currentPath, item.filename);
        final newPath = p.posix.join(_currentPath, newName);
        await ssh.renameFile(oldPath, newPath);
        _loadFiles();
        if (mounted) CustomToast.show(context, "이름 변경됨");
      } catch (e) {
        if (mounted) CustomToast.show(context, "오류: $e", isError: true);
      }
    }
  }

  Future<void> _changePermissions(SftpName item) async {
    final controller = TextEditingController(text: "755"); // Default
    final perms = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("권한 변경 (chmod)"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("예: 755, 644, 777"),
            TextField(controller: controller, keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("취소")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text("확인")),
        ],
      ),
    );

    if (perms != null && perms.isNotEmpty) {
      final ssh = Provider.of<SSHService>(context, listen: false);
      try {
        final fullPath = p.posix.join(_currentPath, item.filename);
        await ssh.executeCommand("chmod $perms $fullPath");
        _loadFiles();
        if (mounted) CustomToast.show(context, "권한 변경됨");
      } catch (e) {
        if (mounted) CustomToast.show(context, "오류: $e", isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
              ),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.home),
                    onPressed: _goHome,
                    tooltip: "홈 (/data/openpilot)",
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: _currentPath == "/" ? null : _goUp,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bookmark_border),
                    onPressed: _showBookmarks,
                    tooltip: "북마크",
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _isSearching 
                      ? TextField(
                          controller: _searchController,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: "검색...",
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() {
                                  _isSearching = false;
                                  _searchController.clear();
                                  _filterFiles();
                                });
                              },
                            ),
                          ),
                          onChanged: (value) {
                            setState(() {
                              _filterFiles();
                            });
                          },
                        )
                      : GestureDetector(
                          onTap: () {
                            // Maybe allow manual path entry?
                          },
                          child: Text(
                            _currentPath,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ),
                  if (!_isSearching)
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () {
                        setState(() {
                          _isSearching = true;
                        });
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _loadFiles,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_isLoading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 150),
            itemCount: _filteredFiles.length,
            itemBuilder: (context, index) {
              final item = _filteredFiles[index];
              final isDir = item.attr.isDirectory;
              final isLink = item.attr.isSymbolicLink;
              return ListTile(
                leading: Icon(
                  isDir ? Icons.folder : (isLink ? Icons.link : Icons.insert_drive_file),
                  color: isDir ? Colors.amber : (isLink ? Colors.blue : Colors.grey),
                ),
                title: Text(item.filename),
                subtitle: isDir ? null : Text(item.attr.size != null ? "${(item.attr.size! / 1024).toStringAsFixed(1)} KB" : ""),
                onTap: () {
                  if (isDir) {
                    final newPath = p.posix.join(_currentPath, item.filename);
                    _navigate(newPath);
                  } else {
                    _editFile(item);
                  }
                },
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        _editFile(item);
                        break;
                      case 'rename':
                        _renameItem(item);
                        break;
                      case 'chmod':
                        _changePermissions(item);
                        break;
                      case 'delete':
                        _deleteItem(item);
                        break;
                    }
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    if (!isDir)
                      const PopupMenuItem<String>(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit),
                          title: Text('편집'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem<String>(
                      value: 'rename',
                      child: ListTile(
                        leading: Icon(Icons.drive_file_rename_outline),
                        title: Text('이름 바꾸기'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'chmod',
                      child: ListTile(
                        leading: Icon(Icons.lock),
                        title: Text('권한 설정'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete, color: Colors.red),
                        title: Text('삭제', style: TextStyle(color: Colors.red)),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
