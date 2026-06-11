import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter_v2ray_plus/flutter_v2ray.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:share_plus/share_plus.dart';

import '../models/me_response.dart';
import '../models/server_node.dart';
import '../models/subscription_info.dart';
import '../config/app_config.dart';
import '../services/app_logger.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/ping_state.dart';
import '../services/referral_service.dart';
import '../services/remnawave_service.dart';
import '../services/selected_server_state.dart';
import '../utils/server_icon.dart';
import '../utils/signal_quality.dart';
import '../utils/speed_calculator.dart';
import 'auth_bottom_sheet.dart';
import 'referral_page.dart';
import 'subscription_page.dart';
import 'support_page.dart';
import '../main.dart' show DS;

class HomePage extends StatefulWidget {
  final VoidCallback? onGoToPremium;

  const HomePage({super.key, this.onGoToPremium});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const List<String> _bypassKeywords = [
    'белые',
    'обход',
    'bypass',
    'лте',
    'lte',
  ];
  // Multi-token signatures where all tokens must be present in description.
  static const List<List<String>> _bypassKeywordCombos = [
    ['yt', 'tg'],
  ];
  static const int _defaultServerPort = 443;
  static const Duration _nodeReachabilityTimeout = Duration(seconds: 1);
  static const int _maxReachabilityWorkers = 4;

  // ── V2ray ──────────────────────────────────────────────────────────────────
  late final FlutterV2ray _v2ray;
  VlessStatus _status = VlessStatus();
  StreamSubscription<VlessStatus>? _statusSub;

  // ── Nodes ──────────────────────────────────────────────────────────────────
  List<ServerNode> _nodes = [];
  ServerNode? _selectedNode;
  bool _isLoadingNodes  = false;
  bool _pendingLoad     = false;   // set when a load is requested while one is running
  bool _isPublicCatalog = false;
  SubscriptionInfo? _subscriptionInfo;
  String _lastKnownSubUrl = '';
  // True once _loadNodes finished at least once (success or failure). Used to
  // distinguish 'still loading' from 'finished but no data', so we can show a
  // retry CTA instead of an endless spinner when the backend returns empty.
  bool _loadAttempted = false;
  String? _loadError;

  // ── State ──────────────────────────────────────────────────────────────────
  late final SpeedCalculator _speedCalc;
  bool _initialized = false;
  bool _isConnecting = false;

  // ── Signal / ping ─────────────────────────────────────────────────────────
  // Probe state lives in the shared PingState service so the home connection
  // card and the servers list stay in sync — whoever measured last wins.
  // `_pingInFlight` and `_pingMeasuring` remain local because they describe
  // *this* widget's probe lifecycle, not the global cache.
  Timer? _pingTimer;
  bool _pingInFlight = false;
  bool _pingMeasuring = false;

  int? get _pingMs {
    final uuid = _selectedNode?.uuid;
    return uuid == null ? null : PingState.get(uuid);
  }

  // ── Speed history (sparkline ring buffers) ────────────────────────────────
  static const int _sparkLen = 18;
  final List<double> _downloadHist = [];
  final List<double> _uploadHist = [];

  // ── Referral ──────────────────────────────────────────────────────────────
  // Loaded lazily from /cabinet/referral once we have a Cabinet JWT. The card
  // is hidden entirely until [_referralInfo] is non-null, so failure modes
  // (no auth / network error / disabled programme) just collapse the slot.
  ReferralInfo? _referralInfo;
  bool _referralCopied = false;

