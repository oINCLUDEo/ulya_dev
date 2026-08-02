import 'package:flutter/services.dart';
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';

import '../models/server_node.dart';
import 'app_logger.dart';

/// Keeps the Quick Settings tile's native side supplied with everything it
/// needs to connect/disconnect the *currently selected* server directly,
/// without opening the app to the foreground.
///
/// The tile only ever acts on whatever was last pushed here — it falls back
/// to opening the app (today's behaviour) when nothing usable is cached or
/// VPN permission hasn't been granted yet (that one dialog can only be shown
/// from a visible Activity, so there's no way around it on first connect).
class NativeVpnBridge {
  NativeVpnBridge._();

  static const MethodChannel _channel = MethodChannel('apps.channel');

  /// Pushes the resolved xray config for [node] to the native side.
  /// Clears the cached config when there's nothing connectable (no node,
  /// disabled, or no link) so the tile correctly falls back to opening the
  /// app instead of trying to connect to nothing.
  static Future<void> syncSelectedNode(
    ServerNode? node, {
    List<String> blockedApps = const [],
  }) async {
    if (node == null || node.isDisabled || node.link == null) {
      await _clear();
      return;
    }

    final rawLink = node.link!.trim();
    final String config;
    try {
      config = rawLink.startsWith('{')
          ? rawLink
          : FlutterV2ray.parseFromURL(rawLink).getFullConfiguration();
    } catch (e) {
      appLogger.info('NativeVpnBridge', 'config resolve failed: $e');
      await _clear();
      return;
    }

    try {
      await _channel.invokeMethod('setVpnConfig', {
        'remark': node.name,
        'config': config,
        'blockedApps': blockedApps,
      });
    } catch (e) {
      // iOS / platforms without the channel — no QS tile there anyway.
      appLogger.info('NativeVpnBridge', 'setVpnConfig unavailable: $e');
    }
  }

  static Future<void> _clear() async {
    try {
      await _channel.invokeMethod('clearVpnConfig');
    } catch (_) {}
  }
}
