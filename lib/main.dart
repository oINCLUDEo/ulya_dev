import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/app_config.dart';
import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/premium_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';
import 'services/auth_state.dart';
import 'services/favorites_state.dart';
import 'services/launch_action_service.dart';
import 'services/me_service.dart';
import 'services/network_monitor.dart';
import 'services/notification_service.dart';
import 'services/ping_state.dart';
import 'services/remote_config_service.dart';
import 'widgets/notification_banner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Global Design System tokens — imported by all pages
// ─────────────────────────────────────────────────────────────────────────────

class DS {
  DS._();

  // ── Accent ────────────────────────────────────────────────────────────────
  static const violet        = Color(0xFF7C6BFF);   // accent/primary
  static const violetDim     = Color(0xFF5B4DE0);   // accent/hover / pressed
  static const violetGlow    = Color(0x337C6BFF);
  static const indigoLight   = Color(0xFF818CF8);   // auto-server / virtual host
  static const cyan          = Color(0xFF22D3EE);   // vless protocol / unlimited group
  static const orchid        = Color(0xFFF0ABFC);   // tuic protocol
  static const gold          = Color(0xFFD4A84B);   // premium membership active
  static const goldDim       = Color(0xFFB8922E);
  static const telegramBlue  = Color(0xFF3FA9F5);   // accent/telegram

  // ── Semantic ──────────────────────────────────────────────────────────────
  static const emerald       = Color(0xFF1DC97A);   // success / connected
  static const amber         = Color(0xFFFAB432);   // warning / connecting
  static const rose          = Color(0xFFE24B4A);   // danger / error

  // ── Surfaces ──────────────────────────────────────────────────────────────
  // Blue-violet tinted rather than neutral grey: the tint is part of the
  // brand, and a flat grey card next to a violet accent reads as unfinished.
  // (These values came from the premium/renew/tariff screens, which had
  // evolved their own tinted palette; the whole app now shares it.)
  static const surface0 = Color(0xFF0A0A0F);   // bg/base
  static const surface1 = Color(0xFF111124);   // bg/surface  (cards)
  static const surface2 = Color(0xFF1F1F2C);   // bg/elevated (modals, popups)
  static const surface3 = Color(0xFF2A2A38);   // disabled bg

  // ── Text ──────────────────────────────────────────────────────────────────
  static const textPrimary   = Color(0xFFF0F0FF);   // text/primary
  static const textSecondary = Color(0xFF8892AA);   // text/secondary
  static const textMuted     = Color(0xFF6B6B8A);   // text/tertiary

  /// Decorative micro-labels ONLY — section captions, disclaimers, the kind
  /// of 10-11px text that frames content rather than carrying it. Sits at
  /// roughly 2:1 against [surface0], well under the 4.5:1 body-text bar, so
  /// never use it for anything the user actually has to read. Use
  /// [textMuted] (~3.9:1) for genuine tertiary content.
  static const textFaint     = Color(0xFF454565);

  // ── Border ────────────────────────────────────────────────────────────────
  static const border    = Color(0xFF1E1E38);   // card border
  static const borderDim = Color(0xFF16162E);   // deep divider inside cards

  // ── Radii ─────────────────────────────────────────────────────────────────
  static const radius   = 20.0;   // lg — buttons, large cards
  static const radiusSm = 12.0;   // md — cards
  static const radiusXs = 4.0;    // sm — badges

  // ── Accent surface formula ────────────────────────────────────────────────
  // The tint recipe behind every "tier 1" surface — see AccentCard in
  // lib/widgets/accent_surface.dart for the hierarchy rules. Exposed as
  // helpers (rather than only via the widget) for the cases that need the
  // decoration alone, e.g. an AnimatedContainer that tweens between states.

  /// Vertical accent wash: strongest at the top, almost gone at the bottom.
  static LinearGradient accentGradient(Color accent) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0.12),
          accent.withValues(alpha: 0.04),
        ],
      );

  /// Border tint that pairs with [accentGradient] — visible enough to read as
  /// deliberate, dim enough not to look like a focus ring.
  static Color accentBorderColor(Color accent) =>
      accent.withValues(alpha: 0.30);
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  // Crash reporting is opt-in via AppConfig.sentryDsn — with an empty DSN the
  // SDK is never initialised and the app boots exactly as before.
  if (AppConfig.sentryDsn.isNotEmpty) {
    await SentryFlutter.init(
      (options) async {
        options.dsn = AppConfig.sentryDsn;
        // VPN app: never attach user IPs or PII to crash events.
        options.sendDefaultPii = false;
        options.tracesSampleRate = 0.1;
        options.attachScreenshot = false;
        // Release Health (crash-free sessions/users) is broken down by
        // `release` — tag it with the actual installed build so a bad
        // version shows up distinctly from previous ones.
        try {
          final info = await PackageInfo.fromPlatform();
          options.release = 'ulya-vpn@${info.version}+${info.buildNumber}';
        } catch (_) {
          // Release tagging is a nice-to-have — never block Sentry init on it.
        }
      },
      appRunner: _boot,
    );
  } else {
    await _boot();
  }
}

