import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/server_node.dart';

/// Service that fetches the public server catalog from the mobile API.
///
/// Called when the user has not configured a personal subscription URL.
/// The endpoint aggregates Remnawave hosts and returns servers that are
/// visible but not connectable ([ServerNode.link] is `null`,
/// [ServerNode.isDisabled] is `true`).
///
/// Endpoint: `GET {AppConfig.panelBaseUrl}/mobile/v1/servers`
class MobileApiService {
  MobileApiService._();

  static const _serversPath = '/mobile/v1/servers';

  /// The placeholder URL set in [AppConfig.panelBaseUrl] before the developer
  /// configures the real panel URL.  When this value is detected the service
  /// skips the network request.
  static const _unconfiguredBaseUrl = 'https://panel.example.com';

  /// Fetches the public server catalog from the mobile API.
  ///
  /// Returns an empty list on network error or when the endpoint is
  /// unavailable.  Servers in the returned list always have
  /// [ServerNode.link] == `null` and [ServerNode.isDisabled] == `true`
  /// as enforced by the backend, so they serve as a preview catalog only.
  static Future<List<ServerNode>> fetchPublicServers() async {
    final base = AppConfig.panelBaseUrl;
    if (base.isEmpty || base == _unconfiguredBaseUrl) {
      debugPrint('MobileApiService: panelBaseUrl is not configured');
      return [];
    }

    final uri = Uri.tryParse('$base$_serversPath');
    if (uri == null) {
      debugPrint('MobileApiService: invalid panelBaseUrl: $base');
      return [];
    }

    try {
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint(
          'MobileApiService: /mobile/v1/servers returned ${response.statusCode}',
        );
        return [];
      }

      final dynamic decoded = jsonDecode(response.body);

      // Accept both a bare JSON array and a wrapped object such as
      // {"servers": [...]} or {"data": [...]}.
      final List<dynamic> rawList;
      if (decoded is List) {
        rawList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        final inner = decoded['servers'] ?? decoded['data'];
        rawList = inner is List ? inner : [];
      } else {
        rawList = [];
      }

      final nodes = rawList
          .whereType<Map<String, dynamic>>()
          .map(ServerNode.fromJson)
          .toList();

      debugPrint('MobileApiService: loaded ${nodes.length} public servers');
      return nodes;
    } catch (e) {
      debugPrint('MobileApiService: fetchPublicServers error: $e');
      return [];
    }
  }
}