  // ── Computed ───────────────────────────────────────────────────────────────
  bool get _isConnected => _status.state.toUpperCase() == 'CONNECTED';
  bool get _isTransitioning =>
      _status.state.toUpperCase() == 'CONNECTING' ||
          _status.state.toUpperCase() == 'DISCONNECTING' ||
          _isConnecting;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedServerNotifier.addListener(_onSelectedServerChanged);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    // Rebuild on shared ping cache updates — picks up measurements made by
    // the ServersPage sweep without us having to re-probe locally.
    PingState.notifier.addListener(_onPingStateChanged);
    _speedCalc = SpeedCalculator(smoothing: 0.25);
    _v2ray = FlutterV2ray();
    _init();
  }

  void _onPingStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reset speed calculator to prevent stale delta causing unrealistic values
      _speedCalc.reset();
      _refreshAll();
      // Re-subscribe to VPN status to catch any state changes that happened
      // while the app was in the background (e.g. user disconnected via
      // the system VPN notification).
      _resubscribeVpnStatus();
    }
  }

  void _resubscribeVpnStatus() {
    // Cancel the old subscription and re-attach so the plugin sends the
    // current real state immediately rather than waiting for the next change.
    _statusSub?.cancel();
    _statusSub = _v2ray.onStatusChanged.listen((s) {
      if (!mounted) return;
      final connected = s.state.toUpperCase() == 'CONNECTED';
      final wasConnected = vpnConnectedNotifier.value;
      vpnConnectedNotifier.value = connected;
      if (connected) {
        _speedCalc.update(totalUploadBytes: s.upload, totalDownloadBytes: s.download);
        _pushSpark(_downloadHist, _speedCalc.downloadSpeed);
        _pushSpark(_uploadHist, _speedCalc.uploadSpeed);
        // Haptic when VPN just connected
        if (!wasConnected) HapticFeedback.mediumImpact();
      } else {
        _speedCalc.reset();
        _downloadHist.clear();
        _uploadHist.clear();
        // Haptic when VPN just disconnected
        if (wasConnected) HapticFeedback.lightImpact();
      }
      // Re-tune ping cadence to match the new state (10 s vs 30 s).
      if (connected != wasConnected) _restartPingTimer();
      setState(() => _status = s);
    });
  }

  // ── Referral ──────────────────────────────────────────────────────────────
  /// Pulls the referral snapshot if we have any auth context (Cabinet JWT
  /// or telegram id). Idempotent — safe to call on every auth-change tick;
  /// clears the card on logout.
  Future<void> _loadReferral() async {
    final auth = authStateNotifier.value;
    final hasAuth = (auth.cabinetAccessToken?.isNotEmpty ?? false) ||
        auth.telegramId != null;
    if (!hasAuth) {
      appLogger.info('HomePage', '_loadReferral: skipped (not authed)');
      if (_referralInfo != null && mounted) {
        setState(() => _referralInfo = null);
      }
      return;
    }
    appLogger.info('HomePage',
        '_loadReferral: fetching (jwt=${auth.cabinetAccessToken != null}, tg=${auth.telegramId != null})');
    final info = await ReferralService.getInfo();
    if (!mounted) return;
    if (info != _referralInfo) setState(() => _referralInfo = info);
  }

  Future<void> _copyReferralCode() async {
    final info = _referralInfo;
    if (info == null) return;
    await Clipboard.setData(ClipboardData(text: info.referralCode));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _referralCopied = true);
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _referralCopied = false);
    });
  }

  Future<void> _shareReferral() async {
    final info = _referralInfo;
    if (info == null) return;
    HapticFeedback.selectionClick();
    await SharePlus.instance.share(ShareParams(text: info.shareText));
  }

  void _openReferralPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ReferralPage()),
    ).then((_) {
      // Refresh in case the user shared/earned something while on the
      // details page.
      if (mounted) _loadReferral();
    });
  }

  // ── Sparkline helper ──────────────────────────────────────────────────────
  void _pushSpark(List<double> buf, double v) {
    buf.add(v < 0 ? 0 : v);
    while (buf.length > _sparkLen) {
      buf.removeAt(0);
    }
  }

  // ── Ping ───────────────────────────────────────────────────────────────────
  // Cadence: 10 s while connected (live signal), 30 s otherwise (signal preview
  // from server selection). The bars are visible whenever a server is picked.
  /// Burst-then-settle schedule.  The first few seconds after selecting a
  /// server are when the value matters most (user just changed their mind,
  /// or just opened the app), so we probe several times in quick succession
  /// to nail down an accurate reading even if the network was cold.
  /// After the burst we settle to a long-period heartbeat that just keeps
  /// the cache fresh.
  ///
  /// Schedule:  0s · 3s · 9s · 21s · then every 60s (or 30s while connected).
  static const List<Duration> _pingBurst = [
    Duration.zero,
    Duration(seconds: 3),
    Duration(seconds: 9),
    Duration(seconds: 21),
  ];

  int _pingBurstIdx = 0;

  void _restartPingTimer() {
    _pingTimer?.cancel();
    _pingBurstIdx = 0;
    if (_selectedNode == null) {
      _pingTimer = null;
      return;
    }
    _runPingBurstStep();
  }

  void _runPingBurstStep() {
    if (!mounted || _selectedNode == null) return;
    _measurePing();
    _pingBurstIdx++;
    if (_pingBurstIdx < _pingBurst.length) {
      // Next burst step uses delta between this step and the next; the burst
      // table stores absolute offsets, so we need the deltas.
      final delta = _pingBurst[_pingBurstIdx] - _pingBurst[_pingBurstIdx - 1];
      _pingTimer = Timer(delta, _runPingBurstStep);
    } else {
      // Settled — periodic heartbeat to keep the value fresh.
      final settled = _isConnected
          ? const Duration(seconds: 30)
          : const Duration(seconds: 60);
      _pingTimer = Timer.periodic(settled, (_) => _measurePing());
    }
  }

  Future<void> _measurePing() async {
    if (_pingInFlight) return;
    final node = _selectedNode;
    if (node == null || node.address.trim().isEmpty) return;
    _pingInFlight = true;
    // Surface the measuring state to the UI only when we have nothing to show
    // yet — otherwise the bars would flicker through "measuring" on every
    // background poll, which is noisy.
    if (_pingMs == null && mounted) {
      setState(() => _pingMeasuring = true);
    }
    final host = node.address.trim();
    final port = node.serverPort > 0 ? node.serverPort : _defaultServerPort;
    final newPing = await _accurateTcpRtt(host, port);
    _pingInFlight = false;
    PingState.set(node.uuid, newPing);
    if (!mounted) return;
    setState(() => _pingMeasuring = false);
  }

  /// Measures TCP RTT with a throwaway warm-up connect first, then takes the
  /// minimum of two follow-up measurements.
  ///
  /// Why: the first connect to a host pays for DNS, ARP, route discovery and
  /// TCP slow-start — that inflates the reading by hundreds of ms. The
  /// warm-up burns it. Taking min(probe1, probe2) on the hot path filters
  /// out the occasional retransmit / scheduler hiccup, leaving a number
  /// very close to true round-trip.
  ///
  /// Returns null if the warm-up fails (host unreachable / timeout).
  static Future<int?> _accurateTcpRtt(String host, int port,
      {Duration timeout = const Duration(seconds: 2)}) async {
    // Warm-up — discarded.
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
    } catch (_) {
      return null; // unreachable from this network
    }
    // Two real measurements; take the minimum.
    final m1 = await _singleConnect(host, port, timeout);
    if (m1 == null) return null;
    final m2 = await _singleConnect(host, port, timeout);
    if (m2 == null) return m1;
    return m1 < m2 ? m1 : m2;
  }

  static Future<int?> _singleConnect(
      String host, int port, Duration timeout) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      s.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    selectedServerNotifier.removeListener(_onSelectedServerChanged);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    globalRefreshNotifier.removeListener(_onGlobalRefresh);
    PingState.notifier.removeListener(_onPingStateChanged);
    _statusSub?.cancel();
    _pingTimer?.cancel();
    super.dispose();
  }

  void _onSelectedServerChanged() {
    if (!mounted) return;
    final node = selectedServerNotifier.value;
    if (node?.uuid != _selectedNode?.uuid) {
      // _pingMs is computed from PingState now — the value for this uuid
      // (if any) is already visible without a manual sync.
      setState(() => _selectedNode = node);
      _restartPingTimer();
    }
  }

  void _onAuthChanged() {
    _loadNodes();
    _loadReferral();
  }

  void _onMeChanged() {
    final url = meNotifier.value?.subscription?.subscriptionUrl ?? '';
    if (url != _lastKnownSubUrl) { _lastKnownSubUrl = url; _loadNodes(); }
  }

  /// Called when another page triggers a global refresh.  Update traffic/subscription
  /// info from the already-refreshed [RemnawaveService.lastSubscriptionInfo] cache.
  void _onGlobalRefresh() {
    if (!mounted) return;
    // Only update the subscription/traffic info from cache — do not touch
    // _isLoadingNodes to avoid conflicting with any in-progress _loadNodes call.
    setState(() {
      _subscriptionInfo = RemnawaveService.lastSubscriptionInfo;
    });
  }

  // ── Init ───────────────────────────────────────────────────────────────────
  Future<void> _init() async {
    // Pre-populate /me from cache so subscription card renders immediately,
    // before any network call completes.
    await MeService.loadFromCache();

    await _v2ray.initializeVless(
      notificationIconResourceType: 'mipmap',
      notificationIconResourceName: 'ic_launcher',
    );
    // Use the same subscription setup as _resubscribeVpnStatus so that
    // _persistTileState is always called on state changes.
    _resubscribeVpnStatus();
    if (mounted) setState(() => _initialized = true);
    _loadNodes();
    _loadReferral();
  }

  // ── Data ───────────────────────────────────────────────────────────────────
  Future<void> _refreshAll() async {
    await MeService.refreshAll();
    await _loadNodes();
  }

  Future<void> _loadNodes() async {
    if (!mounted) return;
    // Guard: if already loading, mark as pending so we run once more after.
    if (_isLoadingNodes) { _pendingLoad = true; return; }
    _pendingLoad = false;
    setState(() {
      _isLoadingNodes = true;
      _loadError = null;
    });
    appLogger.info('HomePage', '_loadNodes: start');
    List<ServerNode> nodes = const [];
    bool isPublic = false;
    String? error;
    try {
      final subUrl = await RemnawaveService.getSubscriptionUrl();
      appLogger.info('HomePage', '_loadNodes: subUrl=${subUrl.isEmpty ? "(empty)" : "set"}');
      if (subUrl.isEmpty) {
        nodes = await RemnawaveService.fetchPublicServers();
        isPublic = true;
      } else {
        nodes = await RemnawaveService.fetchNodes();
        isPublic = false;
      }
      appLogger.info('HomePage',
          '_loadNodes: ok — ${nodes.length} nodes, isPublic=$isPublic, '
          'subscriptionInfo=${RemnawaveService.lastSubscriptionInfo != null}');
    } on Exception catch (e, st) {
      appLogger.error('HomePage', '_loadNodes failed: $e\n$st');
      error = e.toString();
    }
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final savedUuid = prefs.getString('selected_node_uuid');
    setState(() {
      _nodes = nodes;
      _isPublicCatalog = isPublic;
      _subscriptionInfo = isPublic ? null : RemnawaveService.lastSubscriptionInfo;
      _isLoadingNodes = false;
      _loadError = error;
      _loadAttempted = true;
      if (_selectedNode != null) {
        _selectedNode = nodes.cast<ServerNode?>()
            .firstWhere((n) => n?.uuid == _selectedNode!.uuid, orElse: () => null);
      }
      if (_selectedNode == null && savedUuid != null) {
        _selectedNode = nodes.cast<ServerNode?>()
            .firstWhere((n) => n?.uuid == savedUuid, orElse: () => null);
      }
      // Default selection: auto node first, then any non-disabled node.
      if (_selectedNode == null && !isPublic) {
        _selectedNode = nodes.cast<ServerNode?>().firstWhere(
            (n) => n?.protocol == 'auto' && !(n?.isDisabled ?? true),
            orElse: () => null);
        _selectedNode ??= nodes.cast<ServerNode?>().firstWhere(
            (n) => !(n?.isDisabled ?? true),
            orElse: () => null);
      }
      if (_selectedNode != null &&
          selectedServerNotifier.value?.uuid != _selectedNode!.uuid) {
        selectedServerNotifier.value = _selectedNode;
      }
    });
    // Kick off ping right after we've resolved the default selected node, so
    // the signal bars are filled in before the user even touches the picker.
    // Restart unconditionally — if the previous load left a stale timer (e.g.
    // for a node that no longer exists or had no pingable address), the new
    // one will measure against the current selection.
    if (_selectedNode != null) _restartPingTimer();
    // If a load was requested while we were busy, run it now once.
    if (_pendingLoad && mounted) {
      _pendingLoad = false;
      _loadNodes();
    }
  }

  // ── Connection ─────────────────────────────────────────────────────────────
  Future<void> _performLogout() async => AuthService.logout();

  Future<List<String>> _loadBlockedApps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('settings_blocked_apps');
    if (raw != null) {
      try {
        return List<String>.from((jsonDecode(raw) as List).whereType<String>());
      } catch (e) {
        appLogger.error(
          'HomePage',
          'failed to parse blocked apps setting: $e',
        );
      }
    }
    return List<String>.from(AppConfig.defaultBlockedApps);
  }

  static bool _isBypassDescription(String? description) {
    final hay = (description ?? '').toLowerCase();
    return _bypassKeywords.any(hay.contains) ||
        _bypassKeywordCombos.any((combo) => combo.every(hay.contains));
  }

  static bool _isBypassNode(ServerNode node) => _isBypassDescription(node.description);

  Future<bool> _canReachNode(ServerNode node) async {
    final host = node.address.trim();
    if (host.isEmpty) return false;
    // Default to HTTPS port if backend did not provide an explicit one.
    final port = node.serverPort > 0 ? node.serverPort : _defaultServerPort;
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: _nodeReachabilityTimeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasReachableNonBypassServer() async {
    final candidates = _nodes.where((n) =>
        n.protocol != 'auto' &&
        !_isBypassNode(n) &&
        n.link != null &&
        !n.isDisabled).toList();
    if (candidates.any((server) => server.isAvailable)) return true;
    if (candidates.isEmpty) return false;
    for (var i = 0; i < candidates.length; i += _maxReachabilityWorkers) {
      final end = (i + _maxReachabilityWorkers < candidates.length)
          ? i + _maxReachabilityWorkers
          : candidates.length;
      final batch = candidates.sublist(i, end);
      final checks = await Future.wait(batch.map(_canReachNode));
      if (checks.any((ok) => ok)) return true;
    }
    return false;
  }

  Future<void> _toggleConnection() async {
    if (_isTransitioning) return;
    HapticFeedback.heavyImpact();
    if (_isConnected) {
      appLogger.info('HomePage', 'disconnecting from ${_selectedNode?.name ?? "unknown"}');
      await _v2ray.stopVless();
      return;
    }
    final node = _selectedNode;
    if (node == null) { _snack('Сначала выберите сервер'); return; }
    if (node.isDisabled || node.link == null) {
      if (authStateNotifier.value.isLoggedIn) {
        appLogger.info('HomePage', 'blocked server tapped — redirecting to premium');
        widget.onGoToPremium?.call();
      } else {
        await showAuthBottomSheet(context);
      }
      return;
    }
    if (_isBypassNode(node) && await _hasReachableNonBypassServer()) {
      appLogger.info(
        'HomePage',
        'bypass connection blocked: reachable non-bypass server detected',
      );
      _snack('Сервер обхода заблокирован: используйте обычные серверы');
      return;
    }
    if (!await _v2ray.requestPermission()) { _snack('Нет разрешения VPN'); return; }
    setState(() => _isConnecting = true);
    appLogger.info('HomePage', 'connecting to ${node.name} (${node.countryCode})');
    try {
      // Support both full Xray JSON configs (Remnawave JSON-array subscription)
      // and legacy vless:// / vmess:// / trojan:// URI links.
      final rawLink = node.link!.trim();
      final String vpnConfig;
      if (rawLink.startsWith('{')) {
        vpnConfig = rawLink;
      } else {
        vpnConfig = FlutterV2ray.parseFromURL(rawLink).getFullConfiguration();
      }
      appLogger.info('HomePage',
          'connecting: type=${rawLink.startsWith('{') ? 'JSON' : 'URI'} '
          'addr=${node.address}:${node.serverPort}');
      final blockedApps = await _loadBlockedApps();

      await _v2ray.startVless(
        remark: node.name,
        config: vpnConfig,
        blockedApps: blockedApps,
        notificationDisconnectButtonName: 'Отключить',
      );
    } catch (e) {
      appLogger.error('HomePage', 'connection error: $e');
      _snack('Ошибка подключения: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  // ── Server picker helpers ──────────────────────────────────────────────────

  /// Splits nodes into auto/manual and sorts each group.
  /// Manual nodes: primary sort = country code (keeps same-country servers
  /// together), secondary = availability, tertiary = name.
  /// Auto nodes: alphabetical by name.
  ({List<ServerNode> auto, List<ServerNode> manual})
      _splitAndSort(List<ServerNode> nodes) {
    final auto   = nodes.where((n) => n.protocol == 'auto').toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final manual = nodes.where((n) => n.protocol != 'auto').toList()
      ..sort((a, b) {
        // Keep countries grouped — ping is NOT a cross-country key.
        final cc = a.countryCode.compareTo(b.countryCode);
        if (cc != 0) return cc;
        // Within same country: available first, then name.
        final aOk = a.isAvailable ? 0 : 1;
        final bOk = b.isAvailable ? 0 : 1;
        if (aOk != bOk) return aOk.compareTo(bOk);
        return a.name.compareTo(b.name);
      });
    return (auto: auto, manual: manual);
  }

  void _showServerPicker() {
    String? selectedCat;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DS.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        // ── Category detection (Обход / Безлимит) ───────────────────────────
        bool hasBypass = false, hasUnlimited = false;
        for (final n in _nodes) {
          final d = (n.description ?? '').toLowerCase();
          if (d.contains('белые')) hasBypass = true;
          if (d.contains('безлимит')) hasUnlimited = true;
        }
        final showCats = !_isPublicCatalog && (hasBypass || hasUnlimited);

        // Split and sort
        final (:auto, :manual) = _splitAndSort(_nodes);

        // Apply category filter to manual nodes only.
        // Auto-select is hidden while a sub-category filter is active.
        final List<ServerNode> filteredManual;
        if (selectedCat == null) {
          filteredManual = manual;
        } else {
          filteredManual = manual.where((n) {
            final d = (n.description ?? '').toLowerCase();
            if (selectedCat == 'bypass')    return d.contains('белые');
            if (selectedCat == 'unlimited') return d.contains('безлимит');
            return !d.contains('белые') && !d.contains('безлимит');
          }).toList();
        }

        final showAuto = selectedCat == null && auto.isNotEmpty && !_isPublicCatalog;
        // Group manual nodes by country code, preserving the upstream sort
        // order (already alphabetical by CC) so the group sections come out
        // in a stable order.
        final List<({String cc, List<ServerNode> nodes})> manualGroups = [];
        for (final n in filteredManual) {
          final cc = n.countryCode.isEmpty ? '??' : n.countryCode.toUpperCase();
          final existing = manualGroups.where((g) => g.cc == cc).toList();
          if (existing.isEmpty) {
            manualGroups.add((cc: cc, nodes: [n]));
          } else {
            existing.first.nodes.add(n);
          }
        }
        final totalNodes = (showAuto ? auto.length : 0) + filteredManual.length;

        // ── Card-style server tile ──────────────────────────────────────────
        Widget buildTile(ServerNode node, {required bool isAutoNode}) {
          final isSel  = _selectedNode?.uuid == node.uuid;
          final locked = _isPublicCatalog || node.isDisabled || node.link == null;
          final accent = isAutoNode ? DS.indigoLight : DS.violet;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(DS.radiusSm),
                onTap: () async {
                  if (locked) {
                    Navigator.pop(ctx);
                    if (context.mounted) {
                      authStateNotifier.value.isLoggedIn
                          ? widget.onGoToPremium?.call()
                          : await showAuthBottomSheet(context);
                    }
                    return;
                  }
                  HapticFeedback.selectionClick();
                  setState(() => _selectedNode = node);
                  selectedServerNotifier.value = node;
                  final p = await SharedPreferences.getInstance();
                  await p.setString('selected_node_uuid', node.uuid);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                splashColor: accent.withValues(alpha: 0.10),
                highlightColor: accent.withValues(alpha: 0.05),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: isSel
                        ? accent.withValues(alpha: 0.10)
                        : DS.surface2,
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    border: Border.all(
                      color: isSel
                          ? accent.withValues(alpha: 0.55)
                          : DS.border,
                      width: isSel ? 1.5 : 1.0,
                    ),
                  ),
                  child: Row(children: [
                    buildServerIcon(node, width: 36, height: 28, radius: 8),
                    const SizedBox(width: 14),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          node.name,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14.5,
                              color: isSel ? accent : DS.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(children: [
                          if ((node.protocol ?? '').isNotEmpty)
                            Text(
                              isAutoNode
                                  ? 'Авто-выбор'
                                  : node.protocol!.toUpperCase(),
                              style: TextStyle(
                                  color: isAutoNode
                                      ? DS.indigoLight.withValues(alpha: 0.8)
                                      : DS.textMuted,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.4),
                            ),
                          if (locked) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: DS.amber.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(PhosphorIconsBold.lock,
                                      size: 10, color: DS.amber),
                                  const SizedBox(width: 3),
                                  const Text('Подписка',
                                      style: TextStyle(
                                        color: DS.amber,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      )),
                                ],
                              ),
                            ),
                          ],
                        ]),
                      ],
                    )),
                    const SizedBox(width: 8),
                    // Trailing — selected → check pill; locked → lock; else empty.
                    if (isSel)
                      Container(
                        width: 26, height: 26,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(PhosphorIconsBold.check,
                            color: Colors.white, size: 14),
                      )
                    else if (locked)
                      Icon(PhosphorIconsBold.lock,
                          size: 16, color: DS.textMuted),
                  ]),
                ),
              ),
            ),
          );
        }

        // ── Country group header — for manual node sections ─────────────────
        Widget groupHeader(String cc, int count) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(children: [
                buildCountryFlagIcon(cc, width: 22, height: 16, radius: 3),
                const SizedBox(width: 10),
                Text(
                  countryNameForCode(cc),
                  style: const TextStyle(
                    color: DS.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: DS.surface2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: DS.border),
                  ),
                  child: Text('$count',
                      style: const TextStyle(
                          color: DS.textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
            );

        // Auto section header (only when shown)
        Widget autoHeader() => Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
              child: Row(children: [
                Icon(PhosphorIconsFill.lightning,
                    size: 14, color: DS.indigoLight),
                const SizedBox(width: 6),
                const Text('АВТОВЫБОР',
                    style: TextStyle(
                      color: DS.indigoLight,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.3,
                    )),
              ]),
            );

        // Build a flat list of section widgets (header + tiles…).
        final List<Widget> items = [];
        if (showAuto) {
          items.add(autoHeader());
          for (final n in auto) {
            items.add(buildTile(n, isAutoNode: true));
          }
        }
        for (final g in manualGroups) {
          items.add(groupHeader(g.cc, g.nodes.length));
          for (final n in g.nodes) {
            items.add(buildTile(n, isAutoNode: false));
          }
        }

        // ─────────────────────────────────────────────────────────────────────
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          maxChildSize: 0.94,
          minChildSize: 0.4,
          builder: (_, scrollCtrl) => Column(children: [
            const SizedBox(height: 10),
            Container(
              width: 38, height: 4,
              decoration: BoxDecoration(
                  color: DS.border, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 14),

            // Header: title + count badge + refresh
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                const Text('Выбрать сервер',
                    style: TextStyle(
                        color: DS.textPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                if (totalNodes > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: DS.violet.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('$totalNodes',
                        style: const TextStyle(
                            color: DS.violet,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                const Spacer(),
                VpnIconBtn(
                  loading: _isLoadingNodes,
                  icon: PhosphorIconsBold.arrowsClockwise,
                  onTap: () async {
                    setSheet(() {});
                    await _loadNodes();
                    setSheet(() {});
                  },
                ),
              ]),
            ),

            // Public catalog banner
            if (_isPublicCatalog)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: VpnInfoBanner(
                  color: DS.amber,
                  text: 'Публичный каталог. Для подключения нужна подписка.',
                ),
              ),

            // Category filter chips
            if (showCats)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final e in <(String?, String)>[
                      (null, 'Все'),
                      if (hasBypass)    ('bypass', 'Обход'),
                      if (hasUnlimited) ('unlimited', 'Безлимит'),
                      ('other', 'Прочее'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _Chip(
                          label: e.$2,
                          selected: selectedCat == e.$1,
                          onTap: () => setSheet(() => selectedCat = e.$1),
                        ),
                      ),
                  ]),
                ),
              ),

            const SizedBox(height: 8),

            // Server list — sectioned, card-style tiles.
            Expanded(
              child: _nodes.isEmpty
                  ? Center(
                      child: _isLoadingNodes
                          ? const CircularProgressIndicator(color: DS.violet)
                          : const _EmptyNodes())
                  : items.isEmpty
                      ? const Center(
                          child: Text('Нет серверов в этой категории',
                              style:
                                  TextStyle(color: DS.textSecondary)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.only(top: 4, bottom: 20),
                          itemCount: items.length,
                          itemBuilder: (_, i) => items[i],
                        ),
            ),
          ]),
        );
      }),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
  }

  String _fmtDuration(int sec) {
    final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
    if (h > 0) return '$hч ${m.toString().padLeft(2, '0')}м';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Color _progressColor(double f) {
    if (f < 0.6) return DS.emerald;
    if (f < 0.85) return DS.amber;
    return DS.rose;
  }

  static String _formatExpiry(DateTime dt) {
    const months = [
      'янв.', 'фев.', 'мар.', 'апр.', 'мая', 'июн.',
      'июл.', 'авг.', 'сен.', 'окт.', 'ноя.', 'дек.',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  String _remaining(SubscriptionInfo info) {
    if (info.totalBytes <= 0) return '∞';
    final rem = info.totalBytes - info.usedBytes;
    if (rem <= 0) return '0 ГБ';
    return SubscriptionInfo(uploadBytes: 0, downloadBytes: rem, totalBytes: info.totalBytes).formattedUsed;
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: DS.surface0,
        body: Center(child: CircularProgressIndicator(color: DS.violet)),
      );
    }
    return Scaffold(
      backgroundColor: DS.surface0,
      body: RefreshIndicator(
        color: DS.violet,
        backgroundColor: DS.surface2,
        onRefresh: _refreshAll,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  16, MediaQuery.of(context).padding.top + 12, 16, 120),
              sliver: SliverList(delegate: SliverChildListDelegate([
                _buildHeader(),
                const SizedBox(height: 14),
                _buildConnectionCard(),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: _isConnected
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _SpeedCardFlyIn(
                            uploadSpeed: _speedCalc.uploadSpeed,
                            downloadSpeed: _speedCalc.downloadSpeed,
                            uploadTotal: _fmtBytes(_status.upload),
                            downloadTotal: _fmtBytes(_status.download),
                            uploadHist: List<double>.unmodifiable(_uploadHist),
                            downloadHist: List<double>.unmodifiable(_downloadHist),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (_referralInfo != null) ...[
                  _ReferralCard(
                    info: _referralInfo!,
                    copied: _referralCopied,
                    onCopy: _copyReferralCode,
                    onShare: _shareReferral,
                    onOpenDetails: _openReferralPage,
                  ),
                  const SizedBox(height: 12),
                ],
                _buildSubscriptionCard(),
              ])),
            ),
          ],
        ),
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text('Ulya VPN', style: const TextStyle(
            color: DS.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            height: 1,
          )),
        ),
        VpnIconBtn(
          loading: false,
          icon: PhosphorIconsBold.headset,
          onTap: _openSupportPage,
        ),
        const SizedBox(width: 8),
        VpnIconBtn(
          loading: _isLoadingNodes,
          icon: PhosphorIconsBold.arrowsClockwise,
          onTap: _isLoadingNodes ? null : _refreshAll,
        ),
      ],
    );
  }

  void _openSupportPage() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportPage()));
  }

  // ── Connection card ────────────────────────────────────────────────────────
  Widget _buildConnectionCard() {
    final connected = _isConnected;
    final transitioning = _isTransitioning;

    final String statusSub;
    if (connected) {
      statusSub = 'Сессия: ${_fmtDuration(_status.duration)} · IP скрыт';
    } else if (transitioning) {
      statusSub = 'Устанавливаем соединение…';
    } else {
      statusSub = 'Ваш IP виден сайтам';
    }

    final borderColor = connected
        ? DS.emerald.withValues(alpha: 0.38)
        : transitioning
            ? DS.amber.withValues(alpha: 0.28)
            : DS.border;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: borderColor, width: connected ? 1.5 : 1.0),
        boxShadow: connected
            ? [BoxShadow(
                color: DS.emerald.withValues(alpha: 0.12),
                blurRadius: 32, spreadRadius: -4)]
            : [BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DS.radius - 1),
        child: Stack(children: [
          // Decorative rising bubbles — only render while connected.
          if (connected)
            const Positioned.fill(
              child: IgnorePointer(child: _RisingBubbles()),
            ),
          // Card content
          Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(children: [
          // Статус / время сессии
          if (connected)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Сессия: ',
                    style: TextStyle(fontSize: 13, color: DS.textSecondary)),
                _RollingTimer(
                  text: _fmtDuration(_status.duration),
                ),
                const Text(' · IP скрыт',
                    style: TextStyle(fontSize: 13, color: DS.textSecondary)),
              ],
            )
          else
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                key: ValueKey(statusSub),
                statusSub,
                style: const TextStyle(fontSize: 13, color: DS.textSecondary),
              ),
            ),

          const SizedBox(height: 18),

          // Button — no wrapper Stack needed, graph is in the card Stack above
          _ConnectButton(
            isConnected: connected,
            isLoading: transitioning,
            onTap: _toggleConnection,
          ),

          const SizedBox(height: 18),

          // Gradient separator
          Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, DS.border, Colors.transparent],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Server selector OR "Get subscription"/"Sign in" CTA. When the user
          // has no active subscription we replace the selector entirely so they
          // see the blocker immediately rather than discover it on Connect tap.
          _buildServerSlot(),
        ]),
          ),   // Padding
        ]),    // Stack
      ),       // ClipRRect
    );
  }

  // ── Server selector slot (or no-subscription CTA) ────────────────────────
  Widget _buildServerSlot() {
    final authState = authStateNotifier.value;
    final sub = meNotifier.value?.subscription;
    final subExpired = sub?.expireDate?.isBefore(DateTime.now()) ?? false;

    // 1. Not logged in → "Sign in" CTA opening the bottom sheet.
    if (!authState.isLoggedIn) {
      return _AccentSlotCta(
        icon: PhosphorIconsDuotone.signIn,
        title: 'Войдите в аккаунт',
        subtitle: 'Чтобы подключиться к VPN',
        color: DS.telegramBlue,
        onTap: () => showAuthBottomSheet(context),
      );
    }

    // 2. Logged in but no plan / public catalog only → "Get subscription".
    if (_isPublicCatalog) {
      return _AccentSlotCta(
        icon: PhosphorIconsDuotone.crown,
        title: 'Получить подписку',
        subtitle: 'Откройте доступ ко всем серверам',
        color: DS.violet,
        onTap: widget.onGoToPremium ?? () {},
      );
    }

    // 3. Plan expired → "Renew".
    if (subExpired) {
      return _AccentSlotCta(
        icon: PhosphorIconsDuotone.arrowsClockwise,
        title: 'Возобновить подписку',
        subtitle: 'Срок действия истёк',
        color: DS.amber,
        onTap: widget.onGoToPremium ?? () {},
      );
    }

    // 4. Normal: regular server picker row.
    return _buildServerSelectorRow();
  }

  Widget _buildServerSelectorRow() {
    return GestureDetector(
            onTap: _showServerPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: DS.surface2,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(color: DS.border),
              ),
              child: Row(children: [
                buildServerIcon(_selectedNode),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _selectedNode?.name ?? 'Выберите сервер',
                        style: TextStyle(
                          color: _selectedNode != null ? DS.textPrimary : DS.violet,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      if (_selectedNode != null)
                        Text(
                          _selectedNode!.protocol == 'auto'
                              ? (_selectedNode!.description?.isNotEmpty == true
                                  ? _selectedNode!.description!
                                  : 'Авто-выбор сервера')
                              : ((_selectedNode!.protocol ?? '').isNotEmpty
                                  ? _selectedNode!.protocol!.toUpperCase()
                                  : ''),
                          style: TextStyle(
                            color: _selectedNode!.protocol == 'auto'
                                ? DS.indigoLight.withValues(alpha: 0.75)
                                : DS.textSecondary,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                    ],
                  ),
                ),
                if (_selectedNode != null) ...[
                  _SignalBars(
                    pingMs: _pingMs,
                    measuring: _pingMeasuring,
                    isAuto: _selectedNode?.protocol == 'auto',
                  ),
                  const SizedBox(width: 8),
                ],
                const Icon(Icons.chevron_right_rounded, color: DS.textMuted, size: 20),
              ]),
            ),
          );
  }

  // ── Subscription card ──────────────────────────────────────────────────────
  Widget _buildSubscriptionCard() {
    final info      = _subscriptionInfo;
    final authState = authStateNotifier.value;
    final sub       = meNotifier.value?.subscription;

    // Whether the card header is navigable to SubscriptionPage
    final canOpenDetails = authState.isLoggedIn && (info != null || sub != null);

    void openDetails() {
      if (!canOpenDetails) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SubscriptionPage(onGoToPremium: widget.onGoToPremium),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: Row(children: [
            const Text('ПОДПИСКА', style: TextStyle(
              color: DS.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            )),
            const Spacer(),
            if (sub != null) _SubBadge(sub: sub)
            else if (info?.expireDate != null) _ExpiryBadge(expireDate: info!.expireDate!),
          ]),
        ),

        // Body
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // User strip
            if (authState.isLoggedIn) ...[
              _UserStrip(
                name: authState.displayName,
                isEmailAuth: authState.isEmailAuth,
                onLogout: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Выйти из аккаунта?'),
                      content: const Text(
                          'Данные подписки будут удалены с устройства.',
                          style: TextStyle(color: DS.textSecondary)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Отмена')),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Выйти',
                                style: TextStyle(color: DS.rose))),
                      ],
                    ),
                  );
                  if (ok == true && mounted) await _performLogout();
                },
              ),
              const SizedBox(height: 14),
            ],

            // Content
            if (info == null && !_isPublicCatalog) ...[
              if (!authState.isLoggedIn)
                _LoginPrompt()
              else if (sub != null &&
                  (sub.expireDate?.isBefore(DateTime.now()) ?? false)) ...[
                Text(
                  sub.expireDate != null
                      ? 'Истекла ${_formatExpiry(sub.expireDate!)}'
                      : 'Доступ приостановлен',
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 13, height: 1.4),
                ),
                // Renew CTA itself now lives in the connection card slot,
                // so we only keep the explanation text here.
              ] else if (sub != null)
                _loadAttempted && _loadError != null
                    ? _SubLoadError(error: _loadError!, onRetry: _refreshAll)
                    : Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                        SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: DS.textMuted),
                        ),
                        SizedBox(width: 8),
                        Text('Загрузка трафика…',
                            style: TextStyle(color: DS.textSecondary, fontSize: 13)),
                      ])
              else
                _loadAttempted
                    ? _SubLoadError(
                        error: _loadError ?? 'Данные подписки не получены.',
                        onRetry: _refreshAll,
                      )
                    : const Center(
                        child: Text('Загрузка данных…',
                            style: TextStyle(color: DS.textSecondary, fontSize: 13)),
                      ),
            ] else if (_isPublicCatalog && !authState.isLoggedIn)
              _LoginPrompt()
            else if (_isPublicCatalog && authState.isLoggedIn)
              _NoPlanPrompt(onGoToPremium: widget.onGoToPremium)
            else if (info != null) ...[
              if (sub != null &&
                  (sub.expireDate?.isBefore(DateTime.now()) ?? false)) ...[
                Text(
                  sub.expireDate != null
                      ? 'Истекла ${_formatExpiry(sub.expireDate!)}'
                      : 'Доступ приостановлен',
                  style: const TextStyle(
                      color: DS.textSecondary, fontSize: 13, height: 1.4),
                ),
                // Renew CTA itself now lives in the connection card slot,
                // so we only keep the explanation text here.
              ] else if (info.totalBytes <= 0) ...[
                // Безлимитный трафик — особый вид
                _UnlimitedTrafficSection(usedLabel: info.formattedUsed),
              ] else ...[
                // Traffic stats
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(info.formattedUsed, style: const TextStyle(
                        color: DS.textPrimary, fontSize: 28,
                        fontWeight: FontWeight.w800, height: 1)),
                    const SizedBox(width: 6),
                    Text('/ ${info.formattedTotal}',
                        style: const TextStyle(color: DS.textMuted, fontSize: 15)),
                  ],
                ),
                const SizedBox(height: 12),

                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Stack(children: [
                    Container(height: 6, color: DS.surface3),
                    FractionallySizedBox(
                      widthFactor: info.usedFraction.clamp(0.0, 1.0),
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              _progressColor(info.usedFraction),
                              Color.lerp(
                                  _progressColor(info.usedFraction),
                                  Colors.white, 0.22)!,
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          boxShadow: [BoxShadow(
                              color: _progressColor(info.usedFraction)
                                  .withValues(alpha: 0.45),
                              blurRadius: 6)],
                        ),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),

                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Осталось: ${_remaining(info)}',
                      style: const TextStyle(color: DS.textSecondary, fontSize: 12)),
                  Text('${(info.usedFraction * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                          color: _progressColor(info.usedFraction),
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ],
            ],

            const SizedBox(height: 16),
          ]),
        ),

        // ── CTA «Управление подпиской» ───────────────────────────────────────
        if (canOpenDetails) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Material(
              color: DS.surface2,
              borderRadius: BorderRadius.circular(DS.radiusSm),
              child: InkWell(
                onTap: openDetails,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                splashColor: DS.violet.withValues(alpha: 0.12),
                highlightColor: DS.violet.withValues(alpha: 0.06),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DS.radiusSm),
                    border: Border.all(
                        color: DS.violet.withValues(alpha: 0.40), width: 1),
                  ),
                  child: Row(children: [
                    Icon(PhosphorIconsBold.gearSix,
                        size: 18,
                        color: Color.lerp(DS.violet, Colors.white, 0.28)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Управление подпиской',
                              style: TextStyle(
                                color:
                                    Color.lerp(DS.violet, Colors.white, 0.28),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              )),
                          const SizedBox(height: 2),
                          const Text('Тариф, оплата, продление',
                              style: TextStyle(
                                color: DS.textMuted,
                                fontSize: 11.5,
                                height: 1.2,
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded,
                        size: 20,
                        color: DS.violet.withValues(alpha: 0.70)),
                  ]),
                ),
              ),
            ),
          ),
        ] else
          const SizedBox(height: 2),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Local widgets
