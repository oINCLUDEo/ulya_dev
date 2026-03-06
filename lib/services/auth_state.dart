import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Immutable snapshot of the current Telegram authentication state.
class AuthState {
  const AuthState({
    this.isLoggedIn = false,
    this.telegramId,
    this.firstName,
    this.lastName,
    this.username,
    this.subscriptionUrl,
  });

  /// Whether the user has successfully authenticated via Telegram.
  final bool isLoggedIn;

  /// Telegram user ID (null if not logged in).
  final int? telegramId;

  final String? firstName;
  final String? lastName;
  final String? username;

  /// The personal subscription URL obtained from the backend after login.
  ///
  /// When non-null the app should behave exactly as if the user had manually
  /// entered a subscription URL in Settings.
  final String? subscriptionUrl;

  /// Display name used in the UI.
  String get displayName {
    if (firstName != null && firstName!.isNotEmpty) return firstName!;
    if (username != null && username!.isNotEmpty) return '@$username';
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
  }) =>
      AuthState(
        isLoggedIn: isLoggedIn ?? this.isLoggedIn,
        telegramId: telegramId ?? this.telegramId,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        username: username ?? this.username,
        subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      );

  @override
  String toString() =>
      'AuthState(isLoggedIn: $isLoggedIn, telegramId: $telegramId, '
      'username: $username, hasSubscription: $hasSubscription)';
}

// ── Storage keys ──────────────────────────────────────────────────────────────

const _keyIsLoggedIn = 'auth_is_logged_in';
const _keyTelegramId = 'auth_telegram_id';
const _keyFirstName = 'auth_first_name';
const _keyLastName = 'auth_last_name';
const _keyUsername = 'auth_username';

/// Global notifier for authentication state.
///
/// All pages subscribe to this notifier so the UI updates automatically
/// after login or logout without requiring an external state management library.
final ValueNotifier<AuthState> authStateNotifier =
    ValueNotifier<AuthState>(const AuthState());

// ── Persistence helpers ───────────────────────────────────────────────────────

/// Persist [state] to SharedPreferences.
///
/// Note: the subscription URL itself is stored separately by [RemnawaveService]
/// under its own key so that the existing subscription flow is not disrupted.
Future<void> saveAuthState(AuthState state) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_keyIsLoggedIn, state.isLoggedIn);
  if (state.telegramId != null) {
    await prefs.setInt(_keyTelegramId, state.telegramId!);
  } else {
    await prefs.remove(_keyTelegramId);
  }
  if (state.firstName != null) {
    await prefs.setString(_keyFirstName, state.firstName!);
  } else {
    await prefs.remove(_keyFirstName);
  }
  if (state.lastName != null) {
    await prefs.setString(_keyLastName, state.lastName!);
  } else {
    await prefs.remove(_keyLastName);
  }
  if (state.username != null) {
    await prefs.setString(_keyUsername, state.username!);
  } else {
    await prefs.remove(_keyUsername);
  }
}

/// Load previously persisted auth state into [authStateNotifier].
Future<void> loadAuthState() async {
  final prefs = await SharedPreferences.getInstance();
  final isLoggedIn = prefs.getBool(_keyIsLoggedIn) ?? false;
  if (!isLoggedIn) return;

  authStateNotifier.value = AuthState(
    isLoggedIn: true,
    telegramId: prefs.getInt(_keyTelegramId),
    firstName: prefs.getString(_keyFirstName),
    lastName: prefs.getString(_keyLastName),
    username: prefs.getString(_keyUsername),
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
  authStateNotifier.value = const AuthState();
}
