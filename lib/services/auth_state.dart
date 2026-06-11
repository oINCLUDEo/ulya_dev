import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Immutable snapshot of the current authentication state.
/// Supports both Telegram bot auth and email/password (cabinet) auth.
class AuthState {
  const AuthState({
    this.isLoggedIn = false,
    this.telegramId,
    this.firstName,
    this.lastName,
    this.username,
    this.subscriptionUrl,
    this.email,
    this.cabinetAccessToken,
    this.cabinetRefreshToken,
  });

  /// Whether the user has successfully authenticated.
  final bool isLoggedIn;

  /// Telegram user ID (null for email-only users).
  final int? telegramId;

  final String? firstName;
  final String? lastName;
  final String? username;

  /// The personal subscription URL obtained from the backend after login.
  ///
  /// When non-null the app should behave exactly as if the user had manually
  /// entered a subscription URL in Settings.
  final String? subscriptionUrl;

  /// Email address (set when authenticated via email/password).
  final String? email;

  /// Cabinet JWT access token (set when authenticated via email/password).
  /// Used to call Cabinet API endpoints that require Bearer auth.
  final String? cabinetAccessToken;

  /// Cabinet refresh token — exchanged for a new access/refresh pair via
  /// `POST /cabinet/auth/refresh` when the access token expires.
  final String? cabinetRefreshToken;

  /// Whether this is an email-only account (no Telegram link yet).
  bool get isEmailAuth => telegramId == null && email != null;

  /// Display name used in the UI.
  String get displayName {
    if (firstName != null && firstName!.isNotEmpty) return firstName!;
    if (username != null && username!.isNotEmpty) return '@$username';
    if (email != null && email!.isNotEmpty) return email!;
    return 'Пользователь';
  }

  bool get hasSubscription => subscriptionUrl != null && subscriptionUrl!.isNotEmpty;

  AuthState copyWith({
    bool? isLoggedIn,
    int? telegramId,
    String? firstName,
    String? lastName,
    String? username,
    String? subscriptionUrl,
    String? email,
    String? cabinetAccessToken,
    String? cabinetRefreshToken,
  }) =>
      AuthState(
        isLoggedIn: isLoggedIn ?? this.isLoggedIn,
        telegramId: telegramId ?? this.telegramId,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        username: username ?? this.username,
        subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
        email: email ?? this.email,
        cabinetAccessToken: cabinetAccessToken ?? this.cabinetAccessToken,
        cabinetRefreshToken: cabinetRefreshToken ?? this.cabinetRefreshToken,
      );

  @override
  String toString() =>
      'AuthState(isLoggedIn: $isLoggedIn, telegramId: $telegramId, '
      'email: $email, hasSubscription: $hasSubscription)';
}

// ── Storage keys ──────────────────────────────────────────────────────────────

const _keyIsLoggedIn = 'auth_is_logged_in';
const _keyTelegramId = 'auth_telegram_id';
const _keyFirstName = 'auth_first_name';
const _keyLastName = 'auth_last_name';
const _keyUsername = 'auth_username';
const _keyEmail = 'auth_email';
const _keyCabinetToken = 'auth_cabinet_token';
const _keyCabinetRefreshToken = 'auth_cabinet_refresh_token';

/// Encrypted storage (Android Keystore / iOS Keychain) for the Cabinet JWT.
/// Profile fields stay in SharedPreferences — only the token is a secret.
const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// Global notifier for authentication state.
///
/// All pages subscribe to this notifier so the UI updates automatically
/// after login or logout without requiring an external state management library.
final ValueNotifier<AuthState> authStateNotifier =
    ValueNotifier<AuthState>(const AuthState());

/// Global notifier for VPN connection state.
///
/// Updated by [HomePage] whenever the xray VPN status changes.
/// Used by services (e.g. [SubscriptionApiService], [MeService]) to decide
/// whether to route their HTTP calls through the local xray HTTP proxy.
final ValueNotifier<bool> vpnConnectedNotifier = ValueNotifier<bool>(false);

