import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class GithubVerificationScreen extends StatefulWidget {
  final String verificationUrl;
  final String userCode;

  const GithubVerificationScreen({
    super.key,
    required this.verificationUrl,
    required this.userCode,
  });

  @override
  State<GithubVerificationScreen> createState() => _GithubVerificationScreenState();
}

class _GithubVerificationScreenState extends State<GithubVerificationScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isLoading = false;
            });

            // Check for success URL and close the screen
            if (url.contains('github.com/login/device/success')) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("인증이 완료되었습니다.")),
                );
                Future.delayed(const Duration(seconds: 1), () {
                  if (mounted) Navigator.of(context).pop(true);
                });
              }
            }

            _injectUserCode(url);
          },
          onWebResourceError: (error) {
            debugPrint("WebView Error: ${error.description}");
          },
        ),
      )
      ..setOnConsoleMessage((message) {
        debugPrint("WebView Console: ${message.message}");
      })
      ..loadRequest(Uri.parse(widget.verificationUrl));
  }

  void _injectUserCode(String url) {
    // Auto-fill disabled by user request
    return;
    
    /*
    // Only inject code if we are on the device activation page
    if (!url.contains('/login/device')) return;
    ...
    */
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GitHub 인증"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          // Floating code display (Top Right)
          Positioned(
            top: 10, 
            right: 10,
            child: SafeArea(
              child: Card(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        "인증 코드",
                        style: TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        widget.userCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
