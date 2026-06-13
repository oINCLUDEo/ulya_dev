import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
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
        // Cabinet JWT pair issued by the backend alongside the telegram
        // verification — unlocks /cabinet/* (referral etc.) for bot users.
        cabinetAccessToken: body['access_token'] as String?,
        cabinetRefreshToken: body['refresh_token'] as String?,
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
      final refreshToken = json['refresh_token'] as String?;
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
        cabinetRefreshToken: refreshToken,
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

  // ── Google OAuth (Cabinet) ────────────────────────────────────────────────

  /// Sign in with Google via the Cabinet OAuth flow, mobile variant.
  ///
  /// 1. `GET /cabinet/auth/oauth/google/authorize?mobile=1` →
  ///    `{authorize_url, state}` — the URL is the standard Google consent
  ///    page; the backend keeps its own HTTPS callback registered with
  ///    Google Cloud (we don't touch Google Cloud Console for mobile).
  /// 2. Open `authorize_url` in an in-app browser through
  ///    flutter_web_auth_2 — we wait for any redirect into our custom
  ///    scheme.
  /// 3. Google → backend's HTTPS callback (as usual). The backend handles
  ///    the OAuth code exchange itself and, *because we asked for the
  ///    mobile variant*, instead of rendering a success page it issues a
  ///    short-lived JWT and `302 Redirect → ulyavpn://oauth/done?token=…`.
  /// 4. The app catches the deeplink, extracts `token` from the query.
  /// 5. `POST /cabinet/auth/login/auto {token}` → full access/refresh pair
  ///    and the user payload.
  ///
  /// On success persists the new auth state (including [cabinetAccessToken])
  /// and returns `null`. On failure returns a localised error string.
  ///
  /// **Backend contract requirement.** This relies on the cabinet honouring
  /// the `mobile=1` query parameter (or equivalent) on the authorize
  /// endpoint and redirecting to `ulyavpn://oauth/done?token=<short_jwt>`
  /// after the Google round-trip. See [AppConfig.oauthCallback].
  static Future<String?> signInWithGoogle() async {
    try {
      // ── Step 1: ask the cabinet for the Google authorize URL ───────────
      // mobile=1 tells the backend to switch to the deeplink-return mode
      // instead of rendering a web success page. Also pass the expected
      // redirect target so the backend can pin its 302 response.
      final authorizeResp = await http
          .get(
            Uri.parse(
                '${AppConfig.backendBaseUrl}/cabinet/auth/oauth/google/authorize'
                '?mobile=1&redirect_uri=${Uri.encodeQueryComponent(AppConfig.oauthCallback)}'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 12));
      if (authorizeResp.statusCode != 200) {
        appLogger.error('AuthService',
            'google authorize failed: HTTP ${authorizeResp.statusCode} body=${authorizeResp.body}');
        return 'Не удалось начать вход через Google (${authorizeResp.statusCode}).';
      }
      final authorizeJson =
          jsonDecode(authorizeResp.body) as Map<String, dynamic>;
      final authorizeUrl = authorizeJson['authorize_url'] as String?;
      if (authorizeUrl == null || authorizeUrl.isEmpty) {
        return 'Неверный ответ сервера.';
      }

      // ── Step 2: open the browser and wait for the deeplink redirect ────
      final String resultUrl;
      try {
        resultUrl = await FlutterWebAuth2.authenticate(
          url: authorizeUrl,
          callbackUrlScheme: AppConfig.oauthScheme,
        );
      } on PlatformException catch (e) {
        // User cancelled the in-app browser, or no compatible browser.
        appLogger.info('AuthService', 'google auth cancelled or browser unavailable: ${e.message}');
        return 'Вход отменён.';
      }

      // ── Step 3: extract short-lived token from the deeplink ────────────
      // The deeplink format is `ulyavpn://oauth/done?token=…` (or `error=…`).
      // For backwards compatibility we also accept `access_token` in case
      // the backend ever decides to deliver the full token directly.
      final cb = Uri.parse(resultUrl);
      final err = cb.queryParameters['error'];
      if (err != null && err.isNotEmpty) {
        appLogger.error('AuthService', 'google callback error: $err');
        return _humaniseOauthError(err);
      }
      final shortToken = cb.queryParameters['token'];
      final directAccess = cb.queryParameters['access_token'];
      if ((shortToken == null || shortToken.isEmpty) &&
          (directAccess == null || directAccess.isEmpty)) {
        appLogger.error('AuthService', 'google deeplink missing token: $resultUrl');
        return 'Неверный ответ от Google.';
      }

      // ── Step 4: exchange the short token for a full session ────────────
      String? accessToken;
      String? refreshToken;
      Map<String, dynamic>? userMap;
      if (shortToken != null && shortToken.isNotEmpty) {
        final autoResp = await http
            .post(
              Uri.parse(
                  '${AppConfig.backendBaseUrl}/cabinet/auth/login/auto'),
              headers: const {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({'token': shortToken}),
            )
            .timeout(const Duration(seconds: 15));
        if (autoResp.statusCode != 200) {
          appLogger.error('AuthService',
              'login/auto failed: HTTP ${autoResp.statusCode} body=${autoResp.body}');
          return 'Сервер отклонил вход (${autoResp.statusCode}).';
        }
        final tokens = jsonDecode(autoResp.body) as Map<String, dynamic>;
        accessToken = tokens['access_token'] as String?;
        refreshToken = tokens['refresh_token'] as String?;
        userMap = tokens['user'] as Map<String, dynamic>?;
      } else {
        // Backend gave us the full token directly — no /login/auto round-trip.
        accessToken = directAccess;
        userMap = const {};
      }
      if (accessToken == null || accessToken.isEmpty) {
        return 'Неверный ответ сервера.';
      }
      userMap ??= const {};

      // ── Step 5: persist new auth state ─────────────────────────────────
      final subUrl = await _fetchCabinetSubscriptionUrl(accessToken);
      // Note: isEmailAuth is a getter (telegramId == null && email != null).
      // For pure Google sign-ins the backend usually leaves telegram_id null,
      // so the user will be treated as "email-auth" in the rest of the app.
      final newState = AuthState(
        isLoggedIn: true,
        telegramId: (userMap['telegram_id'] as num?)?.toInt(),
        firstName: userMap['username'] as String? ??
            (userMap['email'] as String?)?.split('@').first,
        username: userMap['username'] as String?,
        email: userMap['email'] as String?,
        cabinetAccessToken: accessToken,
        cabinetRefreshToken: refreshToken,
        subscriptionUrl: subUrl,
      );
      await saveAuthState(newState);
      if (subUrl != null && subUrl.isNotEmpty) {
        await RemnawaveService.saveSubscriptionUrl(subUrl);
      }
      authStateNotifier.value = newState;
      MeService.refresh();

      appLogger.info('AuthService', 'user authenticated via google: ${newState.displayName}');
      return null; // success
    } on Exception catch (e) {
      appLogger.error('AuthService', 'google sign-in failed: $e');
      return 'Ошибка соединения: $e';
    }
  }

  // ── Telegram Native Login (app-to-app OIDC) ───────────────────────────────

  /// Platform channel backed by the official Telegram Login SDK
  /// (`org.telegram:login-sdk`) on the Android side (see MainActivity).
  static const MethodChannel _telegramChannel =
      MethodChannel('ulya/telegram_login');

  /// Sentinel returned by [signInWithTelegram] when the user explicitly
  /// dismissed the login — the caller should quietly return to idle.
  static const String telegramCancelled = '__tg_cancelled__';

  /// Sentinel returned by [signInWithTelegram] when login could not be
  /// completed for a reason that warrants falling back to the bot deep-link
  /// (native SDK unavailable, network failure, backend rejection). For a VPN
  /// audience this is the important resilience path.
  static const String telegramFallback = '__tg_fallback__';

  /// Full Telegram login via the official Native Login SDK (app-to-app OIDC) —
  /// the same provider the web cabinet uses, NOT the bot deep-link, and NOT a
  /// browser flow (so it is immune to the Chrome/MIUI App Link handoff issues).
  ///
  /// 1. The native side calls the Telegram SDK, which opens the installed
  ///    Telegram app (or its own browser fallback) and returns an OIDC
  ///    `id_token` (JWT) to us via the App Link → onNewIntent.
  /// 2. We POST `{id_token}` to `/cabinet/auth/telegram/oidc`. The backend
  ///    validates it via JWKS, creates/logs in the user, returns the JWT pair.
  ///
  /// Returns `null` on success, [telegramCancelled] if the user aborted,
  /// [telegramFallback] if the caller should try the deep-link flow, or a
  /// localised error string for a hard failure.
  static Future<String?> signInWithTelegram() async {
    final String? idToken;
    try {
      idToken = await _telegramChannel.invokeMethod<String>('login');
    } on MissingPluginException {
      // Native SDK not wired (e.g. iOS or an old build) → fall back.
      appLogger.info('AuthService', 'telegram native login unavailable');
      return telegramFallback;
    } on PlatformException catch (e) {
      appLogger.error('AuthService', 'telegram native login error: ${e.code} ${e.message}');
      final msg = (e.message ?? '').toLowerCase();
      if (e.code == 'TG_CANCELLED' || msg.contains('cancel')) {
        return telegramCancelled;
      }
      return telegramFallback;
    }

    if (idToken == null || idToken.isEmpty) {
      appLogger.error('AuthService', 'telegram native login: empty id_token');
      return telegramFallback;
    }

    try {
      final resp = await http
          .post(
            Uri.parse('${AppConfig.backendBaseUrl}/cabinet/auth/telegram/oidc'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'id_token': idToken}),
          )
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) {
        appLogger.error('AuthService',
            'telegram oidc failed: HTTP ${resp.statusCode} body=${resp.body}');
        // e.g. OIDC not configured on the backend — fall back rather than
        // dead-end the user.
        return telegramFallback;
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final accessToken = json['access_token'] as String?;
      final refreshToken = json['refresh_token'] as String?;
      final userMap = json['user'] as Map<String, dynamic>?;
      if (accessToken == null || userMap == null) {
        return 'Неверный ответ сервера.';
      }

      final subUrl = await _fetchCabinetSubscriptionUrl(accessToken);
      final newState = AuthState(
        isLoggedIn: true,
        telegramId: (userMap['telegram_id'] as num?)?.toInt(),
        firstName: userMap['first_name'] as String?,
        lastName: userMap['last_name'] as String?,
        username: userMap['username'] as String?,
        email: userMap['email'] as String?,
        cabinetAccessToken: accessToken,
        cabinetRefreshToken: refreshToken,
        subscriptionUrl: subUrl,
      );

      await saveAuthState(newState);
      if (subUrl != null && subUrl.isNotEmpty) {
        await RemnawaveService.saveSubscriptionUrl(subUrl);
      }
      authStateNotifier.value = newState;
      MeService.refresh();

      appLogger.info('AuthService',
          'user authenticated via telegram oidc: ${newState.displayName}');
      return null; // success
    } on Exception catch (e) {
      appLogger.error('AuthService', 'telegram oidc exchange error: $e');
      return telegramFallback;
    }
  }

  /// Maps common OAuth error codes returned in the deeplink to a Russian
  /// message the user can act on.
  static String _humaniseOauthError(String code) {
    switch (code) {
      case 'access_denied':
        return 'Вы отменили вход.';
      case 'redirect_uri_mismatch':
        return 'Не настроен redirect URI на бэке.';
      case 'invalid_state':
        return 'Сессия входа устарела. Попробуйте снова.';
      case 'invalid_token':
        return 'Сервер не принял токен. Попробуйте снова.';
      default:
        return 'Google отказал в доступе ($code).';
    }
  }

  // ── Logout ────────────────────────────────────────────────────────────────

  /// Clear the authenticated session and subscription URL.
  static Future<void> logout() async {
    try {
      MeService.clear();
      await Future.wait([
        RemnawaveService.clearCache(),
        clearAuthState(),
      ]);
      appLogger.info('AuthService', 'user logged out');
    } catch (e, stackTrace) {
      appLogger.error('AuthService', 'logout cleanup failed: $e\n$stackTrace');
    }
  }
}
