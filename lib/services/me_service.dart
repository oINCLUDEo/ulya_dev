import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
        return me;
      }

      debugPrint('MeService: /me returned ${response.statusCode}');
      return null;
    } on Exception catch (e) {
      debugPrint('MeService: error fetching /me: $e');
      return null;
    }
  }

  /// Clear cached /me data (e.g. on logout).
  static void clear() {
    meNotifier.value = null;
  }
}