// ─────────────────────────────────────────────────────────────────────────────

// ── Круглая кнопка подключения ────────────────────────────────────────────────

class _ConnectButton extends StatefulWidget {
  final bool isConnected;
  final bool isLoading;
  final VoidCallback onTap;
  const _ConnectButton({
    required this.isConnected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<_ConnectButton>
    with TickerProviderStateMixin {
  // Icon rotation when loading
  late final AnimationController _spinCtrl;
  // Concentric pulse rings (2.4s, staggered 0/0.8/1.6s) — runs when active.
  late final AnimationController _pulseCtrl;

  bool get _ringsActive => widget.isConnected || widget.isLoading;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (widget.isLoading) _spinCtrl.repeat();
    if (_ringsActive) _pulseCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _ConnectButton old) {
    super.didUpdateWidget(old);
    if (widget.isLoading && !old.isLoading) {
      _spinCtrl.repeat();
    } else if (!widget.isLoading && old.isLoading) {
      _spinCtrl
        ..stop()
        ..reset();
    }
    final wasActive = old.isConnected || old.isLoading;
    if (_ringsActive && !wasActive) {
      _pulseCtrl.repeat();
    } else if (!_ringsActive && wasActive) {
      _pulseCtrl
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Color get _color => widget.isConnected
      ? DS.emerald
      : widget.isLoading
          ? DS.amber
          : DS.violet;


  String get _hint => widget.isConnected
      ? 'Нажмите, чтобы отключить'
      : widget.isLoading
          ? 'Подождите…'
          : 'Нажмите, чтобы подключить';

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 214,
          height: 214,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Pulsing rings — only while connecting/connected.
              if (_ringsActive)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _PulseRings(controller: _pulseCtrl, color: _color),
                  ),
                ),
              AnimatedBuilder(
                animation: _spinCtrl,
                builder: (_, child) {
                  return GestureDetector(
                    onTap: widget.isLoading ? null : widget.onTap,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 350),
                      width: 128,
                      height: 128,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _color,
                        // Single soft glow only — pulse rings carry the rest of
                        // the "alive" feel. The previous hard-spread ring shadow
                        // clashed with the rings, so it's gone.
                        boxShadow: [
                          BoxShadow(
                            color: _color.withValues(alpha: 0.32),
                            blurRadius: 28,
                            spreadRadius: 0,
                          ),
                        ],
                      ),
                      child: widget.isLoading
                          ? RotationTransition(
                              turns: _spinCtrl,
                              child: const Icon(Icons.refresh_rounded,
                                  color: Colors.white, size: 44),
                            )
                          : AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: !widget.isConnected
                                  ? Column(
                                      key: const ValueKey('off'),
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(PhosphorIconsBold.power,
                                            color: Colors.white, size: 38),
                                        const SizedBox(height: 4),
                                        const Text('Отключено',
                                            style: TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            )),
                                      ],
                                    )
                                  : Icon(
                                      key: const ValueKey('on'),
                                      PhosphorIconsFill.shield,
                                      color: Colors.white,
                                      size: 44,
                                    ),
                            ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        // Hero box already carries spacing below the button — small gap is enough.
        const SizedBox(height: 4),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            key: ValueKey(_hint),
            _hint,
            style: const TextStyle(
              color: DS.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Pulsing concentric rings behind the connect button ──────────────────────
// Driven by a single 2.4s repeating controller; each of the three rings is
// phase-offset by 1/3 of the period so they emit in sequence.
class _PulseRings extends StatelessWidget {
  final AnimationController controller;
  final Color color;
  const _PulseRings({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, child) {
        return CustomPaint(
          painter: _PulseRingsPainter(
            t: controller.value,
            color: color,
          ),
        );
      },
    );
  }
}

class _PulseRingsPainter extends CustomPainter {
  _PulseRingsPainter({required this.t, required this.color});
  final double t; // 0..1
  final Color color;

  static const _startRadius = 64.0;   // button radius (128/2)
  static const _endRadius   = 104.0;  // outer edge — fits inside 214px box

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    for (int i = 0; i < 3; i++) {
      // Phase each ring 1/3 apart so emission is sequential.
      double p = (t + i / 3) % 1.0;
      // ease-out: faster at start, slower at end
      final ep = 1 - (1 - p) * (1 - p);
      final radius = _startRadius + (_endRadius - _startRadius) * ep;
      final alpha = (1 - p) * 0.55;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = color.withValues(alpha: alpha);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_PulseRingsPainter old) =>
      old.t != t || old.color != color;
}

// ── Rising bubbles — atmospheric layer behind the connect button ────────────
// 16 dots drifting upward with varied size, colour and cycle duration.
// Mounted/unmounted by the parent based on connection state; the controller
// runs continuously while mounted.
class _RisingBubbles extends StatefulWidget {
  const _RisingBubbles();

  @override
  State<_RisingBubbles> createState() => _RisingBubblesState();
}

class _Bubble {
  final double xPercent;   // 0..1 horizontal position
  final double size;       // diameter in px
  final Color color;
  final double speed;      // cycles per controller period (e.g. 0.7..1.4)
  final double phase;      // 0..1 starting offset
  final double maxAlpha;   // peak opacity
  const _Bubble(this.xPercent, this.size, this.color, this.speed, this.phase, this.maxAlpha);
}

class _RisingBubblesState extends State<_RisingBubbles>
    with SingleTickerProviderStateMixin {
  // Continuously-accumulated time in "rise cycles" (8 s = 1 cycle). Using a
  // raw Ticker (not an AnimationController that loops 0..1) avoids the visible
  // jerk that happens when a controller wraps around: each bubble's
  // `(t * speed + phase) % 1` would jump because `t` itself snaps back to 0.
  // Here `_t` is monotonically increasing, so % 1 produces a smooth sawtooth.
  Ticker? _ticker;
  double _t = 0;
  Duration _lastTick = Duration.zero;
  static const double _cycleSeconds = 8.0;

  late final List<_Bubble> _bubbles;

  @override
  void initState() {
    super.initState();
    // Deterministic-ish but visually scattered.
    final rnd = math.Random(42);
    _bubbles = List.generate(16, (i) {
      final isCyan = rnd.nextBool();
      return _Bubble(
        rnd.nextDouble(),                       // x
        3 + rnd.nextDouble() * 5,               // size 3..8
        isCyan ? DS.cyan : DS.violet,
        0.7 + rnd.nextDouble() * 0.8,           // speed 0.7..1.5
        rnd.nextDouble(),                       // phase
        0.35 + rnd.nextDouble() * 0.45,         // maxAlpha 0.35..0.8
      );
    });
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (dt <= 0) return;
    setState(() => _t += dt / _cycleSeconds);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BubblesPainter(t: _t, bubbles: _bubbles),
    );
  }
}

class _BubblesPainter extends CustomPainter {
  _BubblesPainter({required this.t, required this.bubbles});
  final double t;
  final List<_Bubble> bubbles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in bubbles) {
      final p = (t * b.speed + b.phase) % 1.0;
      // bottom (1) → top (0), so y = size.height * (1 - p)
      final y = size.height * (1 - p) + b.size; // a little overshoot below baseline
      final x = size.width * b.xPercent;
      // Fade-in/out via sin curve: 0 at edges, 1 at middle.
      final alpha = math.sin(p * math.pi) * b.maxAlpha;
      if (alpha <= 0.01) continue;
      final paint = Paint()..color = b.color.withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), b.size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(_BubblesPainter old) => old.t != t;
}

