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

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    setState(() => _isLoading = true);
    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
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
    setState(() => _loadingImage = true);

    final ssh = Provider.of<SSHService>(context, listen: false);
    try {
      final tempDir = await getTemporaryDirectory();
      final localPath = '${tempDir.path}/${widget.route}_preview.gif';
      final file = File(localPath);

      if (await file.exists()) {
        if (mounted) setState(() => _previewImage = file);
      } else {
        // Check if preview.gif exists on device, if not generate it
        // Fleet Manager path: /data/media/0/realdata/<route>--0/preview.gif
        // But wait, realdata structure is <route> (folder) ? No.
        // Fleet Manager: Paths.log_root() + route + "--0/preview.gif"
        // log_root is /data/media/0/realdata
        // So path is /data/media/0/realdata/<route>--0/preview.gif?
        // Let's check listFiles output.
        // In _loadRoutes, we listed /data/media/0/realdata and got "2023-..."
        // Actually, openpilot structure is /data/media/0/realdata/2023-10-27--12-34-56--0/
        // The folder name INCLUDES the segment number?
        // Let's re-read helpers.py: segment_to_segment_name joins data_dir + segment.
        // listdir_by_creation(Paths.log_root()) returns "2023-10-27--12-34-56--0", "2023-10-27--12-34-56--1" etc.
        // Fleet Manager groups them by route name (removing --N).
        
        // My _loadRoutes logic was: listFiles('/data/media/0/realdata').
        // If the folders are "route--segment", I need to group them.
        // But wait, in my previous code I assumed "driveName" was the folder.
        // Let's check what I did before.
        // "final drives = files.where((f) => f.attr.isDirectory && f.filename.contains('--')).toList()"
        // If the folders are "2023...--0", "2023...--1", then I was listing segments as drives?
        // If so, I need to group them.
        
        // However, standard openpilot structure:
        // /data/media/0/realdata/
        //    2023-10-27--12-34-56--0/
        //    2023-10-27--12-34-56--1/
        
        // Fleet Manager's all_routes() does this grouping.
        // I should do the same.
        
        // But for now, let's assume the route passed here is "2023-10-27--12-34-56".
        // The preview gif should be in "2023-10-27--12-34-56--0/preview.gif".
        
        final remoteDir = '/data/media/0/realdata/${widget.route}--0';
        final remoteGif = '$remoteDir/preview.gif';
        final remoteVideo = '$remoteDir/qcamera.ts';

        // Check if gif exists
        final existsCmd = 'test -f $remoteGif && echo "yes" || echo "no"';
        final exists = (await ssh.executeCommand(existsCmd)).trim() == "yes";

        if (!exists) {
          // Generate GIF
          // ffmpeg -y -i input -ss 5 -vframes 1 output
          // We need to make sure ffmpeg is available or use the one in /usr/bin/ffmpeg or similar.
          // Fleet Manager uses 'ffmpeg'.
          final genCmd = 'ffmpeg -y -i $remoteVideo -ss 5 -vframes 1 $remoteGif';
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
                      child: const Center(
                        child: Icon(Icons.movie, size: 50, color: Colors.grey),
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
          .map((f) => f.filename.split('--').last) // Get segment number
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

  Future<void> _playInBrowser(String segment) async {
    final ssh = Provider.of<SSHService>(context, listen: false);
    final ip = ssh.connectedIp ?? '192.168.0.1';
    
    final url = Uri.parse('http://$ip:8082/footage/${widget.route}?$segment,qcamera');
    
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
                return ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text("Segment $segment"),
                  trailing: const Icon(Icons.open_in_browser),
                  onTap: () => _playInBrowser(segment),
                );
              },
            ),
    );
  }
}


// Removed VideoPlayerScreen class

