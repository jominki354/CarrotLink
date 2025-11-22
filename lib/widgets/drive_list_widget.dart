import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';

class DriveListWidget extends StatefulWidget {
  const DriveListWidget({super.key});

  @override
  State<DriveListWidget> createState() => _DriveListWidgetState();
}

class _DriveListWidgetState extends State<DriveListWidget> {
  List<String> _routes = [];
  bool _isLoading = false;
  bool _isInit = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInit) {
      final ssh = Provider.of<SSHService>(context);
      if (ssh.isConnected) {
        _loadRoutes();
        _isInit = false; // Only load once automatically when connected
      }
    }
  }

  Future<void> _loadRoutes() async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) return;

    setState(() => _isLoading = true);
    try {
      // Add a small delay to ensure SFTP is ready
      await Future.delayed(const Duration(milliseconds: 500));
      final files = await ssh.listFiles('/data/media/0/realdata');
      // Group by route name (remove --segment)
      // Example: 2023-10-27--12-34-56--0 -> 2023-10-27--12-34-56
      final Set<String> routeSet = {};
      for (final f in files) {
        if (f.attr.isDirectory && f.filename.contains('--')) {
          final parts = f.filename.split('--');
          if (parts.length >= 2) {
            // Join all parts except the last one (segment number)
            final routeName = parts.sublist(0, parts.length - 1).join('--');
            routeSet.add(routeName);
          }
        }
      }
      
      final routes = routeSet.toList()..sort((a, b) => b.compareTo(a));

      if (mounted) {
        setState(() {
          _routes = routes;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _openRoute(String route) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RouteDetailScreen(route: route),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_routes.isEmpty) return const Center(child: Text("주행 기록이 없습니다."));

    return Material(
      color: Colors.transparent,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _routes.length,
        itemBuilder: (context, index) {
          final route = _routes[index];
          return SizedBox(
            width: 200, // Fixed width for horizontal items
            child: RouteCard(route: route, onTap: () => _openRoute(route)),
          );
        },
      ),
    );
  }
}

class RouteCard extends StatefulWidget {
  final String route;
  final VoidCallback onTap;

  const RouteCard({super.key, required this.route, required this.onTap});

