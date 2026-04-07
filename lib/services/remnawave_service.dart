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
import '../models/vless_server.dart';

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
  static const _prefSubscriptionUrl        = 'subscription_url';
  static const _prefHwid                   = 'device_hwid';
  static const _prefCachedNodes            = 'cached_nodes';
  static const _prefCachedSubscriptionInfo = 'cached_subscription_info';
  static const _prefSelectedNodeUUID       = 'selected_node_uuid';

  /// SOCKS5 inbound injected into every mobile Xray config.
  ///
  /// Sniffing is intentionally DISABLED to match [FlutterV2RayURL.getFullConfiguration].
  /// With sniffing enabled, xray resolves every sniffer-extracted hostname via its
  /// internal DNS before routing.  When includeSelfInVpn=true those DNS packets also
  /// traverse the TUN → xray re-entry path, adding round-trip latency per connection.
  static const _socksInbound = {
    'tag':      'in_proxy',
    'port':     10807,
    'protocol': 'socks',
    'listen':   '127.0.0.1',
    'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
    'sniffing': {'enabled': false},
  };

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

  /// Clears cached nodes, subscription info and selection while keeping
  /// user-specific data like subscription URL and HWID.
  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefSubscriptionUrl);
    await prefs.remove(_prefCachedNodes);
    await prefs.remove(_prefCachedSubscriptionInfo);
    await prefs.remove(_prefSelectedNodeUUID);
    _lastSubscriptionInfo = null;
    _lastFetchWasFromCache = false;
  }

  // ── Device HWID ───────────────────────────────────────────────────────────

  /// Returns the stable hardware ID for this device installation.
  ///
  /// On first call a random UUID-v4-like string is generated and persisted in
  /// SharedPreferences.  Subsequent calls return the same value so the
  /// subscription server sees a consistent device identity.
  static Future<String> getOrCreateHwid() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_prefHwid);
    if (existing != null && existing.isNotEmpty) return existing;

    final hwid = _generateUuid();
    await prefs.setString(_prefHwid, hwid);
    return hwid;
  }

  /// Generates a random UUID v4 string without external dependencies.
  static String _generateUuid() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    // Set version bits (v4) and variant bits per RFC 4122.
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
      'User-Agent':     'Happ/1.5.1/Ulya/1.1.0',
      'X-HWID':         hwid,
      'X-Ver-OS':       osVersion,
      'X-Device-OS':    platform,
      'X-Device-Model': deviceModel,
    };
  }

  // ── Fetch & parse ─────────────────────────────────────────────────────────

  /// Fetches the subscription URL and returns a list of [ServerNode]s.
  ///
  /// Returns an empty list when no subscription URL is configured or on error.
  /// On success, nodes are cached in SharedPreferences.
  /// On error, cached nodes are returned if available.
  static Future<List<ServerNode>> fetchNodes() async {
    final subUrl = await getSubscriptionUrl();
    if (subUrl.isEmpty) return [];

    final uri = Uri.tryParse(subUrl);
    if (uri == null) return [];

    try {
      final headers = await _getDeviceHeaders();

      final response = await http.get(
        uri,
        headers: headers,
      ).timeout(const Duration(seconds: 15));

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

      // Persist to cache for offline use.
      await _saveToCache(nodes, _lastSubscriptionInfo);
      _lastFetchWasFromCache = false;
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: fetchNodes error: $e');
      return await _loadFromCache();
    }
  }

  // ── Public catalog (no subscription required) ─────────────────────────────

  /// Fetches the public server catalog from the mobile API backend.
  ///
  /// Called when no personal subscription URL is configured.
  /// These servers are for preview only — [ServerNode.link] is `null` and
  /// [ServerNode.isDisabled] is `true`, so they cannot be used to connect.
  static Future<List<ServerNode>> fetchPublicServers() async {
    final url = '${AppConfig.backendBaseUrl}/mobile/v1/servers';
    final uri = Uri.tryParse(url);
    if (uri == null) return [];

    try {
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('RemnawaveService: public servers returned ${response.statusCode}');
        return [];
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final list = body['servers'] as List<dynamic>? ?? [];
      final nodes = list.map((e) {
        final serverJson = Map<String, dynamic>.from(e as Map<String, dynamic>);

        final rawName = serverJson['name']?.toString() ?? '';

        if ((serverJson['countryCode'] == null ||
                serverJson['countryCode'].toString().isEmpty) &&
            rawName.isNotEmpty) {
          final code = _countryCodeFromName(rawName);
          if (code.isNotEmpty) {
            serverJson['countryCode'] = code;
          }
        }

        final cleanName = _cleanServerName(rawName);
        serverJson['name'] = cleanName;

        return ServerNode.fromJson(serverJson);
      }).toList();

      debugPrint('RemnawaveService: loaded ${nodes.length} public servers');
      return nodes;
    } catch (e) {
      debugPrint('RemnawaveService: fetchPublicServers error: $e');
      return [];
    }
  }

  // ── Public VLESS parser ───────────────────────────────────────────────────

  /// Decodes a base64-encoded subscription body and returns a list of
  /// [VlessServer] objects for every valid `vless://` line.
  ///
  /// Algorithm:
  ///   1. base64_decode the body (handles URL-safe alphabet + missing padding)
  ///   2. split by `\n`
  ///   3. filter empty lines and lines not starting with `vless://`
  ///   4. parse URI → extract query params → URL-decode fragment as displayName
  ///
  /// Edge cases handled:
  ///   - Non-base64 input falls back to plain-text split
  ///   - Malformed URIs are silently skipped
  ///   - Duplicate links (same uuid+host+port) are deduplicated
  static List<VlessServer> parseVlessLinks(String rawBody) {
    final lines = _parseSubscriptionBody(rawBody);

    final seen = <String>{};
    final result = <VlessServer>[];

    for (final line in lines) {
      if (!line.startsWith('vless://')) continue;

      Uri uri;
      try {
        uri = Uri.parse(line);
      } catch (_) {
        continue;
      }

      final vs = VlessServer.fromUri(uri);
      if (vs == null) continue;

      // Deduplicate by uuid+host+port.
      final key = '${vs.uuid}@${vs.host}:${vs.port}';
      if (seen.contains(key)) continue;
      seen.add(key);

      result.add(vs);
    }

    debugPrint('RemnawaveService.parseVlessLinks: ${result.length} servers');
    return result;
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  /// Removes the flag emoji from the beginning of a server name.
  /// E.g.: "🇷🇺 Russia" → "Russia", "🇩🇪 DE-01" → "DE-01".
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

    // Restore subscription info from cache.
    final cachedInfoRaw = prefs.getString(_prefCachedSubscriptionInfo);
    if (cachedInfoRaw != null) {
      try {
        _lastSubscriptionInfo = SubscriptionInfo.fromJson(
          jsonDecode(cachedInfoRaw) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    // Restore nodes from cache.
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

  // ── Subscription body ─────────────────────────────────────────────────────

  /// Parses the raw subscription body into individual config-link strings.
  ///
  /// Remnawave (and most panels) return configs in one of three formats:
  ///  1. JSON array of full Xray configs: `[{"dns":...,"outbounds":[...]},...]`
  ///  2. Base64-encoded text: one vless/vmess/trojan link per line
  ///  3. Plain text: one link per line
  static List<String> _parseSubscriptionBody(String body) {
    body = body.trim();
    if (body.isEmpty) return [];

    // ── Format 1: JSON array of full Xray configs ──────────────────────────
    if (body.startsWith('[')) {
      try {
        final list = jsonDecode(body) as List<dynamic>;
        if (list.isNotEmpty && list[0] is Map) {
          debugPrint(
              'RemnawaveService: parsed as JSON array (${list.length} configs)');
          return list
              .whereType<Map<String, dynamic>>()
              .map(jsonEncode)
              .toList();
        }
      } catch (_) {
        // Not a valid JSON array — fall through.
      }
    }

    // ── Format 2: Single JSON object ──────────────────────────────────────
    if (body.startsWith('{')) {
      try {
        final obj = jsonDecode(body) as Map<String, dynamic>;
        debugPrint('RemnawaveService: parsed as single JSON config');
        return [jsonEncode(obj)];
      } catch (_) {}
    }

    // ── Format 3: Base64-encoded links ────────────────────────────────────
    try {
      String b64 = body.replaceAll('\n', '').replaceAll('\r', '');
      final padding = b64.length % 4;
      if (padding != 0) b64 += '=' * (4 - padding);
      final decoded = utf8.decode(base64.decode(b64));
      if (decoded.contains('://')) {
        debugPrint(
            'RemnawaveService: parsed as base64 (${decoded.split('\n').length} lines)');
        return decoded
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      }
    } catch (_) {
      // Not base64 — fall through to plain-text parsing.
    }

    // ── Format 4: Plain text links ────────────────────────────────────────
    debugPrint('RemnawaveService: parsed as plain text');
    return body
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  // ── Subscription info header ──────────────────────────────────────────────

  /// Parses the `Subscription-Userinfo` header into a [SubscriptionInfo].
  ///
  /// Standard format: `upload=131072; download=1048576; total=1073741824; expire=1893427200`
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

  // ── Fragment parser ───────────────────────────────────────────────────────

  static ({String name, String? description}) _parseFragment(
    String fragment,
    String fallbackHost,
  ) {
    if (fragment.isEmpty) {
      return (name: fallbackHost, description: null);
    }

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
      } catch (_) {
        // ignore malformed base64 or query
      }
    }

    return (name: name, description: description);
  }

  // ── Config link parser ────────────────────────────────────────────────────

  /// Parses a single VPN config link into a [ServerNode].
  ///
  /// Handles two input formats:
  ///   - JSON string (full Xray config): `{"outbounds":[...],"remarks":"..."}`
  ///   - URI string: `vless://`, `vmess://`, `trojan://`, `ss://`, etc.
  ///
  /// For `vless://` links the [ServerNode.vlessServer] field is populated with
  /// fully-typed parameters (flow, sni, fp, pbk, etc.) ready for Stage 4.
  ///
  /// Returns `null` for unrecognised or malformed links.
  static ServerNode? _parseConfigLink(String link) {
    try {
      link = link.trim();
      if (link.isEmpty) return null;

      // ── Full Xray JSON config ──────────────────────────────────────────
      if (link.startsWith('{')) {
        return _parseXrayJsonConfig(link);
      }

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

      // For VLESS links — extract all typed params into VlessServer.
      VlessServer? vlessServer;
      if (scheme == 'vless') {
        vlessServer = VlessServer.fromUri(uri);
        // Override displayName with the cleaned name so it matches the UI label.
        if (vlessServer != null) {
          vlessServer = VlessServer(
            uuid:        vlessServer.uuid,
            host:        vlessServer.host,
            port:        vlessServer.port,
            displayName: cleanName,
            flow:        vlessServer.flow,
            sni:         vlessServer.sni,
            fp:          vlessServer.fp,
            pbk:         vlessServer.pbk,
            network:     vlessServer.network,
            security:    vlessServer.security,
            sid:         vlessServer.sid,
            path:        vlessServer.path,
            wsHost:      vlessServer.wsHost,
            encryption:  vlessServer.encryption,
          );
        }
      }

      return ServerNode(
        uuid:        link,   // raw link as UUID — required by plugin for connect
        name:        cleanName,
        address:     host,
        serverPort:  uri.hasPort ? uri.port : 443,
        countryCode: countryCode,
        isConnected: true,
        isDisabled:  false,
        link:        link,
        protocol:    scheme,
        description: description,
        vlessServer: vlessServer,
      );
    } catch (e) {
      debugPrint('RemnawaveService: failed to parse link: $e');
      return null;
    }
  }

  // ── Full Xray JSON config parser ──────────────────────────────────────────

  /// Parses a full Xray JSON config string (as returned by Remnawave when the
  /// subscription format is a JSON array instead of vless:// links).
  ///
  /// VPN compatibility strategy
  /// ──────────────────────────
  /// Remnawave generates *desktop* Xray configs: complex geo-routing, custom DNS
  /// policies, inbounds on desktop ports, etc.  On mobile (tun2socks mode) this
  /// causes silent failures: xray starts but routes traffic incorrectly.
  ///
  /// For **regular servers** we build a *clean mobile config* — identical in
  /// structure to what `FlutterV2RayURL.getFullConfiguration()` produces:
  ///   - Only the proxy outbound from Remnawave (all stream/TLS settings kept)
  ///   - freedom + blackhole utility outbounds
  ///   - Simple DNS: ["8.8.8.8", "1.1.1.1"]
  ///   - Empty routing (XrayCoreManager injects API rule)
  ///   - No inbounds (XrayCoreManager injects SOCKS 10807 + HTTP 10808)
  ///
  /// For **virtual/balanced hosts** the routing.balancers + rules are preserved
  /// (they contain the load-balancing logic), but inbounds are stripped and
  /// DNS is simplified.
  static ServerNode? _parseXrayJsonConfig(String jsonStr) {
    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      // ── Remarks — try multiple field names ────────────────────────────────
      // Remnawave puts the server name in `remarks` (standard xray field).
      // Log all top-level string fields on first call to help diagnose issues.
      final rawRemarks =
          (json['remarks']     as String?) ??
          (json['description'] as String?) ??
          (json['name']        as String?) ?? '';
      // serverDescription is the category label set by Remnawave (e.g. "Белые списки").
      // Remnawave stores it inside a nested `meta` object: meta.serverDescription.
      final meta = json['meta'] as Map<String, dynamic>?;
      final serverDescription = (meta?['serverDescription'] as String?)
          ?? (json['serverDescription'] as String?); // fallback for older format
      debugPrint('RemnawaveService.parseJSON: remarks="$rawRemarks" '
          'serverDescription="$serverDescription" '
          'allKeys=${json.keys.toList()}');

      // ── Collect all outbounds ─────────────────────────────────────────────
      final allOutbounds = json['outbounds'] as List<dynamic>? ?? [];
      const skipProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

      final proxyOutbounds = allOutbounds
          .whereType<Map<String, dynamic>>()
          .where((ob) => !skipProtocols.contains(
              (ob['protocol'] as String? ?? '').toLowerCase()))
          .toList();

      // ── Detect virtual / balanced host ────────────────────────────────────
      final routing   = json['routing'] as Map<String, dynamic>?;
      final balancers = routing?['balancers'] as List<dynamic>?;
      final isVirtual = (balancers != null && balancers.isNotEmpty)
          || proxyOutbounds.length > 1;

      if (isVirtual) {
        // Keep full routing (balancers + rules) but strip inbounds and use
        // clean DNS.  Pre-include the SOCKS inbound with sniffing DISABLED so
        // XrayCoreManager does NOT inject its own (which has sniffing=true).
        // With sniffing=true xray would do DNS resolution for every connection
        // via its internal resolver, whose traffic also goes through TUN when
        // includeSelfInVpn=true — causing latency-inducing re-entry loops.
        final mobileJson = jsonEncode({
          'log':      {'loglevel': 'warning'},
          'dns':      {'servers': ['1.1.1.1', '1.0.0.1'], 'queryStrategy': 'UseIP'},
          'inbounds': [_socksInbound],
          'outbounds': allOutbounds,  // keep all — balancer references them
          'routing':  {
            'domainStrategy': routing?['domainStrategy'] ?? 'IPIfNonMatch',
            'domainMatcher':  'hybrid',
            'rules':    routing?['rules']    ?? [],
            'balancers': balancers ?? [],
          },
        });

        final name = rawRemarks.isNotEmpty ? _cleanServerName(rawRemarks) : 'Авто-выбор';
        return ServerNode(
          uuid:        mobileJson,
          name:        name,
          address:     '',
          serverPort:  443,
          countryCode: '',
          isConnected: true,
          isDisabled:  false,
          link:        mobileJson,
          protocol:    'auto',
          description: serverDescription ?? rawRemarks,
        );
      }

      // ── Regular single-server config ──────────────────────────────────────
      if (proxyOutbounds.isEmpty) return null;
      final proxyOutbound = proxyOutbounds.first;
      final protocol = (proxyOutbound['protocol'] as String? ?? 'vless').toLowerCase();
      final settings = proxyOutbound['settings'] as Map<String, dynamic>? ?? {};

      String host = '';
      int    port = 443;

      switch (protocol) {
        case 'vless':
        case 'vmess':
          final vnext = settings['vnext'] as List<dynamic>?;
          if (vnext != null && vnext.isNotEmpty) {
            final s = vnext[0] as Map<String, dynamic>;
            host = (s['address'] as String?) ?? '';
            port = (s['port']    as int?)    ?? 443;
          }
        case 'trojan':
        case 'shadowsocks':
          final servers = settings['servers'] as List<dynamic>?;
          if (servers != null && servers.isNotEmpty) {
            final s = servers[0] as Map<String, dynamic>;
            host = (s['address'] as String?) ?? '';
            port = (s['port']    as int?)    ?? 443;
          }
        default:
          debugPrint('RemnawaveService.parseJSON: unsupported protocol "$protocol"');
          return null;
      }

      if (host.isEmpty) return null;

      // ── Build clean mobile config ─────────────────────────────────────────
      // Mirror FlutterV2RayURL.getFullConfiguration() structure.
      // Pre-include SOCKS inbound with sniffing=false so XrayCoreManager does
      // NOT inject its own (which has sniffing=true and causes DNS re-entry
      // loops when includeSelfInVpn=true).
      final mobileJson = jsonEncode({
        'log':     {'loglevel': 'warning'},
        'dns':     {'servers': ['1.1.1.1', '1.0.0.1'], 'queryStrategy': 'UseIP'},
        'inbounds': [_socksInbound],
        'outbounds': [
          proxyOutbound,
          {'tag': 'direct',    'protocol': 'freedom'},
          {'tag': 'block',     'protocol': 'blackhole'},
        ],
        'routing': {
          'domainStrategy': 'IPIfNonMatch',
          'domainMatcher':  'hybrid',
          'rules': [
            // Route bittorrent directly (not through VPN) — matches Happ behaviour.
            {'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'direct'},
          ],
        },
      });

      final nameRaw = rawRemarks.isNotEmpty ? rawRemarks : host;
      final name    = _cleanServerName(nameRaw);
      final country = _countryCodeFromName(nameRaw);

      return ServerNode(
        uuid:        mobileJson,
        name:        name,
        address:     host,
        serverPort:  port,
        countryCode: country,
        isConnected: true,
        isDisabled:  false,
        link:        mobileJson,
        protocol:    protocol,
        description: serverDescription ?? rawRemarks,
      );
    } catch (e) {
      debugPrint('RemnawaveService: failed to parse JSON config: $e');
      return null;
    }
  }

  // ── Country code heuristic ────────────────────────────────────────────────

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
    final prefixMatch =
        RegExp(r'^([A-Z]{2})[-_\s\d]').firstMatch(name.toUpperCase());
    if (prefixMatch != null) return prefixMatch.group(1)!;

    return '';
  }
}
