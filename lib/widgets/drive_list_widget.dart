import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'design_components.dart';
import 'custom_toast.dart';

class DriveListWidget extends StatefulWidget {
  const DriveListWidget({super.key});

  @override
  State<DriveListWidget> createState() => _DriveListWidgetState();
}

class _DriveListWidgetState extends State<DriveListWidget> {
  List<String> _routes = [];
  bool _isLoading = false;
  bool _isInit = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Auto-refresh every 15 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) {
        final ssh = Provider.of<SSHService>(context, listen: false);
        if (ssh.isConnected) {
          _loadRoutes(silent: true);
        }
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

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

  Future<void> _loadRoutes({bool silent = false}) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    if (!ssh.isConnected) return;

    if (!silent) {
      setState(() => _isLoading = true);
    }
    
    try {
      // Add a small delay to ensure SFTP is ready
      if (!silent) await Future.delayed(const Duration(milliseconds: 500));
      
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
            child: RouteCard(
              route: route, 
              index: index,
              onTap: () => _openRoute(route)
            ),
          );
        },
      ),
    );
  }
}

class RouteCard extends StatefulWidget {
  final String route;
  final int index;
  final VoidCallback onTap;

  const RouteCard({
    super.key, 
    required this.route, 
    required this.index,
    required this.onTap
  });

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

  String _formatRouteName(String route) {
    // Example: 00000001-8b... -> 001-8b...
    // Removes leading zeros but keeps at least 3 digits if it starts with numbers
    return route.replaceFirst(RegExp(r'^0+(?=\d{3})'), '');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: DesignCard(
        padding: EdgeInsets.zero,
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
                    _formatRouteName(widget.route),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "자세히 보기",
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
  final int index;
  final VoidCallback onTap;

  const SegmentTile({
    super.key,
    required this.route,
    required this.segment,
    required this.index,
    required this.onTap,
  });

  @override
  State<SegmentTile> createState() => _SegmentTileState();
}

class _SegmentTileState extends State<SegmentTile> {
  File? _thumbnail;
  bool _loading = false;
  bool _sharing = false;
  
  // Static queue to limit concurrent ffmpeg processes
  static int _activeGenerations = 0;
  static final List<Function> _taskQueue = [];

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _shareSegment() async {
    if (_sharing) return;
    setState(() => _sharing = true);

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      if (!ssh.isConnected) {
        CustomToast.show(context, "연결이 필요합니다.", isError: true);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final convertToMp4 = prefs.getBool('share_convert_mp4') ?? false;

      if (mounted) {
        CustomToast.show(context, convertToMp4 ? "MP4 변환 및 파일 준비 중..." : "파일 다운로드 및 준비 중...");
      }

      final tempDir = await getTemporaryDirectory();
      final segmentIndex = widget.segment.split('--').last;
      final remoteDir = '/data/media/0/realdata/${widget.route}--$segmentIndex';
      
      // Files to share
      final filesToShare = <XFile>[];
      final fileNames = ['qcamera.ts', 'rlog', 'qlog']; // Common files

      for (final name in fileNames) {
        var remotePath = '$remoteDir/$name';
        var localFileName = '${widget.route}--$segmentIndex--$name';
        
        // Handle MP4 conversion for qcamera.ts
        if (convertToMp4 && name == 'qcamera.ts') {
          final mp4Name = 'qcamera.mp4';
          final remoteMp4Path = '$remoteDir/$mp4Name';
          localFileName = '${widget.route}--$segmentIndex--$mp4Name';
          
          // Check if mp4 already exists remotely
          final existsMp4Cmd = 'test -f $remoteMp4Path && echo "yes" || echo "no"';
          final existsMp4 = (await ssh.executeCommand(existsMp4Cmd)).trim() == "yes";
          
          if (!existsMp4) {
             // CustomToast.show(context, "MP4 변환 중... (잠시만 기다려주세요)");
             // Convert using ffmpeg. -c copy is fast if container change is enough.
             // But qcamera.ts might need re-muxing. -c copy usually works for ts->mp4 if codecs are compatible.
             // If not, we might need -c:v libx264 etc. but that's slow on device.
             // Let's try -c copy first.
             final convertCmd = 'ffmpeg -y -i $remotePath -c copy $remoteMp4Path';
             await ssh.executeCommand(convertCmd);
          }
          
          remotePath = remoteMp4Path;
        }

        final localPath = '${tempDir.path}/$localFileName';
        final file = File(localPath);

        // Check if remote file exists (or the converted one)
        final existsCmd = 'test -f $remotePath && echo "yes" || echo "no"';
        final exists = (await ssh.executeCommand(existsCmd)).trim() == "yes";

        if (exists) {
          // Download if not exists locally
          if (!await file.exists()) {
             // CustomToast.show(context, "${remotePath.split('/').last} 다운로드 중...");
             final content = await ssh.readBinaryFile(remotePath);
             await file.writeAsBytes(content);
          }
          filesToShare.add(XFile(localPath));
        }
      }

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare, text: "${widget.route} -- Segment ${widget.index}");
      } else {
        if (mounted) CustomToast.show(context, "공유할 파일이 없습니다.", isError: true);
      }

    } catch (e) {
      if (mounted) CustomToast.show(context, "공유 실패: $e", isError: true);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
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
      title: Text(
        widget.segment,
        style: const TextStyle(fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        widget.segment,
        style: const TextStyle(fontSize: 10, color: Colors.grey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: _sharing 
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.share),
            onPressed: _shareSegment,
          ),
          const Icon(Icons.open_in_browser),
        ],
      ),
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
          .toList();
        
      // Numerical sort
      segments.sort((a, b) {
        final indexA = int.tryParse(a.split('--').last) ?? 0;
        final indexB = int.tryParse(b.split('--').last) ?? 0;
        return indexA.compareTo(indexB);
      });

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
                  index: index + 1,
                  onTap: () => _playInBrowser(segment),
                );
              },
            ),
    );
  }
}


// Removed VideoPlayerScreen class

