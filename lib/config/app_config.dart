/// Application-wide configuration constants.
///
/// The developer MUST update [panelBaseUrl] and [backendBaseUrl] before
/// distributing the app.  These values are compiled into the binary — they
/// are NOT user-editable and should never contain admin API keys or other
/// admin secrets.
class AppConfig {
  AppConfig._();

  /// Base URL of the Remnawave panel (without trailing slash).
  ///
  /// Example: `'https://panel.example.com'`
  ///
  /// Set this to your panel URL before building the release APK/IPA.
  static const String panelBaseUrl = 'https://panel.ulya.space';

  /// Base URL of the Bedolaga backend (without trailing slash).
  ///
  /// Used by the mobile app to fetch the public server catalog when the user
  /// has no personal subscription URL yet.
  ///
  /// Example: `'https://bot.example.com'`
  ///
  /// Set this to your Bedolaga backend URL before building the release APK/IPA.
  static const String backendBaseUrl = 'https://api.ulya.space';

  /// Custom URL scheme used as OAuth callback target.
  /// Must match AndroidManifest CallbackActivity + Info.plist + the
  /// authorized redirect URI registered for the OAuth client in the Cabinet
  /// admin panel: `ulyavpn://oauth/callback`.
  static const String oauthScheme   = 'ulyavpn';
  static const String oauthCallback = 'ulyavpn://oauth/callback';

  /// Telegram Native Login (app-to-app OIDC) is handled natively via the
  /// official Telegram Login SDK. Its config — the OIDC Client ID
  /// (8380612257), the App Link redirect URI (app{id}-login.tg.dev/tglogin) and
  /// the scopes — lives in the Android side (MainActivity.kt) and the
  /// AndroidManifest App Link intent-filter, so there is a single source of
  /// truth. The app talks to it over the `ulya/telegram_login` MethodChannel
  /// and posts the returned id_token to `/cabinet/auth/telegram/oidc`.

  /// Sentry DSN for crash reporting. Empty string disables Sentry entirely
  /// (no SDK init, zero network calls) — safe default for local dev builds.
  /// Create a Flutter project at sentry.io (or self-hosted) and paste the
  /// DSN here before building a release.
  static const String sentryDsn = '';

  /// Package names excluded from VPN tunnel by default (on first launch).
  static const List<String> defaultBlockedApps = [
    'com.vk.vkvideo',        // VK Video
    'com.vkontakte.android', // VK (старый)
    'ru.mail.mailapp',       // MAX (Mail.ru)
    'ru.rostel',             // Госуслуги (Новая)
    'ru.gosuslugi.mobile',   // Госуслуги

  ];
}
