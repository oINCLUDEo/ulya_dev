/// Application-wide configuration constants.
///
/// The developer MUST update [panelBaseUrl] before distributing the app.
/// These values are compiled into the binary — they are NOT user-editable
/// and should never contain admin API keys or other admin secrets.
class AppConfig {
  AppConfig._();

  /// Base URL of the Remnawave panel (without trailing slash).
  ///
  /// Example: `'https://panel.example.com'`
  ///
  /// Set this to your panel URL before building the release APK/IPA.
  static const String panelBaseUrl = 'https://panel.example.com';

  /// Package names excluded from VPN tunnel by default (on first launch).
  static const List<String> defaultBlockedApps = [
    'com.vk.vkvideo',        // VK Video
    'com.vkontakte.android', // VK (старый)
    'ru.mail.mailapp',       // MAX (Mail.ru)
    'ru.rostel',             // Госуслуги (Новая)
    'ru.gosuslugi.mobile',   // Госуслуги

  ];
}