// ─────────────────────────────────────────────────────────────────────────────
// _ReferralCard — invite-friends surface for the Home screen.
// Compact variant of the standalone referral page: code chip, share CTA,
// progress strip ("N друзей · Y₽"). Pulls data from /cabinet/referral.
// ─────────────────────────────────────────────────────────────────────────────
class _ReferralCard extends StatelessWidget {
  final ReferralInfo info;
  final bool copied;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onOpenDetails;

  const _ReferralCard({
    required this.info,
    required this.copied,
    required this.onCopy,
    required this.onShare,
    required this.onOpenDetails,
  });

  String _fmtRubles(double v) {
    if (v == v.roundToDouble()) return '${v.toInt()} ₽';
    return '${v.toStringAsFixed(2)} ₽';
  }

  @override
  Widget build(BuildContext context) {
    final code = info.referralCode.isEmpty ? '—' : info.referralCode;
    final commission = info.commissionPercent;

    return Container(
      decoration: BoxDecoration(
        // Soft brand gradient — sits between the connection card and the
        // subscription card without competing with either.
        gradient: const LinearGradient(
          colors: [Color(0xFF1E1438), Color(0xFF14101F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.violet.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — tap to open the full referral page.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpenDetails,
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: DS.violet.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: DS.violet.withValues(alpha: 0.4)),
                ),
                child: Icon(PhosphorIconsFill.gift,
                    size: 18, color: DS.violet),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Пригласите друзей',
                        style: TextStyle(
                          color: DS.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      commission > 0
                          ? 'Получайте $commission% с каждого их платежа'
                          : 'Делитесь кодом и получайте бонусы',
                      style: const TextStyle(
                        color: DS.textSecondary,
                        fontSize: 11.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: DS.violet.withValues(alpha: 0.7), size: 20),
            ]),
          ),
          const SizedBox(height: 14),

          // Code chip + copy button. Label sits above the code on its own
          // line so long codes don't have to share the row with anything but
          // the copy button — no more right-side overflow.
          Row(children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: DS.surface1,
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  border: Border.all(color: DS.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('ВАШ КОД',
                        style: TextStyle(
                          color: DS.textMuted,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        )),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        code,
                        style: const TextStyle(
                          color: DS.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Copy pill — flips to emerald "Скопировано" briefly on tap.
            GestureDetector(
              onTap: onCopy,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: copied ? DS.emerald : DS.violet,
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  boxShadow: [
                    BoxShadow(
                      color: (copied ? DS.emerald : DS.violet)
                          .withValues(alpha: 0.28),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(children: [
                  Icon(
                    copied ? PhosphorIconsBold.check : PhosphorIconsBold.copy,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    copied ? 'Готово' : 'Копировать',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ]),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Stats strip + share button
          Row(children: [
            Expanded(
              child: Row(children: [
                _ReferralStat(
                  icon: PhosphorIconsFill.users,
                  value: '${info.totalReferrals}',
                  label: info.activeReferrals == info.totalReferrals
                      ? 'друзей'
                      : '${info.activeReferrals} активны',
                ),
                const SizedBox(width: 14),
                _ReferralStat(
                  icon: PhosphorIconsFill.coins,
                  value: _fmtRubles(info.totalEarningsRubles),
                  label: 'заработано',
                ),
              ]),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onShare,
              child: Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: DS.telegramBlue.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  border: Border.all(
                      color: DS.telegramBlue.withValues(alpha: 0.4)),
                ),
                child: Icon(PhosphorIconsDuotone.paperPlaneTilt,
                    color: DS.telegramBlue, size: 18),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _ReferralStat extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  const _ReferralStat({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: DS.textSecondary),
          const SizedBox(width: 5),
          Text(value,
              style: const TextStyle(
                color: DS.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              )),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                color: DS.textMuted,
                fontSize: 11.5,
              )),
        ],
      );
}

class _UserStrip extends StatelessWidget {
  final String name;
  final bool isEmailAuth;
  final VoidCallback onLogout;
  const _UserStrip({
    required this.name,
    required this.isEmailAuth,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final color = isEmailAuth ? DS.violet : DS.telegramBlue;
    final icon = isEmailAuth
        ? PhosphorIconsDuotone.envelopeSimple
        : PhosphorIconsDuotone.paperPlaneTilt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 15),
        const SizedBox(width: 8),
        Expanded(child: Text(name, style: const TextStyle(
            color: DS.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis)),
        GestureDetector(
            onTap: onLogout,
            child: Icon(PhosphorIconsBold.signOut, size: 16, color: DS.textMuted)),
      ]),
    );
  }
}

class _LoginPrompt extends StatelessWidget {
  // The login CTA itself now lives in the connection card; here we keep only
  // the explanation text so the subscription card doesn't echo the same button.
  @override
  Widget build(BuildContext context) => const Text(
        'Войдите в аккаунт, чтобы активировать подписку.',
        style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.5),
      );
}

/// Fallback for the subscription card when /loadNodes finished but no data
/// landed (network down, JWT rejected, empty response). Shows a short
/// human-readable error and a Retry button so the user isn't stuck staring
/// at a spinner that will never resolve.
class _SubLoadError extends StatelessWidget {
  final String error;
  final Future<void> Function() onRetry;
  const _SubLoadError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Keep the visible message short — full exception text goes to the logs
    // (see _loadNodes), not to the UI.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(PhosphorIconsBold.warningCircle,
            size: 18, color: DS.amber),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Не удалось загрузить данные подписки. Проверьте соединение.',
            style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.4),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: DS.violet,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onRetry,
          child: const Text('Обновить',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _NoPlanPrompt extends StatelessWidget {
  // onGoToPremium kept for API stability — the CTA itself now lives in the
  // connection card (see _AccentSlotCta), so the subscription card only
  // explains the state without duplicating the call to action.
  final VoidCallback? onGoToPremium;
  const _NoPlanPrompt({this.onGoToPremium});

  @override
  Widget build(BuildContext context) => const Text(
        'У вас нет активной подписки.',
        style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.5),
      );
}

class _SubBadge extends StatelessWidget {
  final MeSubscription sub;
  const _SubBadge({required this.sub});

  @override
  Widget build(BuildContext context) {
    Color color; String label; IconData icon;
    if (sub.isActive) {
      if (sub.isTrial) {
        color = DS.amber; label = 'Пробный'; icon = Icons.hourglass_top_rounded;
      } else {
        final diff = sub.expireDate?.difference(DateTime.now());
        if (diff != null && diff.inDays < 7 && !diff.isNegative) {
          color = DS.amber; label = '${diff.inDays}д'; icon = Icons.timer_outlined;
        } else {
          // Pick the most informative label available. The backend often
          // returns a human-readable plan name ("Стандартный", "Семейный",
          // "Премиум"…) — prefer it. If the name reads as a free/basic tier
          // we drop the crown so it doesn't look like a paid plan.
          final pn = sub.planName?.trim();
          final pnLow = pn?.toLowerCase() ?? '';
          final isFreeTier = pnLow.contains('беспл') || pnLow.contains('free');
          if (isFreeTier) {
            color = DS.textSecondary;
            label = pn!; // e.g. "Бесплатный"
            icon = PhosphorIconsFill.gift;
          } else {
            color = DS.violet;
            label = (pn != null && pn.isNotEmpty) ? pn : 'Премиум';
            icon = PhosphorIconsFill.crown;
          }
        }
      }
    } else if (sub.isExpired) {
      color = DS.rose; label = 'Истекла'; icon = Icons.timer_off_rounded;
    } else {
      color = DS.textMuted; label = sub.status; icon = Icons.info_outline_rounded;
    }
    return _StatusPill(color: color, label: label, icon: icon);
  }
}

class _ExpiryBadge extends StatelessWidget {
  final DateTime expireDate;
  const _ExpiryBadge({required this.expireDate});

  @override
  Widget build(BuildContext context) {
    final diff = expireDate.difference(DateTime.now());
    final expired = diff.isNegative;
    final soon = !expired && diff.inDays < 7;
    final color = expired ? DS.rose : soon ? DS.amber : DS.violet;
    final label = expired ? 'Истекла' : diff.inDays > 0 ? '${diff.inDays}д' : '< 1д';
    return _StatusPill(
        color: color, label: label,
        icon: expired ? Icons.timer_off_rounded : Icons.timer_outlined);
  }
}

class _StatusPill extends StatelessWidget {
  final Color color; final String label; final IconData icon;
  const _StatusPill({required this.color, required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 12),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
}

// ── Shared micro-widgets ──────────────────────────────────────────────────────

class VpnIconBtn extends StatefulWidget {
  final bool loading;
  final IconData icon;
  final VoidCallback? onTap;
  const VpnIconBtn({super.key, required this.loading, required this.icon, this.onTap});

  @override
  State<VpnIconBtn> createState() => _VpnIconBtnState();
}

class _VpnIconBtnState extends State<VpnIconBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotCtrl;

  @override
  void initState() {
    super.initState();
    _rotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    if (widget.loading) _rotCtrl.repeat();
  }

  @override
  void didUpdateWidget(VpnIconBtn old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _rotCtrl.repeat();
    } else if (!widget.loading && old.loading) {
      final remaining = 1.0 - (_rotCtrl.value % 1.0);
      if (remaining > 0 && remaining < 1.0) {
        _rotCtrl.animateTo(
          _rotCtrl.value + remaining,
          duration: Duration(milliseconds: (remaining * 700).round().clamp(1, 700)),
        ).then((_) { if (mounted) _rotCtrl.reset(); });
      } else {
        _rotCtrl.reset();
      }
    }
  }

  @override
  void dispose() {
    _rotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    child: Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: RotationTransition(
        turns: _rotCtrl,
        child: Icon(widget.icon, color: DS.textSecondary, size: 20),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// _AccentSlotCta — replaces the server-selector row when the user has no
// active subscription / isn't signed in. Bigger CTA so it's immediately
// obvious that tapping connect won't work yet.
// ─────────────────────────────────────────────────────────────────────────────
class _AccentSlotCta extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _AccentSlotCta({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(DS.radiusSm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        splashColor: color.withValues(alpha: 0.18),
        highlightColor: color.withValues(alpha: 0.06),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DS.radiusSm),
            border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
          ),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                        color: Color.lerp(color, Colors.white, 0.35),
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                        color: DS.textMuted,
                        fontSize: 11.5,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: color.withValues(alpha: 0.75), size: 20),
          ]),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? DS.violet.withValues(alpha: 0.15) : DS.surface2,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: selected ? DS.violet : DS.border),
      ),
      child: Text(label, style: TextStyle(
          color: selected ? DS.violet : DS.textSecondary,
          fontSize: 12, fontWeight: FontWeight.w600)),
    ),
  );
}

