import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/me_response.dart';
import 'app_logger.dart';
import 'auth_state.dart';
import 'cabinet_http.dart';
import 'notification_service.dart';
import 'remnawave_service.dart';

/// Global notifier for the current user's /me response.
///
/// Updated whenever [MeService.refresh] is called.  Pages subscribe to this
/// so they react immediately when auth state changes.
final ValueNotifier<MeResponse?> meNotifier = ValueNotifier<MeResponse?>(null);

/// Incremented whenever a full refresh (me + Remnawave subscription info) has
/// completed.  Pages that display Remnawave traffic data listen to this and
/// update their local traffic state from [RemnawaveService.lastSubscriptionInfo].
final ValueNotifier<int> globalRefreshNotifier = ValueNotifier<int>(0);

/// Service responsible for calling GET /mobile/v1/me.
///
/// Call [refresh] after login and on app resume when the user is authenticated.
class MeService {
  MeService._();

  static String get _url => '${AppConfig.backendBaseUrl}/mobile/v1/me';
  static const _prefCachedMe = 'cached_me_response';

  static http.Client _makeClient() {
    if (vpnConnectedNotifier.value) {
      return IOClient(
        HttpClient()..findProxy = (uri) => 'PROXY 127.0.0.1:10808',
      );
    }
    return http.Client();
  }

  /// Fetch user/subscription data and update [meNotifier].
  ///
  /// - Telegram users  → GET /mobile/v1/me  (X-Telegram-Id header)
  /// - Email-only users → GET /cabinet/subscription  (Bearer JWT)
  ///
  /// Does nothing when the user is not logged in.
  /// Returns the response on success, or null on failure.
  static Future<MeResponse?> refresh() async {
    final auth = authStateNotifier.value;
    if (!auth.isLoggedIn) return null;

    // Email-only users: use Cabinet API
    if (auth.isEmailAuth && auth.cabinetAccessToken != null) {
      return _refreshFromCabinet(auth);
    }

    if (auth.telegramId == null) return null;
    return _refreshFromMobile(auth);
  }

  // ── Telegram (mobile API) ──────────────────────────────────────────────────

