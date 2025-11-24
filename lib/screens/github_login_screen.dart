import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/github_service.dart';
import '../widgets/custom_toast.dart';
// import 'github_verification_screen.dart'; // 외부 브라우저 사용으로 제거

class GithubLoginScreen extends StatefulWidget {
  final GitHubService githubService;

  const GithubLoginScreen({super.key, required this.githubService});

  @override
  State<GithubLoginScreen> createState() => _GithubLoginScreenState();
}

class _GithubLoginScreenState extends State<GithubLoginScreen> {
  String? _userCode;
  String? _verificationUri;
  String? _deviceCode;
  int _interval = 5;
  bool _isLoading = true;
  bool _isPolling = false;
  bool _isSuccess = false;
  String? _authToken; // 성공한 토큰 저장용

  @override
  void initState() {
    super.initState();
    _initiateDeviceFlow();
  }

  @override
  void dispose() {
    _isPolling = false; // 화면 종료 시 폴링 중단
    super.dispose();
  }

  Future<void> _initiateDeviceFlow() async {
    try {
      final deviceData = await widget.githubService.initiateDeviceFlow();
      if (mounted) {
        setState(() {
          _userCode = deviceData['user_code'];
          _verificationUri = deviceData['verification_uri'];
          _deviceCode = deviceData['device_code'];
          _interval = deviceData['interval'];
          _isLoading = false;
          _isPolling = true;
        });
        _startPolling();
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, "로그인 초기화 실패: $e", isError: true);
        Navigator.pop(context);
      }
    }
  }

  void _startPolling() async {
    if (_deviceCode == null) return;

    while (_isPolling && mounted) {
      await Future.delayed(Duration(seconds: _interval + 1));
      if (!_isPolling || !mounted) break;

      try {
        final token = await widget.githubService.pollForToken(_deviceCode!);
        if (token != null) {
          _handleSuccess(token);
          break;
        }
      } catch (e) {
        if (e.toString().contains('slow_down')) {
          _interval += 5;
        } else if (e.toString().contains('expired_token')) {
          if (mounted) {
            CustomToast.show(context, "인증 시간이 만료되었습니다.", isError: true);
            Navigator.pop(context);
          }
          break;
        } else if (e.toString().contains('access_denied')) {
          if (mounted) {
            CustomToast.show(context, "인증이 거부되었습니다.", isError: true);
            Navigator.pop(context);
          }
          break;
        }
        // authorization_pending: continue polling
      }
    }
  }

  void _handleSuccess(String token) {
    if (_isSuccess) return;
    _isPolling = false;
    _isSuccess = true;
    _authToken = token; // 토큰 저장

    if (mounted) {
      // 성공 시 토큰을 반환하며 화면 종료
      Navigator.of(context).pop(token);
    }
  }

  void _openVerificationPage() async {
    if (_verificationUri != null) {
      final url = Uri.parse(_verificationUri!);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
        if (mounted) {
          CustomToast.show(context, "브라우저에서 승인 후 앱으로 돌아오세요.");
        }
      } else {
        if (mounted) {
          CustomToast.show(context, "브라우저를 열 수 없습니다.", isError: true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop) {
          _isPolling = false;
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("GitHub 로그인"),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _isPolling = false;
              Navigator.of(context).pop();
            },
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.security, size: 64, color: Colors.blue),
                    const SizedBox(height: 32),
                    const Text(
                      "GitHub 기기 인증",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "1. 아래 코드를 확인하세요.",
                      style: TextStyle(fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[700]!),
                      ),
                      child: Center(
                        child: Text(
                          _userCode ?? "ERROR",
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      "2. 아래 버튼을 눌러 인증 페이지로 이동 후\n코드를 입력하고 승인하세요.",
                      style: TextStyle(fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _openVerificationPage,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text("인증 페이지 열기"),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                    ),
                    const Spacer(),
                    if (_isPolling)
                      const Column(
                        children: [
                          LinearProgressIndicator(),
                          SizedBox(height: 8),
                          Text("인증 대기 중...", style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
