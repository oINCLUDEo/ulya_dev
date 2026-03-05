import 'dart:ui';
import 'package:flutter/material.dart';
import 'pages/home_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';

void main() {
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
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
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
  int _currentIndex = 1;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ServersPage(
        onGoToHome: () => setState(() => _currentIndex = 1),
        onGoToSettings: () => setState(() => _currentIndex = 2),
      ),
      const HomePage(),
      const SettingsPage(),
    ];

    return Scaffold(
      extendBody: true, // фон под панелью будет сквозным
      body: IndexedStack(index: _currentIndex, children: pages),

      // Здесь просто размещаем наш Glass Nav Bar
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), // отступы от краев и снизу
        child: _GlassNavBar(
          currentIndex: _currentIndex,
          onTabSelected: (i) => setState(() => _currentIndex = i),
        ),
      ),
    );
  }
}

/// ── Плавающий стеклянный навбар ───────────────────────────────
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
            color: const Color(0xFF171A21).withOpacity(0.85),
            border: Border.all(color: Colors.white10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
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
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
                label: 'Главная',
                selected: currentIndex == 1,
                onTap: () => onTabSelected(1),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings,
                label: 'Настройки',
                selected: currentIndex == 2,
                onTap: () => onTabSelected(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) {
    final activeColor = Colors.white;
    final inactiveColor = Colors.white54;

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
                size: 24,
                color: widget.selected ? activeColor : inactiveColor,
              ),
              const SizedBox(height: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
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