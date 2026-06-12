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

    // The platform channel already delivers byte arrays as Uint8List —
    // avoid the old double copy through List<int>.
    if (bytes is Uint8List) return bytes;
    if (bytes is List) return Uint8List.fromList(bytes.cast<int>());
    return null;
  }
}