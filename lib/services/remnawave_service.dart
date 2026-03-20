import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/server_node.dart';
import '../models/subscription_info.dart';
// meNotifier is used to sync subscription URL from live /me data
import '../services/auth_state.dart';
import 'me_service.dart';

/// Service that fetches and parses the user's personal subscription URL.
///
/// The subscription URL is a per-user link (given to the user by the
/// Telegram bot after purchase).  It requires **no admin API key** — the
/// short-UUID inside the URL is the user's personal access credential.
///
/// The URL returns VPN configuration lines (vless://, vmess://, trojan://, …),
/// optionally base64-encoded, one config per line.  Each config is parsed into
/// a [ServerNode] that the Servers page can display.
///
/// The subscription server identifies devices via two required headers:
///   `User-Agent: Happ/1.5.1/Android`
///   `X-HWID: <stable-device-id>`
class RemnawaveService {
  static const _prefSubscriptionUrl = 'subscription_url';
  static const _prefHwid = 'device_hwid';
  static const _prefCachedNodes = 'cached_nodes';
  static const _prefCachedSubscriptionInfo = 'cached_subscription_info';
  static const _prefSelectedNodeUUID = 'selected_node_uuid';

  // ── Cached subscription info ──────────────────────────────────────────────

  static SubscriptionInfo? _lastSubscriptionInfo;
  static bool _lastFetchWasFromCache = false;

  /// The subscription quota/expiry info from the most recent [fetchNodes] call.
  static SubscriptionInfo? get lastSubscriptionInfo => _lastSubscriptionInfo;

  /// Whether the most recent [fetchNodes] call returned cached data.
  static bool get lastFetchWasFromCache => _lastFetchWasFromCache;

  // ── Subscription URL storage ─────────────────────────────────────────────