// ── Persistence helpers ───────────────────────────────────────────────────────

/// Persist [state] to SharedPreferences.
///
/// Note: the subscription URL itself is stored separately by [RemnawaveService]
/// under its own key so that the existing subscription flow is not disrupted.
Future<void> saveAuthState(AuthState state) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_keyIsLoggedIn, state.isLoggedIn);
  _setOrRemove(prefs, _keyTelegramId, state.telegramId, setInt: true);
  _setOrRemoveString(prefs, _keyFirstName, state.firstName);
  _setOrRemoveString(prefs, _keyLastName, state.lastName);
  _setOrRemoveString(prefs, _keyUsername, state.username);
  _setOrRemoveString(prefs, _keyEmail, state.email);

  if (state.cabinetAccessToken != null) {
    await _secureStorage.write(
        key: _keyCabinetToken, value: state.cabinetAccessToken);
  } else {
    await _secureStorage.delete(key: _keyCabinetToken);
  }
  if (state.cabinetRefreshToken != null) {
    await _secureStorage.write(
        key: _keyCabinetRefreshToken, value: state.cabinetRefreshToken);
  } else {
    await _secureStorage.delete(key: _keyCabinetRefreshToken);
  }
  // Make sure no plaintext copy from older app versions survives.
  await prefs.remove(_keyCabinetToken);
}

void _setOrRemove(
  SharedPreferences prefs,
  String key,
  Object? value, {
  bool setInt = false,
}) {
  if (value == null) {
    prefs.remove(key);
  } else if (setInt) {
    prefs.setInt(key, value as int);
  }
}

void _setOrRemoveString(SharedPreferences prefs, String key, String? value) {
  if (value != null) {
    prefs.setString(key, value);
  } else {
    prefs.remove(key);
  }
}

/// Load previously persisted auth state into [authStateNotifier].
Future<void> loadAuthState() async {
  final prefs = await SharedPreferences.getInstance();
  final isLoggedIn = prefs.getBool(_keyIsLoggedIn) ?? false;
  if (!isLoggedIn) return;

  // Migration: older app versions kept the JWT in plain SharedPreferences.
  // Move it to secure storage once and wipe the plaintext copy.
  final legacyToken = prefs.getString(_keyCabinetToken);
  if (legacyToken != null && legacyToken.isNotEmpty) {
    await _secureStorage.write(key: _keyCabinetToken, value: legacyToken);
    await prefs.remove(_keyCabinetToken);
  }

  String? token;
  String? refreshToken;
  try {
    token = await _secureStorage.read(key: _keyCabinetToken);
    refreshToken = await _secureStorage.read(key: _keyCabinetRefreshToken);
  } catch (e) {
    // Keystore can fail after backup-restore onto another device; treat the
    // token as lost — the user will simply have to log in again.
    debugPrint('loadAuthState: secure storage read failed: $e');
  }

  authStateNotifier.value = AuthState(
    isLoggedIn: true,
    telegramId: prefs.getInt(_keyTelegramId),
    firstName: prefs.getString(_keyFirstName),
    lastName: prefs.getString(_keyLastName),
    username: prefs.getString(_keyUsername),
    email: prefs.getString(_keyEmail),
    cabinetAccessToken: token,
    cabinetRefreshToken: refreshToken,
  );
}

/// Clear all auth data (login + subscription URL).
Future<void> clearAuthState() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_keyIsLoggedIn);
  await prefs.remove(_keyTelegramId);
  await prefs.remove(_keyFirstName);
  await prefs.remove(_keyLastName);
  await prefs.remove(_keyUsername);
  await prefs.remove(_keyEmail);
  await prefs.remove(_keyCabinetToken);
  try {
    await _secureStorage.delete(key: _keyCabinetToken);
    await _secureStorage.delete(key: _keyCabinetRefreshToken);
  } catch (e) {
    debugPrint('clearAuthState: secure storage delete failed: $e');
  }
  authStateNotifier.value = const AuthState();
}
