import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'apps_service.dart';

class AppsRepository {
  static final AppsRepository instance = AppsRepository._();
  AppsRepository._();

  List<Map<String, dynamic>>? _apps;
  final Map<String, Uint8List?> _icons = {};

  final ValueNotifier<int> iconsVersion = ValueNotifier(0);

  bool _loadingApps = false;
  bool _loadingIcons = false;
  bool _cancelLoading = false;

  List<Map<String, dynamic>>? get apps => _apps;
  Map<String, Uint8List?> get icons => _icons;
  bool get isLoaded => _apps != null;

  /// ===============================
  /// Загрузка списка приложений
  /// ===============================
  Future<void> preload() async {
    if (_apps != null || _loadingApps) return;

    _loadingApps = true;

    final apps = await AppsService.getInstalledApps();

    apps.sort(
          (a, b) =>
          (a['appName'] as String).compareTo(b['appName'] as String),
    );

    _apps = apps;
    _loadingApps = false;
  }

  /// ===============================
  /// Плавная загрузка иконок
  /// ===============================
  Future<void> loadIconsGradually(
      Set<String> priorityPackages,
      ) async {
    if (_apps == null || _loadingIcons) return;

    _loadingIcons = true;
    _cancelLoading = false;

    // Формируем порядок: сначала выбранные
    final ordered = [
      ..._apps!.where(
            (a) => priorityPackages.contains(a['packageName']),
      ),
      ..._apps!.where(
            (a) => !priorityPackages.contains(a['packageName']),
      ),
    ];

    for (final app in ordered) {
      if (_cancelLoading) break;

      final pkg = app['packageName'] as String;

      if (_icons.containsKey(pkg)) continue;

      final rawIcon = await AppsService.getAppIcon(pkg);

      if (rawIcon != null) {
        final resized = await _resizeUltraLight(rawIcon);
        _icons[pkg] = resized;
      } else {
        _icons[pkg] = null;
      }

      // 🔥 уведомляем только слушателей
      iconsVersion.value++;

      // 🔥 микро-пауза чтобы UI не лагал
      await Future.delayed(const Duration(milliseconds: 6));
    }

    _loadingIcons = false;
  }

  /// ===============================
  /// Ресайз (28px)
  /// ===============================
  Future<Uint8List?> _resizeUltraLight(Uint8List data) async {
    try {
      final codec = await ui.instantiateImageCodec(
        data,
        targetWidth: 28,
        targetHeight: 28,
      );

      final frame = await codec.getNextFrame();
      final byteData =
      await frame.image.toByteData(format: ui.ImageByteFormat.png);

      return byteData?.buffer.asUint8List();
    } catch (_) {
      return data;
    }
  }

  /// ===============================
  /// Остановка загрузки
  /// ===============================
  void cancelIconLoading() {
    _cancelLoading = true;
  }
}