/// Sends [error] to Sentry when crash reporting is enabled. No-op otherwise.
void _reportCrash(Object error, StackTrace? stack) {
  if (AppConfig.sentryDsn.isEmpty) return;
  unawaited(Sentry.captureException(error, stackTrace: stack));
}

// ─────────────────────────────────────────────────────────────────────────────
// AppLogger → Sentry breadcrumb bridge
//
// Forwards every info/warning/error entry (debug is too chatty — VPN traffic
// ticks alone would be one per second) into Sentry as a breadcrumb. When a
// crash or a captured error happens, the report then carries the preceding
// Payment/HomePage/etc. trail for free — e.g. "buyTariff: start … HTTP 500"
// right before the exception that triggered the report.
// ─────────────────────────────────────────────────────────────────────────────

int _sentryBridgeLastIndex = 0;

void _bridgeLogsToSentry() {
  final logs = appLogger.logsNotifier.value;
  if (_sentryBridgeLastIndex > logs.length) _sentryBridgeLastIndex = 0; // cleared
  for (var i = _sentryBridgeLastIndex; i < logs.length; i++) {
    final e = logs[i];
    if (e.level == AppLogLevel.debug) continue;
    unawaited(Sentry.addBreadcrumb(Breadcrumb(
      message: e.message,
      category: e.source,
      level: _sentryLevelFor(e.level),
      timestamp: e.timestamp.toUtc(),
    )));
  }
  _sentryBridgeLastIndex = logs.length;
}

SentryLevel _sentryLevelFor(AppLogLevel level) {
  switch (level) {
    case AppLogLevel.debug:   return SentryLevel.debug;
    case AppLogLevel.info:    return SentryLevel.info;
    case AppLogLevel.warning: return SentryLevel.warning;
    case AppLogLevel.error:   return SentryLevel.error;
  }
}

const String _kMaintenanceNotifId = 'remote_maintenance';

/// Mirrors the remote maintenance flag into the existing in-app notification
/// pipeline — reuses the persistent-banner UI instead of a bespoke screen.
void _syncMaintenanceBanner() {
  final cfg = RemoteConfigService.notifier.value;
  if (cfg != null && cfg.maintenanceEnabled) {
    notificationService.post(InAppNotification(
      id: _kMaintenanceNotifId,
      title: 'Технические работы',
      body: cfg.maintenanceMessage,
      type: InAppNotifType.persistent,
      severity: InAppNotifSeverity.warning,
    ));
  } else {
    notificationService.dismiss(_kMaintenanceNotifId);
  }
}

Future<void> _boot() async {
  // Catch synchronous errors during boot so the crash trail lands in the
  // log file before the process dies.
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    await appLogger.loadFromDisk();
    appLogger.info('App', '── boot start (build ${DateTime.now()})');
    await appLogger.flush();

    try {
      await notificationService.init();
      appLogger.info('App', 'notifications: ok');
    } catch (e, st) {
      appLogger.error('App', 'notifications init failed: $e\n$st');
    }

    // Wire the log→breadcrumb bridge before anything else logs, so no early
    // boot events (auth, cache loads) are missed. No-op cost when Sentry was
    // never initialised (empty DSN).
    if (AppConfig.sentryDsn.isNotEmpty) {
      appLogger.logsNotifier.addListener(_bridgeLogsToSentry);
    }

    try {
      await loadAuthState();
      appLogger.info('App',
          'auth: loaded — loggedIn=${authStateNotifier.value.isLoggedIn} '
          'tg=${authStateNotifier.value.telegramId != null} '
          'jwt=${authStateNotifier.value.cabinetAccessToken != null}');
    } catch (e, st) {
      appLogger.error('App', 'loadAuthState failed: $e\n$st');
    }

    try {
      await loadFavorites();
    } catch (e, st) {
      appLogger.error('App', 'loadFavorites failed: $e\n$st');
    }

    try {
      await PingState.loadFromDisk();
      appLogger.info('App',
          'ping cache: loaded ${PingState.notifier.value.length} entries');
    } catch (e, st) {
      appLogger.error('App', 'PingState.loadFromDisk failed: $e\n$st');
    }

    try {
      // Restore cached /me so pages never flash an empty state on first render.
      await MeService.loadFromCache();
      appLogger.info('App', 'me cache: ok');
    } catch (e, st) {
      appLogger.error('App', 'MeService.loadFromCache failed: $e\n$st');
    }

    // Remote config (min version / force update / maintenance / default
    // blocked-apps list) — cache read is instant, the network refresh runs in
    // the background so it never delays first paint.
    RemoteConfigService.notifier.addListener(_syncMaintenanceBanner);
    unawaited(RemoteConfigService.load());

    // Watch for Wi-Fi ↔ LTE switches so pages can re-probe immediately.
    NetworkMonitor.start();
    // Launcher shortcut / QS tile action (if the app was opened through one).
    await LaunchActionService.poll();

    // Background refresh — does NOT block startup.
    MeService.refresh();
    // Check whether to show onboarding on first launch.
    final showOnboarding = await shouldShowOnboarding();
    appLogger.info('App',
        'boot done — showOnboarding=$showOnboarding, launching UI');
    await appLogger.flush();

    // Surface Flutter-framework errors into the app log and Sentry.
    FlutterError.onError = (FlutterErrorDetails details) {
      appLogger.error(
        'FlutterError',
        '${details.exceptionAsString()}\n${details.stack ?? ""}',
      );
      _reportCrash(details.exception, details.stack);
      FlutterError.presentError(details);
    };

    runApp(UlyaVpnApp(showOnboarding: showOnboarding));
  }, (error, stack) {
    appLogger.error('App', 'Uncaught zone error: $error\n$stack');
    _reportCrash(error, stack);
    appLogger.flush();
  });
}

