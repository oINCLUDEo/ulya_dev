import 'dart:async';
import 'package:flutter/foundation.dart';
import 'apps_service.dart';

/// Caches the installed-apps list and their icons for the split-tunneling
/// picker.
///
/// Performance contract:
///  * the platform side renders icons at 64px and compresses them OFF the
///    Android main thread, so bytes arriving here are final — no decoding,
///    resizing or re-encoding happens in Dart;
///  * [iconsVersion] ticks are BATCHED (count + time based) so the listening
///    list rebuilds a few times per second instead of once per icon.
class AppsRepository {
  static final AppsRepository instance = AppsRepository._();
  AppsRepository._();

  List<Map<String, dynamic>>? _apps;
  final Map<String, Uint8List?> _icons = {};

  final ValueNotifier<int> iconsVersion = ValueNotifier(0);

  bool _loadingApps = false;
  bool _loadingIcons = false;
  bool _cancelLoading = false;

  List<Map<String, dynamic>>? get apps => _apps;
  Map<String, Uint8List?> get icons => _icons;
  bool get isLoaded => _apps != null;

  /// Notify listeners after this many freshly loaded icons…
  static const int _notifyEvery = 12;

  /// …or after this much time since the last notification, whichever first.
  static const Duration _notifyInterval = Duration(milliseconds: 200);

  // ── App list ──────────────────────────────────────────────────────────────

  Future<void> preload() async {
    if (_apps != null || _loadingApps) return;

    _loadingApps = true;
    try {
      final apps = await AppsService.getInstalledApps();
      apps.sort(
          (a, b) => (a['appName'] as String).compareTo(b['appName'] as String));
      _apps = apps;
    } finally {
      _loadingApps = false;
    }
  }

  // ── Icons ─────────────────────────────────────────────────────────────────

  /// Loads missing icons, selected apps first. Safe to call repeatedly.
  Future<void> loadIconsGradually(Set<String> priorityPackages) async {
    if (_apps == null || _loadingIcons) return;

    _loadingIcons = true;
    _cancelLoading = false;

    // Selected apps first — they're pinned at the top of the picker.
    final ordered = [
      ..._apps!.where((a) => priorityPackages.contains(a['packageName'])),
      ..._apps!.where((a) => !priorityPackages.contains(a['packageName'])),
    ];

    var pendingNotify = 0;
    final sinceNotify = Stopwatch()..start();

    void flushNotify() {
      if (pendingNotify == 0) return;
      pendingNotify = 0;
      sinceNotify.reset();
      iconsVersion.value++;
    }

    for (final app in ordered) {
      if (_cancelLoading) break;

      final pkg = app['packageName'] as String;
      if (_icons.containsKey(pkg)) continue;

      _icons[pkg] = await AppsService.getAppIcon(pkg);
      pendingNotify++;

      if (pendingNotify >= _notifyEvery || sinceNotify > _notifyInterval) {
        flushNotify();
      }
    }

    flushNotify();
    _loadingIcons = false;
  }

  void cancelIconLoading() {
    _cancelLoading = true;
  }
}

extension on Stopwatch {
  bool operator >(Duration d) => elapsed > d;
}
