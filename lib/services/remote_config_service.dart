import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'app_logger.dart';

/// Backend-driven configuration — see `GET /mobile/v1/config` on the
/// Bedolaga backend (`app/mobile/routes/config.py`). Admins edit the
/// underlying `MOBILE_*` settings live; the app just polls for the current
/// snapshot on boot, so behaviour changes (forced update, maintenance,
/// default split-tunneling list) don't require an app store release.
class RemoteConfig {
  final int minSupportedBuild;
  final int latestBuild;
  final bool forceUpdate;
  final String? updateUrl;
  final bool maintenanceEnabled;
  final String maintenanceMessage;
  final List<String> blockedAppsDefault;

  const RemoteConfig({
    required this.minSupportedBuild,
    required this.latestBuild,
    required this.forceUpdate,
    this.updateUrl,
    required this.maintenanceEnabled,
    required this.maintenanceMessage,
    required this.blockedAppsDefault,
  });

  factory RemoteConfig.fromJson(Map<String, dynamic> j) => RemoteConfig(
    minSupportedBuild: (j['min_supported_build'] as num?)?.toInt() ?? 1,
    latestBuild: (j['latest_build'] as num?)?.toInt() ?? 1,
    forceUpdate: j['force_update'] as bool? ?? false,
    updateUrl: j['update_url'] as String?,
    maintenanceEnabled: j['maintenance_enabled'] as bool? ?? false,
    maintenanceMessage: j['maintenance_message'] as String? ?? '',
    blockedAppsDefault: (j['blocked_apps_default'] as List<dynamic>? ?? [])
        .whereType<String>()
        .toList(),
  );
}

/// Fetches and caches [RemoteConfig]. Safe to call [load] repeatedly (e.g. on
/// resume) — a failed fetch silently keeps whatever was last cached, so a
/// flaky network never blocks the app on boot.
class RemoteConfigService {
  RemoteConfigService._();

  static const String _cacheKey = 'remote_config_cache_v1';

  /// Null until the first cache read or successful fetch completes.
  static final ValueNotifier<RemoteConfig?> notifier =
      ValueNotifier<RemoteConfig?>(null);

  static String get _platform => Platform.isIOS ? 'ios' : 'android';

  /// Load cached config immediately (if any), then refresh from the backend.
  /// Call once during boot; safe to call again later (e.g. app resume).
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null && notifier.value == null) {
        notifier.value = RemoteConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      appLogger.warning('RemoteConfig', 'cache read failed: $e');
    }

    try {
      final resp = await http
          .get(Uri.parse(
              '${AppConfig.backendBaseUrl}/mobile/v1/config?platform=$_platform'))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        appLogger.warning('RemoteConfig', 'fetch: HTTP ${resp.statusCode}');
        return;
      }
      notifier.value = RemoteConfig.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, resp.body);
      appLogger.info('RemoteConfig', 'loaded: '
          'minBuild=${notifier.value?.minSupportedBuild} '
          'forceUpdate=${notifier.value?.forceUpdate} '
          'maintenance=${notifier.value?.maintenanceEnabled}');
    } catch (e) {
      appLogger.warning('RemoteConfig', 'fetch failed: $e');
    }
  }

  /// Default split-tunneling exclusion list — remote value when available,
  /// falling back to the list compiled into the app ([AppConfig.defaultBlockedApps]).
  static List<String> get blockedAppsDefault {
    final remote = notifier.value?.blockedAppsDefault;
    return (remote != null && remote.isNotEmpty)
        ? remote
        : AppConfig.defaultBlockedApps;
  }

  /// True when the running build is below [RemoteConfig.minSupportedBuild]
  /// and the admin has [RemoteConfig.forceUpdate] enabled.
  static Future<bool> needsForceUpdate() async {
    final cfg = notifier.value;
    if (cfg == null || !cfg.forceUpdate) return false;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      return build > 0 && build < cfg.minSupportedBuild;
    } catch (e) {
      appLogger.warning('RemoteConfig', 'PackageInfo read failed: $e');
      return false;
    }
  }
}