class UlyaVpnApp extends StatelessWidget {
  const UlyaVpnApp({super.key, this.showOnboarding = false});

  final bool showOnboarding;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ulya VPN',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: _ForceUpdateGate(
        child: showOnboarding
            ? const OnboardingPage()
            : const InAppNotificationOverlay(child: MainShell()),
      ),
    );
  }

  ThemeData _buildTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: const ColorScheme.dark(
      primary: DS.violet,
      secondary: DS.emerald,
      surface: DS.surface1,
      onSurface: DS.textPrimary,
    ),
    scaffoldBackgroundColor: DS.surface0,
    cardTheme: CardThemeData(
      color: DS.surface1,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radius),
        side: const BorderSide(color: DS.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: DS.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radius)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
      s.contains(WidgetState.selected) ? DS.violet : DS.textMuted),
      trackColor: WidgetStateProperty.resolveWith((s) =>
      s.contains(WidgetState.selected)
          ? DS.violet.withValues(alpha: 0.28)
          : DS.surface3),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
      s.contains(WidgetState.selected) ? DS.violet : Colors.transparent),
      checkColor: WidgetStateProperty.all(Colors.white),
      side: const BorderSide(color: DS.border, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) =>
      s.contains(WidgetState.selected) ? DS.violet : DS.textMuted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DS.surface2,
      hintStyle: const TextStyle(color: DS.textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.violet, width: 1.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: DS.surface2,
      labelStyle: const TextStyle(color: DS.textSecondary, fontSize: 11),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DS.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: DS.violet),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: DS.violet,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusSm)),
      ),
    ),
    dividerColor: DS.border,
    dividerTheme: const DividerThemeData(color: DS.border, thickness: 1, space: 1),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: DS.textPrimary),
      bodySmall: TextStyle(color: DS.textSecondary),
      titleMedium: TextStyle(color: DS.textPrimary, fontWeight: FontWeight.w600),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: DS.surface2,
      contentTextStyle: const TextStyle(color: DS.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        side: const BorderSide(color: DS.border),
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main shell — 3 tabs: Home / Servers / Settings
// ─────────────────────────────────────────────────────────────────────────────

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  // Quick fade-through when switching tabs (IndexedStack keeps every page alive,
  // so this just animates the swap, not a rebuild).
  late final AnimationController _tabFade;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    LaunchActionService.pending.addListener(_onLaunchAction);
    _onLaunchAction();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabFade.dispose();
    LaunchActionService.pending.removeListener(_onLaunchAction);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The QS tile / shortcut can fire while the app is alive in background —
    // re-poll the platform side on every return to foreground.
    if (state == AppLifecycleState.resumed) LaunchActionService.poll();
  }

  void _onLaunchAction() {
    // "toggle" is consumed by HomePage itself; the shell only handles tab
    // navigation actions.
    if (LaunchActionService.consume('servers')) _go(1);
  }

  void _goToPremium() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PremiumPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(onGoToPremium: _goToPremium),
      ServersPage(
        onGoToHome: () => _go(0),
        onGoToSettings: () => _go(2),
        onGoToPremium: _goToPremium,
      ),
      const SettingsPage(),
    ];

    return Scaffold(
      extendBody: true,
      backgroundColor: DS.surface0,
      body: FadeTransition(
        opacity: _tabFade,
        child: AnimatedBuilder(
          animation: _tabFade,
          builder: (context, child) => Transform.translate(
            // Subtle 10px rise as the new tab fades in.
            offset: Offset(0, (1 - _tabFade.value) * 10),
            child: child,
          ),
          child: IndexedStack(index: _currentIndex, children: pages),
        ),
      ),
      bottomNavigationBar: _NavBarContainer(
        currentIndex: _currentIndex,
        onTabSelected: _go,
      ),
    );
  }

  void _go(int i) {
    if (i == _currentIndex) return;
    setState(() => _currentIndex = i);
    _tabFade.forward(from: 0);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Nav bar container (fog + glass pill)
// ─────────────────────────────────────────────────────────────────────────────

class _NavBarContainer extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  const _NavBarContainer({
    required this.currentIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        Positioned(
          bottom: 0, left: 0, right: 0,
          height: 120 + MediaQuery.viewPaddingOf(context).bottom,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    DS.surface0,
                    DS.surface0.withValues(alpha: 0.80),
                    DS.surface0.withValues(alpha: 0.32),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.30, 0.62, 1.0],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16, 0, 16,
            14 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: _GlassNavBar(
            currentIndex: currentIndex,
            onTabSelected: onTabSelected,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Glass nav bar pill — 3 items
// ─────────────────────────────────────────────────────────────────────────────

class _GlassNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  const _GlassNavBar({
    required this.currentIndex,
    required this.onTabSelected,
  });

  // Phosphor: regular weight for inactive, fill for the selected tab — matches
  // the duotone-ish aesthetic without crossing into the full duotone variant.
  static final _items = <({IconData icon, IconData activeIcon, String label})>[
    (icon: PhosphorIconsRegular.house,
        activeIcon: PhosphorIconsFill.house,
        label: 'Главная'),
    (icon: PhosphorIconsRegular.globeHemisphereWest,
        activeIcon: PhosphorIconsFill.globeHemisphereWest,
        label: 'Сервера'),
    (icon: PhosphorIconsRegular.gearSix,
        activeIcon: PhosphorIconsFill.gearSix,
        label: 'Настройки'),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: DS.surface1.withValues(alpha: 0.92),
            border: Border.all(color: DS.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.40),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              for (int i = 0; i < _items.length; i++)
                _NavItem(
                  icon: _items[i].icon,
                  activeIcon: _items[i].activeIcon,
                  label: _items[i].label,
                  selected: currentIndex == i,
                  onTap: () => onTabSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Nav item — uniform for all 3 tabs
// ─────────────────────────────────────────────────────────────────────────────

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      lowerBound: 1.0,
      upperBound: 1.08,
      value: widget.selected ? 1.08 : 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant _NavItem old) {
    super.didUpdateWidget(old);
    widget.selected ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, child) => Transform.scale(scale: _ctrl.value, child: child),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  key: ValueKey(widget.selected),
                  widget.selected ? widget.activeIcon : widget.icon,
                  size: 24,
                  color: widget.selected ? DS.violet : DS.textMuted,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: widget.selected ? DS.violet : DS.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Forced-update gate — blocks the whole app when the admin has raised
// RemoteConfig.minSupportedBuild above the running build number and enabled
// force_update. Fails open (shows [child]) whenever config isn't loaded yet,
// the fetch failed, or PackageInfo can't be read — a broken remote config
// must never lock users out of a VPN app.
// ─────────────────────────────────────────────────────────────────────────────

class _ForceUpdateGate extends StatefulWidget {
  final Widget child;
  const _ForceUpdateGate({required this.child});

  @override
  State<_ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<_ForceUpdateGate> {
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    RemoteConfigService.notifier.addListener(_recheck);
    _recheck();
  }

  @override
  void dispose() {
    RemoteConfigService.notifier.removeListener(_recheck);
    super.dispose();
  }

  Future<void> _recheck() async {
    final blocked = await RemoteConfigService.needsForceUpdate();
    if (mounted && blocked != _blocked) setState(() => _blocked = blocked);
  }

  @override
  Widget build(BuildContext context) {
    if (!_blocked) return widget.child;
    return _ForceUpdateScreen(
      updateUrl: RemoteConfigService.notifier.value?.updateUrl,
    );
  }
}

class _ForceUpdateScreen extends StatelessWidget {
  final String? updateUrl;
  const _ForceUpdateScreen({this.updateUrl});

  Future<void> _openStore() async {
    final url = updateUrl;
    if (url == null || url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DS.surface0,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: DS.violet.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.system_update_rounded,
                      color: DS.violet, size: 34),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Нужно обновление',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Вышла новая версия приложения. Обновите его, чтобы продолжить пользоваться VPN.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: DS.textSecondary, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    backgroundColor: DS.violet,
                  ),
                  onPressed: (updateUrl == null || updateUrl!.isEmpty) ? null : _openStore,
                  child: const Text('Обновить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
