import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import 'app_logger.dart';
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

/// Result of email registration.
class EmailRegisterResult {
  const EmailRegisterResult({
    required this.success,
    this.requiresVerification = false,
    this.error,
  });

  final bool success;
  /// True when verification email was sent — user must verify before login.
  final bool requiresVerification;
  final String? error;
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
        appLogger.error('AuthService', 'init failed: HTTP ${response.statusCode}');
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

      appLogger.info('AuthService', 'auth init succeeded, token received');
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
            appLogger.error('AuthService', 'auth apply failed: $result');
            yield AuthResult.failed(result);
          } else {
            appLogger.info('AuthService', 'user authenticated: ${authStateNotifier.value.displayName}');
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

  // ── Email / Password ─────────────────────────────────────────────────────

  /// Register a new account with email and password via Cabinet API.
  ///
  /// Returns [EmailRegisterResult] — success flag and whether email
  /// verification is required before the user can log in.
  static Future<EmailRegisterResult> registerWithEmail({
    required String email,
    required String password,
    String? firstName,
  }) async {
    try {
      final body = <String, dynamic>{'email': email, 'password': password};
      if (firstName != null && firstName.isNotEmpty) body['first_name'] = firstName;

      final response = await http
          .post(
            Uri.parse('${AppConfig.backendBaseUrl}/cabinet/auth/email/register/standalone'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final requiresVerification = json['requires_verification'] as bool? ?? true;
        return EmailRegisterResult(success: true, requiresVerification: requiresVerification);
      }

      String detail = 'Ошибка регистрации (${response.statusCode}).';
      try {
        final err = jsonDecode(response.body) as Map<String, dynamic>;
        final d = err['detail'];
        if (d is String && d.isNotEmpty) detail = d;
      } catch (_) {}
      return EmailRegisterResult(success: false, error: detail);
    } on Exception catch (e) {
      return EmailRegisterResult(success: false, error: 'Ошибка соединения: $e');
    }
  }

  /// Login with email and password via Cabinet API.
  ///
  /// On success updates [authStateNotifier] and [RemnawaveService], returns `null`.
  /// On error returns a localised error string.
  /// Special return value `'email_unverified'` means the user has not verified
  /// their email yet.
  static Future<String?> loginWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('${AppConfig.backendBaseUrl}/cabinet/auth/email/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 401) return 'Неверный email или пароль.';
      if (response.statusCode == 403) return 'email_unverified';
      if (response.statusCode == 429) return 'Слишком много попыток. Подождите минуту.';
      if (response.statusCode != 200) return 'Ошибка сервера (${response.statusCode}).';

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = json['access_token'] as String?;
      final userMap = json['user'] as Map<String, dynamic>?;
      if (accessToken == null || userMap == null) return 'Неверный ответ сервера.';

      // Fetch subscription URL with the new JWT
      final subUrl = await _fetchCabinetSubscriptionUrl(accessToken);

      final newState = AuthState(
        isLoggedIn: true,
        telegramId: (userMap['telegram_id'] as num?)?.toInt(),
        firstName: userMap['first_name'] as String?,
        lastName: userMap['last_name'] as String?,
        username: userMap['username'] as String?,
        email: userMap['email'] as String?,
        cabinetAccessToken: accessToken,
        subscriptionUrl: subUrl,
      );

      await saveAuthState(newState);
      if (subUrl != null && subUrl.isNotEmpty) {
        await RemnawaveService.saveSubscriptionUrl(subUrl);
      }
      authStateNotifier.value = newState;

      // Refresh /me — fails gracefully for email-only users (no telegram_id)
      MeService.refresh();

      appLogger.info('AuthService', 'user authenticated via email: ${newState.displayName}');
      return null; // success
    } on Exception catch (e) {
      return 'Ошибка соединения: $e';
    }
  }

  /// Fetch the subscription URL from Cabinet API using a JWT access token.
  static Future<String?> _fetchCabinetSubscriptionUrl(String accessToken) async {
    try {
      final resp = await http
          .get(
            Uri.parse('${AppConfig.backendBaseUrl}/cabinet/subscription'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final sub = body['subscription'] as Map<String, dynamic>?;
      return sub?['subscription_url'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Google OAuth ──────────────────────────────────────────────────────────

  /// Initiates Google OAuth: calls `/mobile/v1/auth/google/init`, gets a
  /// token + the Google authorize URL, then opens the URL in the browser.
  ///
  /// Returns the token string on success, or null if something failed.
  /// After calling this, poll [pollStatus] with the returned token.
  static Future<String?> startGoogleLogin({
    required void Function(String message) onError,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/google/init'),
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        appLogger.error('AuthService', 'google/init failed: HTTP ${response.statusCode}');
        onError('Ошибка сервера (${response.statusCode}). Попробуйте позже.');
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final token = body['token'] as String?;
      final authorizeUrl = body['authorize_url'] as String?;

      if (token == null || authorizeUrl == null) {
        onError('Неверный ответ сервера.');
        return null;
      }

      final uri = Uri.parse(authorizeUrl);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        onError('Не удалось открыть браузер.');
        return null;
      }

      appLogger.info('AuthService', 'google auth init succeeded, token received');
      return token;
    } on Exception catch (e) {
      onError('Ошибка соединения с сервером: $e');
      return null;
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

      appLogger.info('AuthService', 'user logged out');
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
