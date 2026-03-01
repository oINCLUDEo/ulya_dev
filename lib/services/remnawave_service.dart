import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_node.dart';

/// Service that fetches and parses the user's personal subscription URL.
///
/// The subscription URL is a per-user link (given to the user by the
/// Telegram bot after purchase).  It requires **no admin API key** — the
/// short-UUID inside the URL is the user's personal access credential.
///
/// The URL returns VPN configuration lines (vless://, vmess://, trojan://, …),
/// optionally base64-encoded, one config per line.  Each config is parsed into
/// a [ServerNode] that the Servers page can display.
class RemnawaveService {
  static const _prefSubscriptionUrl = 'subscription_url';

  // ── Subscription URL storage ─────────────────────────────────────────────

  static Future<String> getSubscriptionUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefSubscriptionUrl) ?? '';
  }

  static Future<void> saveSubscriptionUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSubscriptionUrl, url.trim());
  }

  // ── Fetch & parse ─────────────────────────────────────────────────────────

  /// Fetches the subscription URL and returns a list of [ServerNode]s.
  ///
  /// Returns an empty list when no subscription URL is configured or on error.
  static Future<List<ServerNode>> fetchNodes() async {
    final subUrl = await getSubscriptionUrl();
    if (subUrl.isEmpty) return [];

    final uri = Uri.tryParse(subUrl);
    if (uri == null) return [];

    try {
      final response = await http
          .get(uri, headers: {'User-Agent': 'v2rayNG/1.8'})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('RemnawaveService: subscription returned ${response.statusCode}');
        return [];
      }

      final lines = _parseSubscriptionBody(response.body);
      final nodes = lines
          .map(_parseConfigLink)
          .whereType<ServerNode>()
          .toList();
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: fetchNodes error: $e');
      return [];
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Parses the raw subscription body into individual config-link strings.
  ///
  /// Remnawave (and most panels) return configs as either:
  ///  - Plain text: one link per line
  ///  - Base64-encoded text: decode first, then one link per line
  static List<String> _parseSubscriptionBody(String body) {
    body = body.trim();
    if (body.isEmpty) return [];

    // Attempt base64 decode first.
    try {
      // Base64 may use standard or URL-safe alphabet; add padding if needed.
      String b64 = body.replaceAll('\n', '').replaceAll('\r', '');
      final padding = b64.length % 4;
      if (padding != 0) b64 += '=' * (4 - padding);
      final decoded = utf8.decode(base64.decode(b64));
      // If the decoded string looks like VPN config links, use it.
      if (decoded.contains('://')) {
        return decoded
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Not base64 — fall through to plain-text parsing.
    }

    return body
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  /// Parses a single VPN config link into a [ServerNode].
  ///
  /// Supported schemes: vless, vmess, trojan, ss, hysteria2, hy2, tuic, wg.
  /// Returns `null` for unrecognised links.
  static ServerNode? _parseConfigLink(String link) {
    try {
      link = link.trim();
      if (link.isEmpty) return null;

      final uri = Uri.parse(link);
      final scheme = uri.scheme.toLowerCase();

      // Only handle known VPN schemes.
      const knownSchemes = {
        'vless', 'vmess', 'trojan', 'ss',
        'hysteria2', 'hy2', 'hysteria', 'tuic', 'wireguard', 'wg',
      };
      if (!knownSchemes.contains(scheme)) return null;

      // Decode name from URL fragment (#ServerName).
      final rawFragment = uri.fragment;
      final name = rawFragment.isNotEmpty
          ? Uri.decodeComponent(rawFragment)
          : uri.host;

      final host = uri.host;
      if (host.isEmpty) return null;

      // Try to infer 2-letter country code from the server name.
      final countryCode = _countryCodeFromName(name);

      return ServerNode(
        uuid: link,
        name: name,
        address: host,
        countryCode: countryCode,
        isConnected: true,  // nodes from an active subscription are considered reachable
        isDisabled: false,
        link: link,
        protocol: scheme,
      );
    } catch (e) {
      debugPrint('RemnawaveService: failed to parse link: $e');
      return null;
    }
  }

  /// Extracts a 2-letter ISO country code from a server name heuristically.
  ///
  /// Handles patterns like "🇷🇺 Russia", "DE-01", "Netherlands" etc.
  static String _countryCodeFromName(String name) {
    // Check for flag emoji (regional indicator symbols U+1F1E6–U+1F1FF).
    final runes = name.runes.toList();
    if (runes.length >= 2) {
      final a = runes[0];
      final b = runes[1];
      if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
        final letter1 = String.fromCharCode(a - 0x1F1E6 + 0x41);
        final letter2 = String.fromCharCode(b - 0x1F1E6 + 0x41);
        return '$letter1$letter2';
      }
    }

    // Common country name → code mapping.
    const map = {
      'russia': 'RU', 'russian': 'RU', 'россия': 'RU',
      'germany': 'DE', 'german': 'DE', 'deutschland': 'DE',
      'netherlands': 'NL', 'dutch': 'NL', 'holland': 'NL',
      'france': 'FR', 'french': 'FR', 'франция': 'FR',
      'united states': 'US', 'usa': 'US', 'us': 'US', 'america': 'US',
      'united kingdom': 'GB', 'uk': 'GB', 'england': 'GB', 'britain': 'GB',
      'canada': 'CA', 'finland': 'FI', 'sweden': 'SE', 'norway': 'NO',
      'switzerland': 'CH', 'austria': 'AT', 'poland': 'PL',
      'turkey': 'TR', 'india': 'IN', 'japan': 'JP', 'singapore': 'SG',
      'australia': 'AU', 'brazil': 'BR', 'ukraine': 'UA', 'latvia': 'LV',
    };

    final lower = name.toLowerCase();
    for (final entry in map.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }

    // 2-letter prefix pattern: "DE-01", "RU_Server", "US01" etc.
    final prefixMatch = RegExp(r'^([A-Z]{2})[-_\s\d]').firstMatch(name.toUpperCase());
    if (prefixMatch != null) return prefixMatch.group(1)!;

    return '';
  }
}