  static Future<MeResponse?> _refreshFromMobile(AuthState auth) async {
    try {
      final client = _makeClient();
      final response = await client
          .get(
        Uri.parse(_url),
        headers: {'X-Telegram-Id': auth.telegramId.toString()},
      )
          .timeout(const Duration(seconds: 15));
      client.close();

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final me = MeResponse.fromJson(body);
        final subUrl = me.subscription?.subscriptionUrl;
        if (subUrl != null && subUrl.isNotEmpty) {
          await RemnawaveService.saveSubscriptionUrl(subUrl);
        }
        meNotifier.value = me;
        await _saveToCache(me);
        appLogger.info('MeService', '/me refreshed — subscription: ${me.hasSubscription}');
        _checkAndPostExpiryWarning(me);
        unawaited(_fetchAndPostNotifications(auth.telegramId!));
        return me;
      }

      appLogger.warning('MeService', '/me returned ${response.statusCode}');
      return null;
    } on Exception catch (e) {
      appLogger.error('MeService', '/me error: $e');
      return null;
    }
  }

  // ── Email (Cabinet API) ────────────────────────────────────────────────────

  static Future<MeResponse?> _refreshFromCabinet(AuthState auth) async {
    try {
      final response = await CabinetHttp.get('/cabinet/subscription');
      if (response == null) {
        appLogger.warning('MeService', 'cabinet /subscription unreachable');
        return null;
      }

      if (response.statusCode != 200) {
        appLogger.warning('MeService', 'cabinet /subscription returned ${response.statusCode}');
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final hasSub = body['has_subscription'] as bool? ?? false;
      final subData = body['subscription'] as Map<String, dynamic>?;

      MeSubscription? sub;
      if (hasSub && subData != null) {
        sub = _parseCabinetSubscription(subData);
        final subUrl = sub.subscriptionUrl;
        if (subUrl != null && subUrl.isNotEmpty) {
          await RemnawaveService.saveSubscriptionUrl(subUrl);
        }
      }

      final me = MeResponse(
        telegramId: auth.telegramId,
        firstName: auth.firstName,
        lastName: auth.lastName,
        username: auth.username,
        hasSubscription: hasSub,
        subscription: sub,
      );

      meNotifier.value = me;
      await _saveToCache(me);
      appLogger.info('MeService', 'cabinet /subscription refreshed — hasSub: $hasSub');
      _checkAndPostExpiryWarning(me);
      return me;
    } on Exception catch (e) {
      appLogger.error('MeService', 'cabinet refresh error: $e');
      return null;
    }
  }

  /// Map a Cabinet `SubscriptionData` JSON object to [MeSubscription].
  static MeSubscription _parseCabinetSubscription(Map<String, dynamic> s) {
    // Cabinet uses end_date (ISO-8601); mobile uses expire_at (Unix seconds).
    int? expireAt;
    final endDateRaw = s['end_date'] as String?;
    if (endDateRaw != null) {
      try {
        expireAt = DateTime.parse(endDateRaw).millisecondsSinceEpoch ~/ 1000;
      } catch (_) {}
    }

    // plan_name may come as tariff_name or plan_name depending on endpoint version
    final planName =
        (s['tariff_name'] as String?) ??
        (s['plan_name']   as String?) ??
        (s['name']        as String?);

    return MeSubscription(
      status:          s['status']            as String?  ?? 'unknown',
      isTrial:         s['is_trial']          as bool?    ?? false,
      expireAt:        expireAt,
      trafficLimitGb:  (s['traffic_limit_gb'] as num?)?.toInt() ?? 0,
      trafficUsedGb:   (s['traffic_used_gb']  as num?)?.toDouble() ?? 0.0,
      subscriptionUrl: s['subscription_url']  as String?,
      deviceLimit:     (s['device_limit']     as num?)?.toInt() ?? 1,
      autopayEnabled:  s['autopay_enabled']   as bool?    ?? false,
      planName:        (planName?.isNotEmpty == true) ? planName : null,
    );
  }

  /// Full refresh: fetch /me AND the Remnawave subscription info (nodes).
  ///
  /// Increments [globalRefreshNotifier] after all data has been updated so
  /// that pages that display Remnawave traffic data can pick up the new values
  /// from [RemnawaveService.lastSubscriptionInfo] with a simple setState call.
  static Future<void> refreshAll() async {
    await refresh();
    final subUrl = await RemnawaveService.getSubscriptionUrl();
    if (subUrl.isNotEmpty) {
      try {
        await RemnawaveService.fetchNodes();
      } catch (_) {}
    }
    globalRefreshNotifier.value++;
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
        'balance_kopeks': me.balanceKopeks,
        'balance_rub': me.balanceRub,
        'balance_currency': me.balanceCurrency,
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
          'autopay_enabled': me.subscription!.autopayEnabled,
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

  // ── Backend notifications ─────────────────────────────────────────────────

  static Future<void> _fetchAndPostNotifications(int telegramId) async {
    try {
      final url = '${AppConfig.backendBaseUrl}/mobile/v1/notifications';
      final client = _makeClient();
      final resp = await client
          .get(Uri.parse(url), headers: {'X-Telegram-Id': telegramId.toString()})
          .timeout(const Duration(seconds: 10));
      client.close();
      if (resp.statusCode != 200) return;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = body['notifications'] as List<dynamic>? ?? [];
      for (final raw in items) {
        try {
          final notif = InAppNotification.fromJson(raw as Map<String, dynamic>);
          notificationService.post(notif);
          appLogger.info('MeService', 'Backend notification posted: ${notif.id}');
        } catch (_) {}
      }
    } on Exception catch (e) {
      debugPrint('MeService: _fetchAndPostNotifications error: $e');
    }
  }

  // ── Subscription expiry warning ──────────────────────────────────────────

  /// Posts a persistent in-app warning when the subscription is expired or
  /// about to expire (within [_expiryWarnDays] days).  Uses a session-scoped
  /// flag so the banner only appears once per session; the user can dismiss it.
  static const int _expiryWarnDays = 3;
  static bool _expiryWarningPosted = false;

  static void _checkAndPostExpiryWarning(MeResponse me) {
    final sub = me.subscription;
    if (sub == null) return;

    if (sub.isExpired) {
      if (!_expiryWarningPosted) {
        _expiryWarningPosted = true;
        notificationService.post(const InAppNotification(
          id: 'sub_expired',
          title: 'Подписка истекла',
          body: 'Подписка истекла — продлите, чтобы продолжить использовать VPN.',
          type: InAppNotifType.persistent,
          severity: InAppNotifSeverity.error,
        ));
      }
      return;
    }

    if (sub.isActive) {
      final expireDate = sub.expireDate;
      if (expireDate == null) return;
      final daysLeft = expireDate.difference(DateTime.now()).inDays;
      if (daysLeft <= _expiryWarnDays && !_expiryWarningPosted) {
        _expiryWarningPosted = true;
        final label = daysLeft <= 0 ? 'менее 1 дня' : '$daysLeft ${_dayWord(daysLeft)}';
        notificationService.post(InAppNotification(
          id: 'sub_expiring_soon',
          title: 'Подписка скоро истекает',
          body: 'Ваша подписка истекает через $label.',
          type: InAppNotifType.persistent,
          severity: InAppNotifSeverity.warning,
        ));
      }
    }
  }

  static String _dayWord(int n) {
    if (n % 100 >= 11 && n % 100 <= 19) return 'дней';
    switch (n % 10) {
      case 1: return 'день';
      case 2:
      case 3:
      case 4: return 'дня';
      default: return 'дней';
    }
  }
}