class VpnInfoBanner extends StatelessWidget {
  final Color color; final String text;
  const VpnInfoBanner({super.key, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(DS.radiusSm),
      border: Border.all(color: color.withValues(alpha: 0.25)),
    ),
    child: Row(children: [
      Icon(Icons.info_outline_rounded, size: 15, color: color.withValues(alpha: 0.85)),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 12))),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// _RollingTimer — таймер сессии с поразрядной анимацией (как флип-клок).
// Каждая цифра анимируется независимо: только изменившиеся цифры «прокручиваются»
// снизу вверх. Разделители «:», «ч», «м» отображаются статично.
// ─────────────────────────────────────────────────────────────────────────────
class _RollingTimer extends StatelessWidget {
  final String text;
  const _RollingTimer({required this.text});

  static const _digitStyle = TextStyle(
    fontSize: 13,
    color: DS.textSecondary,
    fontVariations: [FontVariation('wght', 600)],
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const _sepStyle = TextStyle(
    fontSize: 13,
    color: DS.textMuted,
    fontVariations: [FontVariation('wght', 500)],
  );

  @override
  Widget build(BuildContext context) {
    final chars = text.split('');
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (int i = 0; i < chars.length; i++) _buildChar(chars[i], i),
      ],
    );
  }

  Widget _buildChar(String c, int pos) {
    final isDigit = c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
    if (!isDigit) return Text(c, style: _sepStyle);

    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, anim) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: const Interval(0, 0.6)),
            child: child,
          ),
        ),
        child: Text(
          c,
          key: ValueKey('$pos:$c'),
          style: _digitStyle,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SignalBars — 4-bar Wi-Fi style signal indicator driven by TCP RTT.
// Bar count vs RTT:  ≤50 → 4 · ≤100 → 3 · ≤200 → 2 · >200 → 1 · null → 0 (all dim).
// When [measuring] is true (we have nothing to show yet AND a probe is in
// flight) the bars run a left→right amber scan so the user gets immediate
// feedback after picking a server, instead of staring at four dim stubs.
// ─────────────────────────────────────────────────────────────────────────────
class _SignalBars extends StatefulWidget {
  final int? pingMs;
  final bool measuring;
  /// `true` when the selected node is an auto / balanced host — those don't
  /// have a single address to probe, so we display a "fully healthy" indigo
  /// indicator instead of leaving the bars dim.
  final bool isAuto;
  const _SignalBars({
    required this.pingMs,
    this.measuring = false,
    this.isAuto = false,
  });

  @override
  State<_SignalBars> createState() => _SignalBarsState();
}

class _SignalBarsState extends State<_SignalBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanCtrl;

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.measuring) _scanCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _SignalBars old) {
    super.didUpdateWidget(old);
    if (widget.measuring && !old.measuring) {
      _scanCtrl.repeat();
    } else if (!widget.measuring && old.measuring) {
      _scanCtrl
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    super.dispose();
  }

  // Quality bucketing lives in lib/utils/signal_quality.dart so the home
  // indicator and the ServersPage quality badge agree on bars + colour for
  // the same RTT — otherwise the same server can read 3 bars on one screen
  // and 2 on another.
  SignalQuality get _quality => signalQualityFromPing(widget.pingMs);
  int get _activeBars => _quality.activeBars;
  Color get _color => _quality.color;

  @override
  Widget build(BuildContext context) {
    const heights = [6.0, 9.0, 12.0, 15.0];

    // Auto / balanced host — no single address to probe. Show 4 indigo bars
    // immediately so the indicator never reads as "no signal" for an auto
    // selection (which would be misleading).
    if (widget.isAuto) {
      return SizedBox(
        height: 16,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 4; i++) ...[
              Container(
                width: 3,
                height: heights[i],
                decoration: BoxDecoration(
                  color: DS.indigoLight,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              if (i < 3) const SizedBox(width: 2),
            ],
          ],
        ),
      );
    }

    // Measuring state — animated amber scan across the four bars.
    if (widget.measuring && _activeBars == 0) {
      return SizedBox(
        height: 16,
        child: AnimatedBuilder(
          animation: _scanCtrl,
          builder: (_, child) {
            // Highlight the bar at position floor(t * 4); fades around it.
            final t = _scanCtrl.value * 4;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int i = 0; i < 4; i++) ...[
                  Container(
                    width: 3,
                    height: heights[i],
                    decoration: BoxDecoration(
                      color: DS.amber.withValues(
                          alpha: _scanAlpha(i, t)),
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                  if (i < 3) const SizedBox(width: 2),
                ],
              ],
            );
          },
        ),
      );
    }

    // Static state — colour bars by ping bucket, rest dimmed.
    final active = _activeBars;
    final color = _color;
    return SizedBox(
      height: 16,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < 4; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              width: 3,
              height: heights[i],
              decoration: BoxDecoration(
                color: i < active
                    ? color
                    : DS.textMuted.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
            if (i < 3) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }

  /// Alpha for bar `i` during scan progress `t` ∈ [0, 4). Peaks at 0.85 for
  /// the bar nearest `t`, decays smoothly to ~0.18 for the others.
  double _scanAlpha(int i, double t) {
    final d = (i - t).abs();
    final wrapped = math.min(d, 4 - d); // wrap so scan loops smoothly
    final n = (1 - wrapped / 2).clamp(0.0, 1.0);
    return 0.18 + 0.67 * n;
  }
}

