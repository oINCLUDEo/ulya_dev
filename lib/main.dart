import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pages/home_page.dart';
import 'pages/premium_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscription_page.dart';
import 'services/app_logger.dart';
import 'services/auth_state.dart';
import 'services/me_service.dart';
import 'services/notification_service.dart';
import 'widgets/notification_banner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Global Design System tokens — imported by all pages
// ─────────────────────────────────────────────────────────────────────────────

class DS {
  DS._();

  // Accent
  static const violet        = Color(0xFF7C6FF7);
  static const violetDim     = Color(0xFF4A44AA);
  static const violetGlow    = Color(0x337C6FF7);
  static const emerald       = Color(0xFF34D399);
  static const amber         = Color(0xFFFBBF24);
  static const rose          = Color(0xFFF87171);
  static const telegramBlue  = Color(0xFF229ED9);

  // Surfaces
  static const surface0 = Color(0xFF0F0F14);
  static const surface1 = Color(0xFF17171F);
  static const surface2 = Color(0xFF1E1E2A);
  static const surface3 = Color(0xFF26263A);

  // Text
  static const textPrimary   = Color(0xFFEEEEF8);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted     = Color(0xFF55556A);

  // Border
  static const border = Color(0xFF2A2A3D);

  // Radii
  static const radius   = 20.0;
  static const radiusSm = 12.0;
  static const radiusXs = 8.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry
// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await appLogger.loadFromDisk();
  await notificationService.init();
  appLogger.info('App', 'Application started');
  await loadAuthState();
  MeService.refresh();
  runApp(const UlyaVpnApp());
}

class UlyaVpnApp extends StatelessWidget {
  const UlyaVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ulya VPN',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const InAppNotificationOverlay(child: MainShell()),
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
// Main shell
// ─────────────────────────────────────────────────────────────────────────────

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 2;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ServersPage(
        onGoToHome: () => _go(2),
        onGoToSettings: () => _go(4),
        onGoToPremium: () => _go(3),
      ),
      SubscriptionPage(onGoToPremium: () => _go(3)),
      HomePage(onGoToPremium: () => _go(3)),
      const PremiumPage(),
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
        // Gradient fog so content scrolls under gracefully
        Positioned(
          bottom: 0, left: 0, right: 0, height: 130,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    DS.surface0,
                    DS.surface0.withValues(alpha: 0.82),
                    DS.surface0.withValues(alpha: 0.38),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.28, 0.58, 1.0],
                ),
              ),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
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
// Glass nav bar pill
// ─────────────────────────────────────────────────────────────────────────────

class _GlassNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTabSelected;

  const _GlassNavBar({
    required this.currentIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: DS.surface1.withValues(alpha: 0.90),
            border: Border.all(color: DS.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 32,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              _NavItem(
                icon: Icons.dns_outlined,
                activeIcon: Icons.dns_rounded,
                label: 'Серверы',
                selected: currentIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              _NavItem(
                icon: Icons.card_membership_outlined,
                activeIcon: Icons.card_membership_rounded,
                label: 'Подписка',
                selected: currentIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              _HomeNavItem(
                selected: currentIndex == 2,
                onTap: () => onTabSelected(2),
              ),
              _NavItem(
                icon: Icons.workspace_premium_outlined,
                activeIcon: Icons.workspace_premium_rounded,
                label: 'Premium',
                selected: currentIndex == 3,
                onTap: () => onTabSelected(3),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: 'Настройки',
                selected: currentIndex == 4,
                onTap: () => onTabSelected(4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Center home button
// ─────────────────────────────────────────────────────────────────────────────

class _HomeNavItem extends StatefulWidget {
  final bool selected;
  final VoidCallback onTap;
  const _HomeNavItem({required this.selected, required this.onTap});

  @override
  State<_HomeNavItem> createState() => _HomeNavItemState();
}

class _HomeNavItemState extends State<_HomeNavItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      lowerBound: 0.88,
      upperBound: 1.0,
      value: widget.selected ? 1.0 : 0.88,
    );
  }

  @override
  void didUpdateWidget(covariant _HomeNavItem old) {
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
              // Glowing circle button
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: widget.selected
                        ? [DS.violet, DS.violetDim]
                        : [DS.surface2, DS.surface3],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: widget.selected
                        ? DS.violet.withValues(alpha: 0.6)
                        : DS.border,
                  ),
                  boxShadow: widget.selected
                      ? [BoxShadow(
                    color: DS.violet.withValues(alpha: 0.40),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  )]
                      : [],
                ),
                child: Icon(
                  widget.selected ? Icons.home_rounded : Icons.home_outlined,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Главная',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: widget.selected ? DS.textPrimary : DS.textMuted,
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
// Regular nav item
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
              Icon(
                widget.selected ? widget.activeIcon : widget.icon,
                size: 22,
                color: widget.selected ? DS.violet : DS.textMuted,
              ),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: widget.selected ? DS.textPrimary : DS.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}