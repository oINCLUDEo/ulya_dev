import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../main.dart' show DS;

/// In-app payment window: loads the checkout [url] in an embedded WebView with
/// our own top bar (title + close) instead of a Chrome Custom Tab, so the user
/// never sees the browser UI and stays inside the app.
///
/// Returns nothing meaningful — the caller starts payment polling once this
/// page is popped (the backend confirms the payment regardless of how the
/// WebView ended).
///
/// Escape hatch: an "open externally" action in the app bar re-opens the URL in
/// the system browser, in case a payment provider's 3-D Secure / anti-fraud
/// step refuses to run inside a WebView.
class PaymentWebViewPage extends StatefulWidget {
  final String url;
  const PaymentWebViewPage({super.key, required this.url});

  @override
  State<PaymentWebViewPage> createState() => _PaymentWebViewPageState();
}

class _PaymentWebViewPageState extends State<PaymentWebViewPage> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(DS.surface0)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        // Keep web navigations inside the WebView; never bounce to Chrome.
        // Non-http schemes (intent://, bank apps) are blocked here — the user
        // can use the "open externally" action if a provider needs them.
        onNavigationRequest: (req) {
          final u = req.url;
          if (u.startsWith('http://') ||
              u.startsWith('https://') ||
              u.startsWith('about:')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
        onWebResourceError: (err) {
          // Only the main-frame failure matters; sub-resource errors are noise.
          if (err.isForMainFrame ?? true) {
            if (mounted) setState(() => _failed = true);
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _openExternally() async {
    try {
      await launchUrl(Uri.parse(widget.url),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DS.surface0,
      appBar: AppBar(
        backgroundColor: DS.surface1,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: DS.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Оплата',
            style: TextStyle(
                color: DS.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Открыть в браузере',
            icon: const Icon(Icons.open_in_new_rounded,
                color: DS.textSecondary, size: 20),
            onPressed: _openExternally,
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress == 0 ? null : _progress / 100,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation(DS.violet),
                ),
              )
            : null,
      ),
      body: _failed ? _errorState() : WebViewWidget(controller: _controller),
    );
  }

  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, color: DS.textMuted, size: 44),
            const SizedBox(height: 14),
            const Text(
              'Не удалось загрузить страницу оплаты',
              textAlign: TextAlign.center,
              style: TextStyle(color: DS.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: DS.violet),
              onPressed: _openExternally,
              child: const Text('Открыть в браузере'),
            ),
          ],
        ),
      ),
    );
  }
}
