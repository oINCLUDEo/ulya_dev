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

  /// Telegram OIDC bridge page (a tiny static HTML file) hosted on the SAME
  /// domain that is registered in @BotFather (`/setdomain`) — the trusted
  /// origin for `oauth.telegram.org`. The mobile app opens this page in an
  /// in-app browser; the page runs the Telegram OAuth flow and redirects back
  /// to the app via [telegramAuthCallback] carrying the auth result.
  ///
  /// Deploy `web_bridge/tg-mobile.html` from this repo to that URL.
  static const String telegramBridgeUrl =
      'https://web.ulya.space/tg-mobile.html';

  /// Deep-link the Telegram OIDC bridge redirects to once it has the auth
  /// result. Caught by flutter_web_auth_2 (callbackUrlScheme = [oauthScheme]).
  static const String telegramAuthCallback = 'ulyavpn://oauth/telegram';

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
