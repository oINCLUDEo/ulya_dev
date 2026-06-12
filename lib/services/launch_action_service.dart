import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Bridges launcher shortcuts and the Quick Settings tile into the app.
///
/// The platform side stores the `shortcut_action` intent extra
/// ("toggle" | "servers") and hands it out once via `getLaunchAction`.
/// [pending] carries the action until the responsible widget consumes it
/// with [consume].
class LaunchActionService {
  LaunchActionService._();

  static const MethodChannel _channel = MethodChannel('apps.channel');

  /// Action waiting to be handled, or null.
  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  /// Polls the platform side. Call at boot and on app resume (the tile can
  /// fire while the app is alive in the background).
  static Future<void> poll() async {
    try {
      final action = await _channel.invokeMethod<String>('getLaunchAction');
      if (action != null && action.isNotEmpty) {
        appLogger.info('LaunchAction', 'received: $action');
        pending.value = action;
      }
    } catch (e) {
      // iOS / platforms without the channel — shortcuts simply don't exist.
      appLogger.info('LaunchAction', 'poll unavailable: $e');
    }
  }

  /// Returns the pending action if it equals [action] and clears it.
  static bool consume(String action) {
    if (pending.value != action) return false;
    pending.value = null;
    return true;
  }
}
