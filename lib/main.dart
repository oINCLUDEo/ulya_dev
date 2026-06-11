import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pages/home_page.dart';
import 'pages/onboarding_page.dart';
import 'pages/premium_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'services/app_logger.dart';
import 'services/auth_state.dart';
import 'services/favorites_state.dart';
import 'services/me_service.dart';
import 'services/notification_service.dart';
import 'services/ping_state.dart';
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
  static const surface0 = Color(0xFF0A0A0F);   // bg/base
  static const surface1 = Color(0xFF16161F);   // bg/surface  (cards)
  static const surface2 = Color(0xFF1F1F2C);   // bg/elevated (modals, popups)
  static const surface3 = Color(0xFF2A2A38);   // disabled bg

  // ── Text ──────────────────────────────────────────────────────────────────
  static const textPrimary   = Color(0xFFFFFFFF);   // text/primary
  static const textSecondary = Color(0xFFA8A8B8);   // text/secondary
  static const textMuted     = Color(0xFF6B6B7D);   // text/tertiary

  // ── Border ────────────────────────────────────────────────────────────────
  static const border = Color(0xFF2E2E40);

  // ── Radii ─────────────────────────────────────────────────────────────────
  static const radius   = 20.0;   // lg — buttons, large cards
  static const radiusSm = 12.0;   // md — cards
  static const radiusXs = 4.0;    // sm — badges
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
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

    // Background refresh — does NOT block startup.
    MeService.refresh();
    // Check whether to show onboarding on first launch.
    final showOnboarding = await shouldShowOnboarding();
    appLogger.info('App',
        'boot done — showOnboarding=$showOnboarding, launching UI');
    await appLogger.flush();

    // Surface Flutter-framework errors into the app log too.
    FlutterError.onError = (FlutterErrorDetails details) {
      appLogger.error(
        'FlutterError',
        '${details.exceptionAsString()}\n${details.stack ?? ""}',
      );
      FlutterError.presentError(details);
    };

    runApp(UlyaVpnApp(showOnboarding: showOnboarding));
  }, (error, stack) {
    appLogger.error('App', 'Uncaught zone error: $error\n$stack');
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
      home: showOnboarding
          ? const OnboardingPage()
          : const InAppNotificationOverlay(child: MainShell()),
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

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

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
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: _NavBarContainer(
        currentIndex: _currentIndex,
        onTabSelected: _go,
      ),
    );
  }

  void _go(int i) => setState(() => _currentIndex = i);
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
        label: 'Серверы'),
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