  static Future<String> getSubscriptionUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefSubscriptionUrl) ?? '';
  }

  static Future<void> saveSubscriptionUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSubscriptionUrl, url.trim());
  }

  /// Returns the subscription URL, preferring the live value from [meNotifier]
  /// over the SharedPreferences cache.
  ///
  /// This ensures the URL is always current even after [clearCache] was called
  /// while the user remained logged in.
  static Future<String> _resolveSubscriptionUrl() async {
    // 1. Try live value from /me response (in-memory, always fresh)
    final liveUrl = meNotifier.value?.subscription?.subscriptionUrl ?? '';
    if (liveUrl.isNotEmpty) {
      // Persist so future cold-starts work without a /me round-trip
      await saveSubscriptionUrl(liveUrl);
      return liveUrl;
    }
    // 2. Fall back to whatever is stored in SharedPreferences
    return getSubscriptionUrl();
  }

  /// Clears only derived/cached data.  Intentionally preserves
  /// [_prefSubscriptionUrl] and [_prefHwid] — these are user credentials
  /// that should survive cache invalidation.
  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    // NOTE: _prefSubscriptionUrl is intentionally NOT removed here.
    // Removing it while the user is logged in causes fetchNodes() to return []
    // because meNotifier may not be populated yet on the next cold start.
    await prefs.remove(_prefCachedNodes);
    await prefs.remove(_prefCachedSubscriptionInfo);
    await prefs.remove(_prefSelectedNodeUUID);
    _lastSubscriptionInfo = null;
    _lastFetchWasFromCache = false;
  }

  // ── Device HWID ───────────────────────────────────────────────────────────

  static Future<String> getOrCreateHwid() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_prefHwid);
    if (existing != null && existing.isNotEmpty) return existing;
    final hwid = _generateUuid();
    await prefs.setString(_prefHwid, hwid);
    return hwid;
  }

  static String _generateUuid() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    String h(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${bytes.sublist(0, 4).map(h).join()}'
        '-${bytes.sublist(4, 6).map(h).join()}'
        '-${bytes.sublist(6, 8).map(h).join()}'
        '-${bytes.sublist(8, 10).map(h).join()}'
        '-${bytes.sublist(10, 16).map(h).join()}';
  }

  static final Random _rng = Random.secure();

  static Future<Map<String, String>> _getDeviceHeaders() async {
    final deviceInfo = DeviceInfoPlugin();
    final hwid = await getOrCreateHwid();
    String osVersion = '';
    String deviceModel = '';
    String platform = '';
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        osVersion = androidInfo.version.release;
        deviceModel = androidInfo.model;
        platform = 'Android';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        osVersion = iosInfo.systemVersion;
        deviceModel = iosInfo.model;
        platform = 'iOS';
      }
    } catch (e) {
      debugPrint('RemnawaveService: failed to get device info: $e');
    }
    return {
      'User-Agent': 'Happ/1.5.1/Ulya/1.1.0',
      'X-HWID': hwid,
      'X-Ver-OS': osVersion,
      'X-Device-OS': platform,
      'X-Device-Model': deviceModel,
    };
  }

  // ── Fetch & parse ─────────────────────────────────────────────────────────

  /// Fetches the subscription URL and returns a list of [ServerNode]s.
  ///
  /// Uses [_resolveSubscriptionUrl] to always prefer the live URL from
  /// [meNotifier] over the cached value — this fixes the case where
  /// [clearCache] was called while the user remained logged in.
  static Future<List<ServerNode>> fetchNodes() async {
    // KEY FIX: use _resolveSubscriptionUrl() instead of getSubscriptionUrl()
    // so that a logged-in user with a cleared cache still gets their servers.
    final subUrl = await _resolveSubscriptionUrl();
    if (subUrl.isEmpty) return [];

    final uri = Uri.tryParse(subUrl);
    if (uri == null) return [];

    try {
      final headers = await _getDeviceHeaders();
      final response = await http.get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('RemnawaveService: subscription returned ${response.statusCode}');
        return await _loadFromCache();
      }

      _lastSubscriptionInfo = _parseSubscriptionInfo(response.headers);
      final lines = _parseSubscriptionBody(response.body);
      final nodes = lines
          .map(_parseConfigLink)
          .whereType<ServerNode>()
          .toList();
      debugPrint('RemnawaveService: loaded ${nodes.length} nodes');
      await _saveToCache(nodes, _lastSubscriptionInfo);
      _lastFetchWasFromCache = false;
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: fetchNodes error: $e');
      return await _loadFromCache();
    }
  }

  // ── Public catalog (no subscription required) ─────────────────────────────

  static Future<List<ServerNode>> fetchPublicServers() async {
    final url = '${AppConfig.backendBaseUrl}/mobile/v1/servers';
    final uri = Uri.tryParse(url);
    if (uri == null) return [];
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        debugPrint('RemnawaveService: public servers returned ${response.statusCode}');
        return [];
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final list = body['servers'] as List<dynamic>? ?? [];
      final nodes = list.map((e) {
        final serverJson = Map<String, dynamic>.from(e as Map<String, dynamic>);
        final rawName = serverJson['name']?.toString() ?? '';
        if ((serverJson['countryCode'] == null || serverJson['countryCode'].toString().isEmpty) &&
            rawName.isNotEmpty) {
          final code = _countryCodeFromName(rawName);
          if (code.isNotEmpty) serverJson['countryCode'] = code;
        }
        serverJson['name'] = _cleanServerName(rawName);
        return ServerNode.fromJson(serverJson);
      }).toList();
      debugPrint('RemnawaveService: loaded ${nodes.length} public servers');
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: fetchPublicServers error: $e');
      return [];
    }
  }

  static String _cleanServerName(String name) {
    if (name.isEmpty) return name;
    final runes = name.runes.toList();
    if (runes.length >= 2) {
      final a = runes[0];
      final b = runes[1];
      if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
        int startIndex = 2;
        while (startIndex < runes.length &&
            (runes[startIndex] == 0x20 || runes[startIndex] == 0x200B)) {
          startIndex++;
        }
        if (startIndex < runes.length) {
          return String.fromCharCodes(runes.sublist(startIndex));
        }
      }
    }
    return name;
  }

  // ── Cache helpers ─────────────────────────────────────────────────────────

  static Future<void> _saveToCache(
      List<ServerNode> nodes, SubscriptionInfo? info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefCachedNodes,
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
    if (info != null) {
      await prefs.setString(
        _prefCachedSubscriptionInfo,
        jsonEncode(info.toJson()),
      );
    }
  }

  static Future<List<ServerNode>> _loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedInfoRaw = prefs.getString(_prefCachedSubscriptionInfo);
    if (cachedInfoRaw != null) {
      try {
        _lastSubscriptionInfo = SubscriptionInfo.fromJson(
          jsonDecode(cachedInfoRaw) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    final cachedNodesRaw = prefs.getString(_prefCachedNodes);
    if (cachedNodesRaw == null) return [];
    try {
      final list = jsonDecode(cachedNodesRaw) as List<dynamic>;
      final nodes = list
          .map((e) => ServerNode.fromJson(e as Map<String, dynamic>))
          .toList();
      debugPrint('RemnawaveService: loaded ${nodes.length} nodes from cache');
      _lastFetchWasFromCache = true;
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: failed to load cache: $e');
      return [];
    }
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  static List<String> _parseSubscriptionBody(String body) {
    body = body.trim();
    if (body.isEmpty) return [];
    try {
      String b64 = body.replaceAll('\n', '').replaceAll('\r', '');
      final padding = b64.length % 4;
      if (padding != 0) b64 += '=' * (4 - padding);
      final decoded = utf8.decode(base64.decode(b64));
      if (decoded.contains('://')) {
        debugPrint('RemnawaveService: parsed as base64 (${decoded.split('\n').length} lines)');
        return decoded
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    debugPrint('RemnawaveService: parsed as plain text');
    return body
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  static SubscriptionInfo? _parseSubscriptionInfo(Map<String, String> headers) {
    final raw = headers['subscription-userinfo'] ??
        headers['x-subscription-userinfo'];
    if (raw == null || raw.isEmpty) return null;
    final values = <String, int>{};
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final val = int.tryParse(part.substring(eq + 1).trim());
      if (val != null) values[key] = val;
    }
    final upload = values['upload'] ?? 0;
    final download = values['download'] ?? 0;
    final total = values['total'] ?? 0;
    final expireEpoch = values['expire'];
    return SubscriptionInfo(
      uploadBytes: upload,
      downloadBytes: download,
      totalBytes: total,
      expireDate: expireEpoch != null && expireEpoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(expireEpoch * 1000)
          : null,
    );
  }

  static ({String name, String? description}) _parseFragment(
      String fragment, String fallbackHost) {
    if (fragment.isEmpty) return (name: fallbackHost, description: null);
    final parts = fragment.split('?');
    final rawName = parts.first.trim();
    final name = Uri.decodeComponent(rawName);
    String? description;
    if (parts.length > 1) {
      final queryPart = parts.sublist(1).join('?');
      try {
        final params = Uri.splitQueryString(queryPart);
        final encoded = params['serverDescription'];
        if (encoded != null && encoded.isNotEmpty) {
          description = utf8.decode(base64.decode(encoded));
        }
      } catch (_) {}
    }
    return (name: name, description: description);
  }

  static ServerNode? _parseConfigLink(String link) {
    try {
      link = link.trim();
      if (link.isEmpty) return null;
      final uri = Uri.parse(link);
      final scheme = uri.scheme.toLowerCase();
      const knownSchemes = {
        'vless', 'vmess', 'trojan', 'ss',
        'hysteria2', 'hy2', 'hysteria',
        'tuic', 'wireguard', 'wg',
      };
      if (!knownSchemes.contains(scheme)) return null;
      final host = uri.host;
      if (host.isEmpty) return null;
      final parsed = _parseFragment(uri.fragment, host);
      final rawName = parsed.name;
      final cleanName = _cleanServerName(rawName);
      final description = parsed.description;
      final countryCode = _countryCodeFromName(rawName);
      return ServerNode(
        uuid: link,
        name: cleanName,
        address: host,
        countryCode: countryCode,
        isConnected: true,
        isDisabled: false,
        link: link,
        protocol: scheme,
        description: description,
      );
    } catch (e) {
      debugPrint('RemnawaveService: failed to parse link: $e');
      return null;
    }
  }

  static String _countryCodeFromName(String name) {
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
    final prefixMatch = RegExp(r'^([A-Z]{2})[-_\s\d]').firstMatch(name.toUpperCase());
    if (prefixMatch != null) return prefixMatch.group(1)!;
    return '';
  }
}