import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Listens for default-network changes (Wi-Fi ↔ LTE switches) reported by the
/// platform side (EventChannel `ulya/network_events`, see MainActivity.kt).
///
/// Consumers subscribe to [changeTick] — it increments on every network
/// switch, debounced so a flap (lost + available within a second) produces a
/// single notification after the new network has settled.
///
/// On platforms without the native channel (e.g. iOS until the tunnel work
/// lands) [start] fails silently and the tick simply never fires — callers
/// keep their existing resume/heartbeat refresh paths.
class NetworkMonitor {
  NetworkMonitor._();

  static const EventChannel _channel = EventChannel('ulya/network_events');

  /// Increments once per (debounced) network change.
  static final ValueNotifier<int> changeTick = ValueNotifier<int>(0);

  static StreamSubscription<dynamic>? _sub;
  static Timer? _debounce;

  /// Idempotent. Call once during app boot.
  static void start() {
    if (_sub != null) return;
    try {
      _sub = _channel.receiveBroadcastStream().listen((event) {
        appLogger.info('NetworkMonitor', 'network event: $event');
        // Let the new network settle (DHCP/route setup) before consumers
        // start probing through it, and collapse lost→available flaps.
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 800), () {
          changeTick.value++;
        });
      }, onError: (Object e) {
        appLogger.warning('NetworkMonitor', 'stream error: $e');
      });
    } catch (e) {
      appLogger.warning('NetworkMonitor', 'unavailable on this platform: $e');
    }
  }
}