class _EmptyNodes extends StatelessWidget {
  const _EmptyNodes();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off_rounded, size: 40, color: DS.textMuted),
    const SizedBox(height: 10),
    const Text('Серверы не найдены',
        style: TextStyle(color: DS.textSecondary, fontSize: 14)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// _SpeedCardFlyIn — карточка скоростей, прилетающая сверху при подключении
// ─────────────────────────────────────────────────────────────────────────────
class _SpeedCardFlyIn extends StatefulWidget {
  final double uploadSpeed;
  final double downloadSpeed;
  final String uploadTotal;
  final String downloadTotal;
  final List<double> uploadHist;
  final List<double> downloadHist;

  const _SpeedCardFlyIn({
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.uploadTotal,
    required this.downloadTotal,
    required this.uploadHist,
    required this.downloadHist,
  });

  @override
  State<_SpeedCardFlyIn> createState() => _SpeedCardFlyInState();
}

class _SpeedCardFlyInState extends State<_SpeedCardFlyIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 520));
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.8),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _fade = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.55)));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: DS.surface1,
            borderRadius: BorderRadius.circular(DS.radiusSm),
            border: Border.all(color: DS.border),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Expanded(child: _SpeedTile(
                  icon: PhosphorIconsBold.arrowFatLineDown,
                  color: DS.cyan,
                  label: 'Загрузка',
                  speed: widget.downloadSpeed,
                  total: widget.downloadTotal,
                  hist: widget.downloadHist,
                )),
                Container(width: 1, color: DS.border),
                Expanded(child: _SpeedTile(
                  icon: PhosphorIconsBold.arrowFatLineUp,
                  color: DS.violet,
                  label: 'Отдача',
                  speed: widget.uploadSpeed,
                  total: widget.uploadTotal,
                  hist: widget.uploadHist,
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeedTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final double speed;
  final String total;
  final Color color;
  final List<double> hist;

  const _SpeedTile({
    required this.icon, required this.label,
    required this.speed, required this.total, required this.color,
    required this.hist,
  });

  String _fmt(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: color, size: 13),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: DS.textSecondary, fontSize: 11)),
    ]),
    const SizedBox(height: 6),
    TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: speed),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Text(_fmt(v), style: TextStyle(
          color: color, fontSize: 18,
          fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    ),
    const SizedBox(height: 6),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: _Sparkline(values: hist, color: color),
    ),
    const SizedBox(height: 5),
    Text(total, style: const TextStyle(color: DS.textMuted, fontSize: 11)),
  ]);
}