  @override
  State<RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<RouteCard> {
  File? _previewImage;
  bool _loadingImage = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    if (_loadingImage) return;
    if (mounted) setState(() => _loadingImage = true);

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/${widget.route}_preview.gif';
      final file = File(localPath);

      if (await file.exists()) {
        if (mounted) setState(() => _previewImage = file);
      } else {
        // Only load if connected
        if (!ssh.isConnected) return;

        final remoteDir = '/data/media/0/realdata/${widget.route}--0';
        final remoteGif = '$remoteDir/preview.gif';
        final remoteVideo = '$remoteDir/qcamera.ts';

        // Check if gif exists remotely
        final existsCmd = 'test -f $remoteGif && echo "yes" || echo "no"';
        final exists = (await ssh.executeCommand(existsCmd)).trim() == "yes";

        if (!exists) {
          // Generate GIF - use -t 1 for faster generation (1 second only)
          final genCmd = 'ffmpeg -y -i $remoteVideo -ss 5 -t 1 -vf scale=320:-1 -r 10 $remoteGif';
          // Run in background or wait? Waiting might block if many items load at once.
          // But we are in async function.
          await ssh.executeCommand(genCmd);
        }

        // Download GIF
        final content = await ssh.readBinaryFile(remoteGif);
        await file.writeAsBytes(content);
        if (mounted) setState(() => _previewImage = file);
      }
    } catch (e) {
      print("Preview error: $e");
    } finally {
      if (mounted) setState(() => _loadingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 150,
              width: double.infinity,
              child: _previewImage != null
                  ? Image.file(_previewImage!, fit: BoxFit.cover)
                  : Container(
                      color: Colors.black12,
                      child: Center(
                        child: _loadingImage
                            ? const SizedBox(
                                width: 24, 
                                height: 24, 
                                child: CircularProgressIndicator(strokeWidth: 2)
                              )
                            : const Icon(Icons.movie, size: 50, color: Colors.grey),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.route,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Tap to view segments",
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SegmentTile extends StatefulWidget {
  final String route;
  final String segment;
  final VoidCallback onTap;

  const SegmentTile({
    super.key,
    required this.route,
    required this.segment,
    required this.onTap,
  });

  @override
  State<SegmentTile> createState() => _SegmentTileState();
}

class _SegmentTileState extends State<SegmentTile> {
  File? _thumbnail;
  bool _loading = false;
  
  // Static queue to limit concurrent ffmpeg processes
  static int _activeGenerations = 0;
  static final List<Function> _taskQueue = [];

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (_loading) return;
    if (mounted) setState(() => _loading = true);

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/${widget.route}--${widget.segment}.jpg';
      final file = File(localPath);

      if (await file.exists()) {
        if (mounted) setState(() => _thumbnail = file);
      } else {
        if (!ssh.isConnected) return;

        // Enqueue remote generation
        _enqueueTask(() async {
          if (!mounted) return;
          
          final segmentIndex = widget.segment.split('--').last;
          final remoteDir = '/data/media/0/realdata/${widget.route}--$segmentIndex';
          final remoteImg = '$remoteDir/thumbnail.jpg';
          final remoteVideo = '$remoteDir/qcamera.ts';

          // Check if thumbnail exists remotely
          final existsCmd = 'test -f $remoteImg && echo "yes" || echo "no"';
          final exists = (await ssh.executeCommand(existsCmd)).trim() == "yes";

          if (!exists) {
            // Generate thumbnail
            final genCmd = 'ffmpeg -y -i $remoteVideo -ss 5 -vframes 1 -vf scale=160:-1 $remoteImg';
            await ssh.executeCommand(genCmd);
          }

          final content = await ssh.readBinaryFile(remoteImg);
          await file.writeAsBytes(content);
          if (mounted) setState(() => _thumbnail = file);
        });
      }
    } catch (e) {
      // Ignore errors
    } finally {
      if (mounted && _thumbnail != null) setState(() => _loading = false);
      // If failed, keep loading false but no image
      if (mounted && _thumbnail == null) setState(() => _loading = false);
    }
  }

  void _enqueueTask(Future<void> Function() task) {
    if (_activeGenerations < 2) { // Max 2 concurrent tasks
      _activeGenerations++;
      task().then((_) => _processNext()).catchError((_) => _processNext());
    } else {
      _taskQueue.add(task);
    }
  }

  static void _processNext() {
    _activeGenerations--;
    if (_taskQueue.isNotEmpty) {
      _activeGenerations++;
      final nextTask = _taskQueue.removeAt(0);
      nextTask().then((_) => _processNext()).catchError((_) => _processNext());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 80,
        height: 45,
        color: Colors.black12,
        child: _thumbnail != null
            ? Image.file(_thumbnail!, fit: BoxFit.cover)
            : (_loading
                ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                : const Icon(Icons.play_circle_outline)),
      ),
      title: Text(widget.segment),
      trailing: const Icon(Icons.open_in_browser),
      onTap: widget.onTap,
    );
  }
}

class RouteDetailScreen extends StatefulWidget {
  final String route;
  const RouteDetailScreen({super.key, required this.route});

  @override
  State<RouteDetailScreen> createState() => _RouteDetailScreenState();
}

class _RouteDetailScreenState extends State<RouteDetailScreen> {
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
      // List all folders in realdata that start with route
      final files = await ssh.listFiles('/data/media/0/realdata');
      final segments = files
          .where((f) => f.attr.isDirectory && f.filename.startsWith('${widget.route}--'))
          .map((f) => f.filename) // Keep full filename
          .toList()
        ..sort((a, b) => a.compareTo(b));

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

  Future<void> _playInBrowser(String segmentFilename) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final ip = ssh.connectedIp ?? '192.168.0.1';
    
    // Extract segment number from filename: route--N
    final segmentIndex = segmentFilename.split('--').last;
    
    final url = Uri.parse('http://$ip:8082/footage/${widget.route}?$segmentIndex,qcamera');
    
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("브라우저를 열 수 없습니다.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.route)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _segments.length,
              itemBuilder: (context, index) {
                final segment = _segments[index];
                return SegmentTile(
                  route: widget.route,
                  segment: segment,
                  onTap: () => _playInBrowser(segment),
                );
              },
            ),
    );
  }
}


// Removed VideoPlayerScreen class

