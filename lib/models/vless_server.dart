/// Fully-parsed VLESS server parameters extracted from a vless:// URI.
///
/// Used in Stage 4 to build the xray outbound JSON config without relying
/// on the plugin's built-in URL parser.
class VlessServer {
  /// VLESS user UUID (the userinfo part of the URI, before @).
  final String uuid;

  /// Server hostname or IP.
  final String host;

  /// Server port.
  final int port;

  /// XTLS/XRAY flow control, e.g. `xtls-rprx-vision`. Empty string if absent.
  final String flow;

  /// SNI value for TLS/Reality handshake.
  final String sni;

  /// Fingerprint for uTLS, e.g. `chrome`, `firefox`. Empty string if absent.
  final String fp;

  /// Reality public key (base64). Empty string if absent.
  final String pbk;

  /// Human-readable display name decoded from the URI fragment.
  final String displayName;

  // ── Additional transport/security params ─────────────────────────────────

  /// Network type: `tcp`, `ws`, `grpc`, `http`, etc.
  final String network;

  /// Security layer: `reality`, `tls`, `none`.
  final String security;

  /// Reality short ID (sid query param).
  final String sid;

  /// WebSocket path or gRPC service name.
  final String path;

  /// WebSocket host header (host query param inside ws settings).
  final String wsHost;

  /// Encryption value (usually `none` for VLESS).
  final String encryption;

  const VlessServer({
    required this.uuid,
    required this.host,
    required this.port,
    required this.displayName,
    this.flow = '',
    this.sni = '',
    this.fp = '',
    this.pbk = '',
    this.network = 'tcp',
    this.security = 'none',
    this.sid = '',
    this.path = '',
    this.wsHost = '',
    this.encryption = 'none',
  });

  /// Builds a [VlessServer] by parsing a `vless://` URI.
  ///
  /// Returns `null` if the URI is not a valid VLESS link.
  static VlessServer? fromUri(Uri uri) {
    if (uri.scheme.toLowerCase() != 'vless') return null;

    final userUuid = uri.userInfo;
    if (userUuid.isEmpty) return null;

    final host = uri.host;
    if (host.isEmpty) return null;

    final port = uri.hasPort ? uri.port : 443;

    final q = uri.queryParameters;

    // URL-decode the fragment (display name).
    String displayName = '';
    if (uri.fragment.isNotEmpty) {
      try {
        displayName = Uri.decodeComponent(uri.fragment);
      } catch (_) {
        displayName = uri.fragment;
      }
    }
    if (displayName.isEmpty) displayName = host;

    return VlessServer(
      uuid:        userUuid,
      host:        host,
      port:        port,
      displayName: displayName,
      flow:        q['flow']       ?? '',
      sni:         q['sni']        ?? '',
      fp:          q['fp']         ?? '',
      pbk:         q['pbk']        ?? '',
      network:     q['type']       ?? 'tcp',
      security:    q['security']   ?? 'none',
      sid:         q['sid']        ?? '',
      path:        q['path']       ?? '',
      wsHost:      q['host']       ?? '',
      encryption:  q['encryption'] ?? 'none',
    );
  }

  /// Serialise to JSON (for caching in SharedPreferences).
  Map<String, dynamic> toJson() => {
    'uuid':        uuid,
    'host':        host,
    'port':        port,
    'displayName': displayName,
    'flow':        flow,
    'sni':         sni,
    'fp':          fp,
    'pbk':         pbk,
    'network':     network,
    'security':    security,
    'sid':         sid,
    'path':        path,
    'wsHost':      wsHost,
    'encryption':  encryption,
  };

  factory VlessServer.fromJson(Map<String, dynamic> j) => VlessServer(
    uuid:        j['uuid']        as String? ?? '',
    host:        j['host']        as String? ?? '',
    port:        (j['port']       as num?)?.toInt() ?? 443,
    displayName: j['displayName'] as String? ?? '',
    flow:        j['flow']        as String? ?? '',
    sni:         j['sni']         as String? ?? '',
    fp:          j['fp']          as String? ?? '',
    pbk:         j['pbk']         as String? ?? '',
    network:     j['network']     as String? ?? 'tcp',
    security:    j['security']    as String? ?? 'none',
    sid:         j['sid']         as String? ?? '',
    path:        j['path']        as String? ?? '',
    wsHost:      j['wsHost']      as String? ?? '',
    encryption:  j['encryption']  as String? ?? 'none',
  );

  @override
  String toString() => 'VlessServer($displayName @ $host:$port)';
}
