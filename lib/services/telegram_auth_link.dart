import 'dart:async';

import 'package:app_links/app_links.dart';

import '../config/app_config.dart';
import 'app_logger.dart';

/// Captures the Telegram Native Login App Link redirect
/// (`https://app{id}-login.tg.dev/tglogin?code=…&state=…`) and hands it to
/// whoever is currently awaiting a Telegram sign-in.
///
/// Telegram returns the OIDC authorization result to an Android App Link rather
/// than a custom scheme, so flutter_web_auth_2 (custom-scheme only) can't catch
/// it. We listen on the platform deep-link stream instead.
class TelegramAuthLink {
  TelegramAuthLink._();

  static final AppLinks _appLinks = AppLinks();
  static Completer<Uri>? _pending;
  static bool _started = false;

  /// Begin listening for incoming links. Call once, early at app startup.
  /// Idempotent. The subscription lives for the whole app lifetime.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _appLinks.uriLinkStream.listen(
      _onUri,
      onError: (Object e) =>
          appLogger.error('TelegramAuthLink', 'uri stream error: $e'),
    );
  }

  static void _onUri(Uri uri) {
    if (uri.host != AppConfig.telegramAuthCallbackHost) return;
    if (!uri.path.startsWith('/tglogin')) return;
    final p = _pending;
    if (p != null && !p.isCompleted) p.complete(uri);
    // No one waiting → stale/cold link, ignore.
  }

  /// Await the next Telegram redirect. Returns the redirect [Uri], or `null`
  /// on timeout (treated by the caller as "use the fallback login").
  static Future<Uri?> awaitRedirect({
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final c = Completer<Uri>();
    _pending = c;
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      appLogger.info('TelegramAuthLink', 'redirect wait timed out');
      return null;
    } finally {
      if (identical(_pending, c)) _pending = null;
    }
  }

  /// Drop any in-flight waiter (e.g. the user backed out manually).
  static void cancel() {
    final p = _pending;
    if (p != null && !p.isCompleted) {
      _pending = null;
    }
  }
}
