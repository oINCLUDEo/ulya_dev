import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../config/app_config.dart';
import 'app_logger.dart';
import 'auth_state.dart';

/// Centralised HTTP client for Cabinet API (`/cabinet/*`) calls.
///
/// Responsibilities:
///   * attaches the Bearer JWT from [authStateNotifier];
///   * on 401 transparently rotates the token pair via
///     `POST /cabinet/auth/refresh` and retries the original request once;
///   * concurrent 401s share a single refresh round-trip;
///   * routes through the local xray HTTP proxy when the VPN is active so
///     calls reach the backend even when the app is excluded from the tunnel.
///
/// All methods return `null` when no JWT is available or on a network error —
/// the same degrade-gracefully contract the per-service helpers used before.
class CabinetHttp {
  CabinetHttp._();

  static String get _base => AppConfig.backendBaseUrl;

  /// In-flight refresh — concurrent callers await the same future instead of
  /// firing parallel refresh requests (which would revoke each other's
  /// rotated tokens server-side).
  static Future<bool>? _refreshing;

  // ── Public verbs ──────────────────────────────────────────────────────────

  static Future<http.Response?> get(String path,
          {Duration timeout = const Duration(seconds: 15)}) =>
      _send('GET', path, null, timeout);

  static Future<http.Response?> post(String path,
          {Object? body, Duration timeout = const Duration(seconds: 30)}) =>
      _send('POST', path, body, timeout);

  static Future<http.Response?> put(String path,
          {Object? body, Duration timeout = const Duration(seconds: 15)}) =>
      _send('PUT', path, body, timeout);

  static Future<http.Response?> delete(String path,
          {Duration timeout = const Duration(seconds: 15)}) =>
      _send('DELETE', path, null, timeout);

  // ── Internals ─────────────────────────────────────────────────────────────

  static http.Client _makeClient() {
    if (vpnConnectedNotifier.value) {
      return IOClient(
        HttpClient()..findProxy = (uri) => 'PROXY 127.0.0.1:10808',
      );
    }
    return http.Client();
  }

  static Map<String, String>? _headers() {
    final token = authStateNotifier.value.cabinetAccessToken;
    if (token == null || token.isEmpty) return null;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static Future<http.Response?> _send(
      String method, String path, Object? body, Duration timeout) async {
    var headers = _headers();
    if (headers == null) return null;

    var resp = await _exec(method, path, body, headers, timeout);
    if (resp == null || resp.statusCode != 401) return resp;

    // Access token expired — rotate the pair and retry exactly once.
    final refreshed = await _refreshTokens();
    if (!refreshed) return resp;
    headers = _headers();
    if (headers == null) return resp;
    final retry = await _exec(method, path, body, headers, timeout);
    return retry ?? resp;
  }

  static Future<http.Response?> _exec(String method, String path, Object? body,
      Map<String, String> headers, Duration timeout) async {
    final client = _makeClient();
    try {
      final uri = Uri.parse('$_base$path');
      final encoded = body == null
          ? null
          : (body is String ? body : jsonEncode(body));
      switch (method) {
        case 'GET':
          return await client.get(uri, headers: headers).timeout(timeout);
        case 'POST':
          return await client
              .post(uri, headers: headers, body: encoded)
              .timeout(timeout);
        case 'PUT':
          return await client
              .put(uri, headers: headers, body: encoded)
              .timeout(timeout);
        case 'DELETE':
          return await client.delete(uri, headers: headers).timeout(timeout);
        default:
          throw ArgumentError('unsupported method $method');
      }
    } on Exception catch (e) {
      appLogger.error('CabinetHttp', '$method $path failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  // ── Token refresh ─────────────────────────────────────────────────────────

  /// Rotates the access/refresh pair. Returns true when a new access token
  /// has been persisted and published to [authStateNotifier].
  static Future<bool> _refreshTokens() {
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    final future = _doRefresh().whenComplete(() => _refreshing = null);
    _refreshing = future;
    return future;
  }

  static Future<bool> _doRefresh() async {
    final refreshToken = authStateNotifier.value.cabinetRefreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      appLogger.warning('CabinetHttp', 'refresh skipped — no refresh token');
      return false;
    }
    try {
      // Deliberately a bare client: the refresh call itself must not recurse
      // through _send's 401 handling.
      final resp = await http
          .post(
            Uri.parse('$_base/cabinet/auth/refresh'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        // Refresh token revoked or expired — the session is over. Callers
        // will keep getting 401s and degrade to their logged-out fallbacks.
        appLogger.warning(
            'CabinetHttp', 'refresh rejected: HTTP ${resp.statusCode}');
        return false;
      }

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final access = json['access_token'] as String?;
      final newRefresh = json['refresh_token'] as String?;
      if (access == null || access.isEmpty) {
        appLogger.error('CabinetHttp', 'refresh response missing access_token');
        return false;
      }

      final newState = authStateNotifier.value.copyWith(
        cabinetAccessToken: access,
        cabinetRefreshToken: newRefresh ?? refreshToken,
      );
      await saveAuthState(newState);
      authStateNotifier.value = newState;
      appLogger.info('CabinetHttp', 'token pair rotated');
      return true;
    } on Exception catch (e) {
      appLogger.error('CabinetHttp', 'refresh failed: $e');
      return false;
    }
  }
}
