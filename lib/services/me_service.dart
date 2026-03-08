import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/me_response.dart';
import 'auth_state.dart';

/// Global notifier for the current user's /me response.
///
/// Updated whenever [MeService.refresh] is called.  Pages subscribe to this
/// so they react immediately when auth state changes.
final ValueNotifier<MeResponse?> meNotifier = ValueNotifier<MeResponse?>(null);

/// Service responsible for calling GET /mobile/v1/me.
///
/// Call [refresh] after login and on app resume when the user is authenticated.
class MeService {
  MeService._();

  static String get _url => '${AppConfig.backendBaseUrl}/mobile/v1/me';
  static const _prefCachedMe = 'cached_me_response';

  /// Fetch the /me endpoint and update [meNotifier].
  ///
  /// Does nothing when the user is not logged in.
  /// Returns the response on success, or null on failure.
  static Future<MeResponse?> refresh() async {
    final auth = authStateNotifier.value;
    if (!auth.isLoggedIn || auth.telegramId == null) return null;

    try {
      final response = await http
          .get(
            Uri.parse(_url),
            headers: {
              'X-Telegram-Id': auth.telegramId.toString(),
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final me = MeResponse.fromJson(body);
        meNotifier.value = me;
        await _saveToCache(me);
        return me;
      }

      debugPrint('MeService: /me returned ${response.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('MeService: error fetching /me: $e');
      return null;
    }
  }

  static Future<void> _saveToCache(MeResponse me) async {
    final prefs = await SharedPreferences.getInstance();

    try {
      final json = {
        'telegram_id': me.telegramId,
        'first_name': me.firstName,
        'last_name': me.lastName,
        'username': me.username,
        'has_subscription': me.hasSubscription,
        'subscription': me.subscription == null
            ? null
            : {
          'status': me.subscription!.status,
          'is_trial': me.subscription!.isTrial,
          'expire_at': me.subscription!.expireAt,
          'traffic_limit_gb': me.subscription!.trafficLimitGb,
          'traffic_used_gb': me.subscription!.trafficUsedGb,
          'subscription_url': me.subscription!.subscriptionUrl,
          'device_limit': me.subscription!.deviceLimit,
        }
      };

      await prefs.setString(_prefCachedMe, jsonEncode(json));

      debugPrint('MeService: saved /me to cache');
    } catch (e) {
      debugPrint('MeService: failed saving cache: $e');
    }
  }

  static Future<MeResponse?> loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_prefCachedMe);
    if (raw == null) return null;

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final me = MeResponse.fromJson(json);

      meNotifier.value = me;

      debugPrint('MeService: loaded /me from cache');

      return me;
    } catch (e) {
      debugPrint('MeService: failed loading cache: $e');
      return null;
    }
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefCachedMe);

    debugPrint('MeService: cache cleared');
  }

  /// Clear cached /me data (e.g. on logout).
  static Future<void> clear() async {
    meNotifier.value = null;
    await clearCache();
  }
}
