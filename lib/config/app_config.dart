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
  static const String backendBaseUrl = 'http://192.168.0.103:8081';

  /// Package names excluded from VPN tunnel by default (on first launch).
  static const List<String> defaultBlockedApps = [
    'com.vk.vkvideo',        // VK Video
    'com.vkontakte.android', // VK (старый)
    'ru.mail.mailapp',       // MAX (Mail.ru)
    'ru.rostel',             // Госуслуги (Новая)
    'ru.gosuslugi.mobile',   // Госуслуги

  ];
}
