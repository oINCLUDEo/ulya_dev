import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';

class RemnawaveService {
  static const _prefApiUrl = 'remnawave_api_url';
  static const _prefApiKey = 'remnawave_api_key';

  static Future<String> getApiUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefApiUrl) ?? '';
  }

  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefApiKey) ?? '';
  }

  static Future<void> saveApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefApiUrl, url.trim());
  }

  static Future<void> saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefApiKey, key.trim());
  }

  /// Fetch the list of VPN nodes from the remnawave panel.
  /// Returns an empty list when the API URL is not configured or on errors.
  static Future<List<ServerNode>> fetchNodes() async {
    final baseUrl = await getApiUrl();
    final apiKey = await getApiKey();

    if (baseUrl.isEmpty) return [];

    final cleanBase =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final uri = Uri.parse('$cleanBase/api/nodes');

    try {
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (apiKey.isNotEmpty) 'X-Api-Key': apiKey,
      };
      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final List<dynamic> nodes =
            body['response']?['nodes'] as List<dynamic>? ?? [];
        return nodes
            .map((n) => ServerNode.fromJson(n as Map<String, dynamic>))
            .toList();
      }
      debugPrint('RemnawaveService: fetchNodes returned ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('RemnawaveService: fetchNodes error: $e');
      return [];
    }
  }
}
