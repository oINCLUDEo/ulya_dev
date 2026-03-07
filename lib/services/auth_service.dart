import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import 'auth_state.dart';
import 'me_service.dart';
import 'remnawave_service.dart';

/// Result of an auth initiation or poll.
class AuthResult {
  const AuthResult._({required this.success, this.error, this.state});

  final bool success;
  final String? error;
  final AuthState? state;

  static const AuthResult pending = AuthResult._(success: false);

  factory AuthResult.failed(String message) =>
      AuthResult._(success: false, error: message);

  factory AuthResult.done(AuthState state) =>
      AuthResult._(success: true, state: state);
}

/// Service that handles the Telegram deep-link auth flow:
///
/// 1. Call [startLogin] — calls `/mobile/v1/auth/init`, opens Telegram deep-link.
/// 2. Stream [pollStatus] — polls `/mobile/v1/auth/check/{token}` every
///    [pollInterval] until verified, expired, or cancelled.
/// 3. On success, updates [authStateNotifier] and [RemnawaveService].
class AuthService {
  AuthService._();

  static const Duration pollInterval = Duration(seconds: 2);
  static const Duration pollTimeout = Duration(minutes: 5);

  static String get _baseUrl => '${AppConfig.backendBaseUrl}/mobile/v1/auth';

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Call the init endpoint and open Telegram.
  ///
  /// Returns the token string on success, or null with [onError] called on failure.
  static Future<String?> startLogin({
    required void Function(String message) onError,
  }) async {
    try {
      final response = await http
          .post(
        Uri.parse('$_baseUrl/init'),
        headers: {'Content-Type': 'application/json'},
      )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        onError('Ошибка сервера (${response.statusCode}). Попробуйте позже.');
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final token = body['token'] as String?;
      final deepLink = body['deep_link'] as String?;

      if (token == null || deepLink == null) {
        onError('Неверный ответ сервера.');
        return null;
      }

      final uri = Uri.parse(deepLink);
      final canOpen = await canLaunchUrl(uri);
      if (!canOpen) {
        // Fallback: use https link
        final fallback = Uri.parse(deepLink.replaceFirst('tg://resolve?domain=', 'https://t.me/').replaceAll('&start=', '?start='));
        if (!await launchUrl(fallback, mode: LaunchMode.externalApplication)) {
          onError('Не удалось открыть Telegram. Установите приложение Telegram.');
          return null;
        }
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }

      return token;
    } on Exception catch (e) {
      onError('Ошибка соединения с сервером: $e');
      return null;
    }
  }

  // ── Poll ──────────────────────────────────────────────────────────────────

  /// Poll the check endpoint until verified, expired or [timeout].
  ///
  /// Emits `AuthResult.pending` on each "pending" response.
  /// Completes with `AuthResult.done` on success or `AuthResult.failed` otherwise.
  static Stream<AuthResult> pollStatus(String token) async* {
    final deadline = DateTime.now().add(pollTimeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);

      try {
        final response = await http
            .get(Uri.parse('$_baseUrl/check/$token'))
            .timeout(const Duration(seconds: 8));

        if (response.statusCode != 200) {
          yield AuthResult.failed('Ошибка сервера (${response.statusCode}).');
          return;
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final statusStr = body['status'] as String? ?? 'pending';

        if (statusStr == 'expired') {
          yield AuthResult.failed('Время авторизации истекло. Попробуйте снова.');
          return;
        }

        if (statusStr == 'verified') {
          final authMap = body['auth'] as Map<String, dynamic>?;
          if (authMap == null) {
            yield AuthResult.failed('Неверный ответ сервера.');
            return;
          }

          final result = await _applyAuthResponse(authMap);
          if (result != null) {
            yield AuthResult.failed(result);
          } else {
            yield AuthResult.done(authStateNotifier.value);
          }
          return;
        }

        // status == 'pending'
        yield AuthResult.pending;
      } on Exception catch (e) {
        yield AuthResult.failed('Ошибка соединения: $e');
        return;
      }
    }

    yield AuthResult.failed('Время ожидания истекло. Попробуйте снова.');
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Persist the auth response and update global state.
  ///
  /// Returns `null` on success, or an error string.
  static Future<String?> _applyAuthResponse(Map<String, dynamic> body) async {
    try {
      final userMap = body['user'] as Map<String, dynamic>?;
      if (userMap == null) return 'Неверный формат ответа сервера.';

      final newState = AuthState(
        isLoggedIn: true,
        telegramId: (userMap['telegram_id'] as num?)?.toInt(),
        firstName: userMap['first_name'] as String?,
        lastName: userMap['last_name'] as String?,
        username: userMap['username'] as String?,
        subscriptionUrl: body['subscription_url'] as String?,
      );

      await saveAuthState(newState);

      final subUrl = body['subscription_url'] as String?;
      if (subUrl != null && subUrl.isNotEmpty) {
        await RemnawaveService.saveSubscriptionUrl(subUrl);
      }

      authStateNotifier.value = newState;

      // Eagerly fetch /me so subscription data is ready before pages load.
      MeService.refresh();

      return null; // success
    } on Exception catch (e) {
      return 'Ошибка разбора ответа: $e';
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  /// Clear the authenticated session and subscription URL.
  static Future<void> logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      debugPrint('Logout: Все ключи: ${prefs.getKeys()}');
      for (String key in prefs.getKeys()) {
        debugPrint('$key: ${prefs.get(key)}');
      }

      MeService.clear();
      await Future.wait([
        RemnawaveService.clearCache(),
        clearAuthState(),
      ]);

      debugPrint('Logout: все данные успешно очищены');
      debugPrint('Logout: Ключи после выхода: ${prefs.getKeys()}');
      for (String key in prefs.getKeys()) {
        debugPrint('$key: ${prefs.get(key)}');
      }
    } catch (e, stackTrace) {
      debugPrint('Logout: ошибка при очистке данных: $e\n$stackTrace');
      // Даже при ошибке пробуем очистить всё, что можно
      //await _forceCleanup();
    }
  }
}