// ── _Sparkline — 18-bar histogram of the most recent speed samples ──────────
// Length-aligned to the right: empty slots stay zero-height until the buffer
// fills up. Bars use the tile's accent colour with a subtle gradient.
class _Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  const _Sparkline({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    const len = _HomePageState._sparkLen;
    // Pad on the left so newest bar is right-aligned.
    final padded = List<double>.filled(len, 0.0);
    final start = len - values.length;
    for (int i = 0; i < values.length; i++) {
      if (start + i >= 0) padded[start + i] = values[i];
    }
    final maxV = padded.fold<double>(1.0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < len; i++) ...[
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: 0,
                  end: (padded[i] / maxV).clamp(0.05, 1.0),
                ),
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                builder: (_, frac, child) => FractionallySizedBox(
                  heightFactor: frac,
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [color, color.withValues(alpha: 0.4)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                ),
              ),
            ),
            if (i < len - 1) const SizedBox(width: 2),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _UnlimitedTrafficSection — блок для безлимитного трафика
// ─────────────────────────────────────────────────────────────────────────────
class _UnlimitedTrafficSection extends StatelessWidget {
  final String usedLabel;
  const _UnlimitedTrafficSection({required this.usedLabel});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Иконка-плашка
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: DS.cyan.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: DS.cyan.withValues(alpha: 0.22),
                    blurRadius: 14,
                    spreadRadius: -3,
                  ),
                ],
              ),
              child: Icon(PhosphorIconsBold.infinity,
                  size: 22, color: DS.cyan),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Безлимитный трафик',
                  style: TextStyle(
                    color: DS.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'использовано $usedLabel',
                  style: const TextStyle(
                    color: DS.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

