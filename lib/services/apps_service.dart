import 'package:flutter/services.dart';

class AppsService {
  static const MethodChannel _channel = MethodChannel('apps.channel');

  static Future<List<Map<String, dynamic>>> getInstalledApps() async {
    final List result = await _channel.invokeMethod('getInstalledApps');
    return result
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<Uint8List?> getAppIcon(String packageName) async {
    final bytes = await _channel.invokeMethod(
      'getAppIcon',
      {"packageName": packageName},
    );

    if (bytes == null) return null;

    return Uint8List.fromList(List<int>.from(bytes));
  }
}