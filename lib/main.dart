import 'dart:ui';

import 'package:dev_vpn/theme/app_colors.dart';
import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/premium_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'pages/subscription_page.dart';
import 'services/auth_state.dart';
import 'services/me_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore previous auth session (if any) before rendering.
  await loadAuthState();
  // Pre-fetch /me data if already logged in.
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
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF6C5CE7),
          secondary: const Color(0xFF00D9FF),
          surface: const Color(0xFF1A1A2E),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: AppColors.neutralBackground,
        cardTheme: CardThemeData(
          color: const Color(0xFF1A1A2E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        fontFamily: 'Roboto',
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  // Home is index 2 (center)
  int _currentIndex = 2;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ServersPage(
        onGoToHome: () => setState(() => _currentIndex = 2),
        onGoToSettings: () => setState(() => _currentIndex = 4),
      ),
      const SubscriptionPage(),
      const HomePage(),
      const PremiumPage(),
      const SettingsPage(),
    ];

    return Scaffold(
      extendBody: true,
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // Легкий туман под меню
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 120, // растягиваем градиент выше для плавности
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      const Color(0xFF171A21).withOpacity(1), // чуть заметная плотность
                      const Color(0xFF171A21).withOpacity(0.5),
                      const Color(0xFF171A21).withOpacity(0.04), // почти прозрачный
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.3, 0.6, 1.0], // плавное уменьшение эффекта
                  ),
                ),
              ),
            ),
          ),
          // Меню навигации
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _GlassNavBar(
              currentIndex: _currentIndex,
              onTabSelected: (i) => setState(() => _currentIndex = i),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Glass Nav Bar ──────────────────────────────────────────────────────────────

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
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            color: const Color(0xFF171A21).withValues(alpha: 0.85),
            border: Border.all(color: Colors.white10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 25,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavItem(
                icon: Icons.dns_outlined,
                activeIcon: Icons.dns,
                label: 'Серверы',
                selected: currentIndex == 0,
                onTap: () => onTabSelected(0),
              ),
              _NavItem(
                icon: Icons.card_membership_outlined,
                activeIcon: Icons.card_membership,
                label: 'Подписка',
                selected: currentIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              // ── Center Home button ──────────────────────────────────────
              _HomeNavItem(
                selected: currentIndex == 2,
                onTap: () => onTabSelected(2),
              ),
              _NavItem(
                icon: Icons.workspace_premium_outlined,
                activeIcon: Icons.workspace_premium,
                label: 'Premium',
                selected: currentIndex == 3,
                onTap: () => onTabSelected(3),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings,
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

// ── Elevated center Home button ────────────────────────────────────────────────

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
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      lowerBound: 0.9,
      upperBound: 1.0,
      value: widget.selected ? 1.0 : 0.9,
    );
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _HomeNavItem oldWidget) {
    if (widget.selected) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: widget.selected
                        ? [const Color(0xFF6C5CE7), const Color(0xFF4834D4)]
                        : [const Color(0xFF3D3463), const Color(0xFF2D2550)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: widget.selected
                      ? [
                    BoxShadow(
                      color: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                      : [],
                ),
                child: Icon(
                  widget.selected ? Icons.home : Icons.home_outlined,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Главная',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: widget.selected ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Regular nav item ──────────────────────────────────────────────────────────

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      lowerBound: 1.0,
      upperBound: 1.1,
      value: widget.selected ? 1.1 : 1.0,
    );
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _NavItem oldWidget) {
    if (widget.selected) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const activeColor = Colors.white;
    const inactiveColor = Colors.white54;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) => Transform.scale(
            scale: _controller.value,
            child: child,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.selected ? widget.activeIcon : widget.icon,
                size: 22,
                color: widget.selected ? activeColor : inactiveColor,
              ),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: widget.selected ? activeColor : inactiveColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}