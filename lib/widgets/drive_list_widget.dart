import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../services/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';

class DriveListWidget extends StatefulWidget {
  const DriveListWidget({super.key});

  @override
  State<DriveListWidget> createState() => _DriveListWidgetState();
}

class _DriveListWidgetState extends State<DriveListWidget> {
  List<SftpName> _drives = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadDrives();
  }

  Future<void> _loadDrives() async {
    setState(() => _isLoading = true);
    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final files = await ssh.listFiles('/data/media/0/realdata');
      // Filter for directories and sort by name desc
      // Usually drives are folders like "2023-10-27--12-34-56"
      final drives = files.where((f) => f.attr.isDirectory && f.filename.contains('--')).toList()
        ..sort((a, b) => b.filename.compareTo(a.filename));
      
      if (mounted) {
        setState(() {
          _drives = drives;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openDrive(String driveName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DriveDetailScreen(driveName: driveName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_drives.isEmpty) return const Center(child: Text("주행 기록이 없습니다."));

    return Material(
      color: Colors.transparent,
      child: ListView.builder(
        itemCount: _drives.length,
        itemBuilder: (context, index) {
          final drive = _drives[index];
          return ListTile(
            leading: const Icon(Icons.drive_eta),
            title: Text(drive.filename),
            subtitle: Text(DateTime.fromMillisecondsSinceEpoch((drive.attr.modifyTime ?? 0) * 1000).toString()),
            onTap: () => _openDrive(drive.filename),
          );
        },
      ),
    );
  }
}

class DriveDetailScreen extends StatefulWidget {
  final String driveName;
  const DriveDetailScreen({super.key, required this.driveName});

  @override
  State<DriveDetailScreen> createState() => _DriveDetailScreenState();
}

class _DriveDetailScreenState extends State<DriveDetailScreen> {
  List<String> _segments = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSegments();
  }

  Future<void> _loadSegments() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final path = '/data/media/0/realdata/${widget.driveName}';
      final files = await ssh.listFiles(path);
      // Segments are directories named 0, 1, 2...
      final segments = files
          .where((f) => f.attr.isDirectory && int.tryParse(f.filename) != null)
          .map((f) => f.filename)
          .toList()
        ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));

      if (mounted) {
        setState(() {
          _segments = segments;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _playSegment(String segment) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/qcamera_$segment.ts';
      final remotePath = '/data/media/0/realdata/${widget.driveName}/$segment/qcamera.ts';
      
      final file = File(localPath);
      if (await file.exists()) await file.delete();

      final content = await ssh.readBinaryFile(remotePath);
      await file.writeAsBytes(content);
      
      if (!mounted) return;
      Navigator.pop(context); // Close loading

      final result = await OpenFilex.open(localPath);
      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("파일 열기 실패: ${result.message}")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("재생 실패: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.driveName)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _segments.length,
              itemBuilder: (context, index) {
                final segment = _segments[index];
                return ListTile(
                  leading: const Icon(Icons.videocam),
                  title: Text("Segment $segment"),
                  onTap: () => _playSegment(segment),
                );
              },
            ),
    );
  }
}

// Removed VideoPlayerScreen class

