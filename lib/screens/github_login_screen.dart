import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/github_service.dart';
import '../widgets/custom_toast.dart';

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
  WebViewController? _webViewController;

  @override
  void initState() {
    super.initState();
    _initiateDeviceFlow();
  }

  @override
  void dispose() {
    _isPolling = false;
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
          _interval = deviceData['interval'] ?? 5;
          _isLoading = false;
          _isPolling = true;
        });
        _initWebView();
        _startPolling();
      }
    } catch (e) {
      if (mounted) {
        CustomToast.show(context, "로그인 초기화 실패: $e", isError: true);
        Navigator.pop(context);
      }
    }
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF1E1E1E))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {},
          onPageStarted: (String url) {},
          onPageFinished: (String url) {},
          onWebResourceError: (WebResourceError error) {},
        ),
      )
      ..loadRequest(Uri.parse(_verificationUri ?? 'https://github.com/login/device'));
    setState(() {});
  }

  Future<void> _startPolling() async {
    while (_isPolling && mounted) {
      await Future.delayed(Duration(seconds: _interval));
      if (!_isPolling || !mounted) break;
      
      try {
        final token = await widget.githubService.pollForToken(_deviceCode!);
        if (token != null) {
          _isPolling = false;
          await widget.githubService.saveToken(token);
          if (mounted) {
            CustomToast.show(context, "GitHub 로그인 성공!");
            Navigator.pop(context, token);
          }
          return;
        }
      } catch (e) {
        if (e.toString().contains('slow_down')) {
          _interval += 5;
        } else if (e.toString().contains('expired_token')) {
          _isPolling = false;
          if (mounted) {
            CustomToast.show(context, "인증 시간이 만료되었습니다. 다시 시도해주세요.", isError: true);
            Navigator.pop(context);
          }
          return;
        } else {
          _isPolling = false;
          if (mounted) {
            CustomToast.show(context, "인증 오류: $e", isError: true);
            Navigator.pop(context);
          }
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
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
          actions: [
            if (_webViewController != null)
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _webViewController?.reload(),
                tooltip: "새로고침",
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 상단: 인증 코드 표시
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      border: Border(
                        bottom: BorderSide(color: Colors.grey[700]!),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "아래 코드를 입력하세요",
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF6D00),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _userCode ?? "ERROR",
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 6,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_isPolling)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.grey[400],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "인증 대기 중...",
                                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  // 하단: WebView로 GitHub 인증 페이지
                  Expanded(
                    child: _webViewController != null
                        ? WebViewWidget(controller: _webViewController!)
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ],
              ),
      ),
    );
  }
}
