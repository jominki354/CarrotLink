import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';

class UpdateService extends ChangeNotifier {
  bool _isChecking = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String? _downloadedFilePath;
  Map<String, dynamic>? _latestRelease;
  String _currentVersion = "";
  String _statusMessage = "";
  String _channel = "stable"; // stable or dev

  bool get isChecking => _isChecking;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadedFilePath => _downloadedFilePath;
  Map<String, dynamic>? get latestRelease => _latestRelease;
  String get currentVersion => _currentVersion;
  String get statusMessage => _statusMessage;
  String get channel => _channel;

  UpdateService() {
    _loadVersion();
    _loadChannel();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    _currentVersion = "${info.version}+${info.buildNumber}";
    notifyListeners();
  }

  Future<void> _loadChannel() async {
    final prefs = await SharedPreferences.getInstance();
    _channel = prefs.getString('update_channel') ?? "stable";
    notifyListeners();
  }

  Future<void> setChannel(String newChannel) async {
    if (_channel == newChannel) return;
    _channel = newChannel;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('update_channel', _channel);
    notifyListeners();
    // Optionally check for update immediately when channel changes
    // checkForUpdate(); 
  }

  Future<bool> checkForUpdate({bool silent = false}) async {
    if (_isChecking) return false;
    _isChecking = true;
    notifyListeners();

    try {
      // Check "Do not ask" preference if silent check (startup)
      if (silent) {
        final prefs = await SharedPreferences.getInstance();
        final lastIgnored = prefs.getString('ignore_update_until');
        if (lastIgnored != null) {
          final date = DateTime.parse(lastIgnored);
          if (DateTime.now().isBefore(date)) {
            _isChecking = false;
            notifyListeners();
            return false;
          }
        }
      }

      Map<String, dynamic>? releaseData;

      if (_channel == 'stable') {
        final url = Uri.parse('https://api.github.com/repos/jominki354/CarrotLink/releases/latest');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          releaseData = jsonDecode(response.body);
        }
      } else {
        // Dev channel: Get list of releases and pick the first one (latest by date)
        final url = Uri.parse('https://api.github.com/repos/jominki354/CarrotLink/releases?per_page=1');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final List list = jsonDecode(response.body);
          if (list.isNotEmpty) {
            releaseData = list.first;
          }
        }
      }

      if (releaseData != null) {
        final String tagName = releaseData['tag_name'] ?? "";
        // Remove 'v' prefix and build metadata (after +)
        final latestVersion = tagName.replaceAll('v', '').split('+')[0];
        final currentVersionBase = _currentVersion.split('+')[0];

        // Compare versions
        if (_isNewer(latestVersion, currentVersionBase)) {
          _latestRelease = releaseData;
          
          // Check if file already exists
          await _checkExistingFile(releaseData);
          
          _isChecking = false;
          notifyListeners();
          return true;
        }
      }
    } catch (e) {
      debugPrint("Update check failed: $e");
    }

    _isChecking = false;
    notifyListeners();
    return false;
  }

  bool _isNewer(String remote, String current) {
    try {
      List<int> rParts = remote.split('.').map((e) => int.parse(e)).toList();
      List<int> cParts = current.split('.').map((e) => int.parse(e)).toList();

      // Pad with zeros if lengths differ (e.g. 1.0 vs 1.0.0)
      while (rParts.length < 3) rParts.add(0);
      while (cParts.length < 3) cParts.add(0);

      for (int i = 0; i < 3; i++) {
        if (rParts[i] > cParts[i]) return true;
        if (rParts[i] < cParts[i]) return false;
      }
      // Equal
      return false;
    } catch (e) {
      // Fallback to string comparison if parsing fails
      return remote != current;
    }
  }

  Future<void> _checkExistingFile(Map<String, dynamic> releaseData) async {
    final tagName = releaseData['tag_name'];
    final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final filePath = "${dir.path}/update_$tagName.apk";
    final file = File(filePath);
    if (await file.exists()) {
      _downloadedFilePath = filePath;
      _statusMessage = "다운로드 완료";
      _downloadProgress = 1.0;
    } else {
      _downloadedFilePath = null;
      _downloadProgress = 0.0;
    }
  }

  Future<void> downloadUpdate() async {
    if (_latestRelease == null || _isDownloading) return;

    final List assets = _latestRelease!['assets'] ?? [];
    String? downloadUrl;
    for (var asset in assets) {
      if (asset['name'].toString().endsWith('.apk')) {
        downloadUrl = asset['browser_download_url'];
        break;
      }
    }

    if (downloadUrl == null) return;

    _isDownloading = true;
    _statusMessage = "다운로드 중...";
    notifyListeners();

    try {
      final tagName = _latestRelease!['tag_name'];
      final dir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      final filePath = "${dir.path}/update_$tagName.apk";
      final file = File(filePath);

      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await http.Client().send(request);
      final total = response.contentLength ?? 0;
      int received = 0;
      
      final List<int> bytes = [];
      
      response.stream.listen(
        (value) {
          bytes.addAll(value);
          received += value.length;
          if (total > 0) {
            _downloadProgress = received / total;
            notifyListeners();
          }
        },
        onDone: () async {
          await file.writeAsBytes(bytes);
          _downloadedFilePath = filePath;
          _isDownloading = false;
          _statusMessage = "설치 준비 완료";
          _downloadProgress = 1.0;
          notifyListeners();
          installUpdate();
        },
        onError: (e) {
          _isDownloading = false;
          _statusMessage = "다운로드 실패: $e";
          notifyListeners();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _isDownloading = false;
      _statusMessage = "오류: $e";
      notifyListeners();
    }
  }

  Future<void> installUpdate() async {
    if (_downloadedFilePath != null) {
      final result = await OpenFilex.open(_downloadedFilePath!);
      if (result.type != ResultType.done) {
        _statusMessage = "설치 실행 실패: ${result.message}";
        notifyListeners();
      }
    }
  }

  Future<void> ignoreUpdateFor3Days() async {
    final prefs = await SharedPreferences.getInstance();
    final date = DateTime.now().add(const Duration(days: 3));
    await prefs.setString('ignore_update_until', date.toIso8601String());
    _latestRelease = null; // Hide update for now
    notifyListeners();
  }
}
