class CoreInfo {
  final String name;
  final String version;
  final String architecture;
  final String goVersion;
  final String fullString;

  CoreInfo({
    this.name = 'Xray',
    this.version = 'неизвестно',
    this.architecture = '',
    this.goVersion = '',
    this.fullString = '',
  });

  factory CoreInfo.fromString(String versionString) {
    try {
      // Получаем версию
      RegExp versionRegExp = RegExp(r'(\d+\.\d+\.\d+)');
      Match? versionMatch = versionRegExp.firstMatch(versionString);
      String version = versionMatch?.group(1) ?? 'неизвестно';

      // Получаем архитектуру
      RegExp archRegExp = RegExp(r'android/\w+|ios/\w+|linux/\w+|windows/\w+');
      Match? archMatch = archRegExp.firstMatch(versionString);
      String arch = archMatch?.group(0) ?? '';

      // Получаем версию Go
      RegExp goRegExp = RegExp(r'go\d+\.\d+\.\d+');
      Match? goMatch = goRegExp.firstMatch(versionString);
      String goVersion = goMatch?.group(0) ?? '';

      // Получаем имя (Xray)
      String name = 'Xray';
      if (versionString.startsWith('Xray')) {
        name = 'Xray';
      }

      return CoreInfo(
        name: name,
        version: version,
        architecture: arch,
        goVersion: goVersion,
        fullString: versionString,
      );
    } catch (e) {
      return CoreInfo(version: 'ошибка');
    }
  }

  // Дополнительные геттеры для удобства
  String get shortArch {
    if (architecture.isEmpty) return '';
    return architecture.split('/').last; // arm64, x64 и т.д.
  }

  String get goVersionShort {
    if (goVersion.isEmpty) return '';
    return goVersion.replaceFirst('go', 'go '); // "go 1.25.4"
  }

  String get displayText {
    return '$name $version${architecture.isNotEmpty ? ' · $shortArch' : ''}';
  }
}