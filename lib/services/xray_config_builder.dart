import 'dart:convert';

/// Builds a proper Xray-core JSON configuration from a VPN link.
///
/// Generates configs in the format used by Happ / v2rayNG that are compatible
/// with whitelist-based mobile filtering (e.g. Rostelecom LTE, Beeline).
///
/// Supported protocols: vless, vmess, trojan, shadowsocks (ss).
class XrayConfigBuilder {
  /// Patches a native Xray JSON config (as produced by `v2ray_box.generateConfig`)
  /// with improved DNS and routing settings for whitelist-based mobile filtering.
  ///
  /// Only the `dns` and `routing` sections are replaced; all other sections
  /// (inbounds with TUN handling, outbounds, policy, etc.) are kept unchanged
  /// so that VPN mode (TUN interface) continues to work correctly.
  ///
  /// Returns the modified JSON string, or `null` if [nativeConfigJson] cannot
  /// be parsed.
  static String? patchNativeConfig(String nativeConfigJson) {
    try {
      final config =
          jsonDecode(nativeConfigJson) as Map<String, dynamic>;

      // Replace DNS with UseIPv4 + 1.1.1.1/8.8.8.8 servers.
      // The googleapis.cn → googleapis.com host override avoids DNS poisoning
      // for Chinese-hosted Google APIs (common in VPN panel setups).
      config['dns'] = {
        'hosts': {'domain:googleapis.cn': 'googleapis.com'},
        'queryStrategy': 'UseIPv4',
        'servers': [
          // Detailed objects allow future per-domain routing overrides.
          {'address': '1.1.1.1', 'domains': <String>[], 'port': 53},
          {'address': '8.8.8.8', 'domains': <String>[], 'port': 53},
          // Plain string fallback for Xray versions that need it.
          '1.1.1.1',
        ],
      };

      // Keep any existing routing rules and prepend DNS routing rules.
      final existing = config['routing'];
      final existingRules =
          (existing is Map ? existing['rules'] as List<dynamic>? : null) ??
              <dynamic>[];
      config['routing'] = {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          // Route Cloudflare DNS through the proxy outbound.
          {'ip': ['1.1.1.1'], 'outboundTag': 'proxy', 'port': '53'},
          // Route Google DNS directly.
          {'ip': ['8.8.8.8'], 'outboundTag': 'direct', 'port': '53'},
          ...existingRules,
        ],
      };

      return const JsonEncoder.withIndent('  ').convert(config);
    } catch (_) {
      return null;
    }
  }

  /// Parses [link] and returns a ready-to-use Xray JSON config string.
  ///
  /// The generated config includes:
  ///  - SOCKS5 inbound on 10808
  ///  - HTTP inbound on 10809
  ///  - DNS with UseIPv4 strategy + 1.1.1.1 / 8.8.8.8 servers
  ///  - Routing with IPIfNonMatch strategy and DNS routing rules
  ///  - Policy timeouts
  ///  - Stats
  ///
  /// Returns `null` if [link] cannot be parsed.
  /// NOTE: Does not include TUN inbound — use [patchNativeConfig] instead
  /// for VPN mode to preserve the native TUN handling.
  static String? buildFromLink(String link) {
    link = link.trim();
    final uri = Uri.tryParse(link);
    if (uri == null) return null;

    final scheme = uri.scheme.toLowerCase();
    // Each builder assigns 'proxy' as the outbound tag; routing rules below
    // reference it by that tag.
    Map<String, dynamic>? outbound;

    switch (scheme) {
      case 'vless':
        outbound = _buildVlessOutbound(uri);
      case 'vmess':
        outbound = _buildVmessOutbound(link);
      case 'trojan':
        outbound = _buildTrojanOutbound(uri);
      case 'ss':
        outbound = _buildShadowsocksOutbound(uri);
      default:
        return null;
    }

    if (outbound == null) return null;

    final config = {
      'log': {'loglevel': 'warning'},
      'dns': {
        'hosts': {'domain:googleapis.cn': 'googleapis.com'},
        'queryStrategy': 'UseIPv4',
        'servers': [
          // Detailed server objects for per-domain routing; the plain string
          // acts as a catch-all fallback (Xray ignores duplicates gracefully).
          {
            'address': '1.1.1.1',
            'domains': <String>[],
            'port': 53,
          },
          {
            'address': '8.8.8.8',
            'domains': <String>[],
            'port': 53,
          },
          '1.1.1.1',
        ],
      },
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': 10808,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
          'sniffing': {
            'destOverride': ['http', 'tls', 'quic'],
            'enabled': true,
          },
          'tag': 'socks',
        },
        {
          'listen': '127.0.0.1',
          'port': 10809,
          'protocol': 'http',
          'settings': {'userLevel': 8},
          'sniffing': {
            'destOverride': ['http', 'tls', 'quic'],
            'enabled': true,
          },
          'tag': 'http',
        },
      ],
      'outbounds': [
        outbound,
        {
          'protocol': 'freedom',
          'settings': {'domainStrategy': 'UseIP'},
          'tag': 'direct',
        },
        {
          'protocol': 'blackhole',
          'settings': {
            'response': {'type': 'http'},
          },
          'tag': 'block',
        },
      ],
      'policy': {
        'levels': {
          '8': {
            'connIdle': 300,
            'downlinkOnly': 1,
            'handshake': 4,
            'uplinkOnly': 1,
          },
        },
        'system': {
          'statsInboundDownlink': true,
          'statsInboundUplink': true,
          'statsOutboundDownlink': true,
          'statsOutboundUplink': true,
        },
      },
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          // Route Cloudflare DNS through the proxy.
          {
            'ip': ['1.1.1.1'],
            'outboundTag': 'proxy',
            'port': '53',
          },
          // Route Google DNS directly (avoids blocking 8.8.8.8 via proxy).
          {
            'ip': ['8.8.8.8'],
            'outboundTag': 'direct',
            'port': '53',
          },
        ],
      },
      'stats': <String, dynamic>{},
    };

    return const JsonEncoder.withIndent('  ').convert(config);
  }

  // ── VLESS ──────────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _buildVlessOutbound(Uri uri) {
    final uuid = uri.userInfo;
    final host = uri.host;
    final port = uri.port > 0 ? uri.port : 443;
    if (uuid.isEmpty || host.isEmpty) return null;

    final q = uri.queryParameters;
    final security = q['security'] ?? 'none';
    final network = q['type'] ?? q['net'] ?? 'tcp';
    final flow = q['flow'] ?? '';
    final sni = q['sni'] ?? q['host'] ?? host;
    final fp = q['fp'] ?? 'chrome';
    final pbk = q['pbk'] ?? '';
    final sid = q['sid'] ?? '';
    final headerType = q['headerType'] ?? 'none';
    final path = q['path'] ?? '';
    final wsHost = q['host'] ?? '';
    final alpn = q['alpn'] ?? '';

    final streamSettings = _buildStreamSettings(
      network: network,
      security: security,
      sni: sni,
      fp: fp,
      pbk: pbk,
      sid: sid,
      headerType: headerType,
      path: path,
      wsHost: wsHost,
      alpn: alpn,
    );

    return {
      'mux': {
        'concurrency': -1,
        'enabled': false,
        'xudpConcurrency': 8,
        'xudpProxyUDP443': '',
      },
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': host,
            'port': port,
            'users': [
              {
                'encryption': 'none',
                'flow': flow,
                'id': uuid,
                'level': 8,
                'security': 'auto',
              },
            ],
          },
        ],
      },
      'streamSettings': streamSettings,
      'tag': 'proxy',
    };
  }

  // ── VMess ──────────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _buildVmessOutbound(String link) {
    // vmess://base64json
    final b64 = link.substring('vmess://'.length).trim();
    try {
      final decoded = _decodeBase64(b64);
      if (decoded == null) return null;
      final Map<String, dynamic> v = jsonDecode(decoded) as Map<String, dynamic>;

      final host = v['add'] as String? ?? '';
      final port = int.tryParse(v['port']?.toString() ?? '443') ?? 443;
      final uuid = v['id'] as String? ?? '';
      final aid = int.tryParse(v['aid']?.toString() ?? '0') ?? 0;
      final network = v['net'] as String? ?? 'tcp';
      final security = v['tls'] as String? ?? 'none';
      final sni = v['sni'] as String? ?? v['host'] as String? ?? host;
      final wsPath = v['path'] as String? ?? '';
      final wsHost = v['host'] as String? ?? '';
      final fp = v['fp'] as String? ?? '';
      final headerType = v['type'] as String? ?? 'none';

      final streamSettings = _buildStreamSettings(
        network: network,
        security: security,
        sni: sni,
        fp: fp,
        pbk: '',
        sid: '',
        headerType: headerType,
        path: wsPath,
        wsHost: wsHost,
        alpn: '',
      );

      return {
        'mux': {
          'concurrency': -1,
          'enabled': false,
          'xudpConcurrency': 8,
          'xudpProxyUDP443': '',
        },
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': host,
              'port': port,
              'users': [
                {
                  'alterId': aid,
                  'id': uuid,
                  'level': 8,
                  'security': 'auto',
                },
              ],
            },
          ],
        },
        'streamSettings': streamSettings,
        'tag': 'proxy',
      };
    } catch (_) {
      return null;
    }
  }

  // ── Trojan ─────────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _buildTrojanOutbound(Uri uri) {
    final password = uri.userInfo;
    final host = uri.host;
    final port = uri.port > 0 ? uri.port : 443;
    if (password.isEmpty || host.isEmpty) return null;

    final q = uri.queryParameters;
    final security = q['security'] ?? 'tls';
    final network = q['type'] ?? 'tcp';
    final sni = q['sni'] ?? q['host'] ?? host;
    final fp = q['fp'] ?? '';
    final pbk = q['pbk'] ?? '';
    final sid = q['sid'] ?? '';
    final alpn = q['alpn'] ?? '';
    final path = q['path'] ?? '';
    final wsHost = q['host'] ?? '';

    final streamSettings = _buildStreamSettings(
      network: network,
      security: security,
      sni: sni,
      fp: fp,
      pbk: pbk,
      sid: sid,
      headerType: 'none',
      path: path,
      wsHost: wsHost,
      alpn: alpn,
    );

    return {
      'mux': {
        'concurrency': -1,
        'enabled': false,
        'xudpConcurrency': 8,
        'xudpProxyUDP443': '',
      },
      'protocol': 'trojan',
      'settings': {
        'servers': [
          {
            'address': host,
            'level': 8,
            'password': password,
            'port': port,
          },
        ],
      },
      'streamSettings': streamSettings,
      'tag': 'proxy',
    };
  }

  // ── Shadowsocks ────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _buildShadowsocksOutbound(Uri uri) {
    final host = uri.host;
    final port = uri.port > 0 ? uri.port : 443;
    if (host.isEmpty) return null;

    // SS URI: ss://base64(method:password)@host:port or ss://method:password@host:port
    String method = 'aes-256-gcm';
    String password = '';

    final userInfo = uri.userInfo;
    if (userInfo.isNotEmpty) {
      // Try to decode as base64 first.
      final decoded = _decodeBase64(userInfo);
      if (decoded != null) {
        final colonIdx = decoded.indexOf(':');
        if (colonIdx > 0) {
          method = decoded.substring(0, colonIdx);
          password = decoded.substring(colonIdx + 1);
        }
      } else {
        // Plain method:password
        final colonIdx = userInfo.indexOf(':');
        if (colonIdx > 0) {
          method = userInfo.substring(0, colonIdx);
          password = userInfo.substring(colonIdx + 1);
        }
      }
    }

    if (password.isEmpty) return null;

    return {
      'mux': {
        'concurrency': -1,
        'enabled': false,
        'xudpConcurrency': 8,
        'xudpProxyUDP443': '',
      },
      'protocol': 'shadowsocks',
      'settings': {
        'servers': [
          {
            'address': host,
            'level': 8,
            'method': method,
            'password': password,
            'port': port,
          },
        ],
      },
      'streamSettings': {'network': 'tcp', 'security': 'none'},
      'tag': 'proxy',
    };
  }

  // ── Stream Settings builder ────────────────────────────────────────────────

  static Map<String, dynamic> _buildStreamSettings({
    required String network,
    required String security,
    required String sni,
    required String fp,
    required String pbk,
    required String sid,
    required String headerType,
    required String path,
    required String wsHost,
    required String alpn,
  }) {
    final Map<String, dynamic> stream = {'network': network};

    // Security layer
    switch (security) {
      case 'reality':
        stream['security'] = 'reality';
        stream['realitySettings'] = {
          'allowInsecure': false,
          'fingerprint': fp.isNotEmpty ? fp : 'chrome',
          'publicKey': pbk,
          'serverName': sni,
          'shortId': sid,
          'show': false,
          'spiderX': '/',
        };
      case 'tls':
        stream['security'] = 'tls';
        stream['tlsSettings'] = {
          'allowInsecure': false,
          'fingerprint': fp.isNotEmpty ? fp : '',
          'serverName': sni,
          if (alpn.isNotEmpty)
            'alpn': alpn.split(',').map((s) => s.trim()).toList(),
        };
      default:
        stream['security'] = 'none';
    }

    // Transport layer
    switch (network) {
      case 'tcp':
        stream['tcpSettings'] = {
          'header': {'type': headerType.isNotEmpty ? headerType : 'none'},
        };
      case 'ws':
        final wsSettings = <String, dynamic>{
          'path': path.isNotEmpty ? path : '/',
        };
        if (wsHost.isNotEmpty) {
          wsSettings['headers'] = {'Host': wsHost};
        }
        stream['wsSettings'] = wsSettings;
      case 'grpc':
        stream['grpcSettings'] = {
          'serviceName': path,
          'multiMode': false,
        };
      case 'h2':
      case 'http':
        stream['network'] = 'h2';
        stream['httpSettings'] = {
          'path': path.isNotEmpty ? path : '/',
          if (wsHost.isNotEmpty) 'host': [wsHost],
        };
      case 'quic':
        stream['quicSettings'] = {
          'security': 'none',
          'key': '',
          'header': {'type': 'none'},
        };
    }

    return stream;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Decodes a URL-safe or standard base64 string.
  /// Returns the decoded UTF-8 string, or `null` on failure.
  static String? _decodeBase64(String input) {
    try {
      String padded = input.replaceAll('-', '+').replaceAll('_', '/');
      final rem = padded.length % 4;
      if (rem != 0) padded += '=' * (4 - rem);
      return utf8.decode(base64.decode(padded));
    } catch (_) {
      return null;
    }
  }
}
