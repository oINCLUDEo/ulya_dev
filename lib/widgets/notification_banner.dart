import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../main.dart' show DS;

// ─────────────────────────────────────────────────────────────────────────────
// Overlay
// ─────────────────────────────────────────────────────────────────────────────

class InAppNotificationOverlay extends StatelessWidget {
  final Widget child;
  const InAppNotificationOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ValueListenableBuilder<List<InAppNotification>>(
          valueListenable: notificationService.activeNotifications,
          builder: (_, notifs, _) {
            if (notifs.isEmpty) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: notifs
                        .map((n) => _Banner(key: ValueKey(n.id), notif: n))
                        .toList(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Banner
// ─────────────────────────────────────────────────────────────────────────────

class _Banner extends StatefulWidget {
  final InAppNotification notif;
  const _Banner({super.key, required this.notif});

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  bool _visible    = false;
  bool _dismissing = false;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
    if (widget.notif.type == InAppNotifType.informational) {
      _autoTimer = Timer(widget.notif.autoDismiss, _dismiss);
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _autoTimer?.cancel();
    setState(() => _visible = false);
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (mounted) notificationService.dismiss(widget.notif.id);
  }

  // ── Accent ─────────────────────────────────────────────────────────────────

  Color get _accent {
    switch (widget.notif.severity) {
      case InAppNotifSeverity.success: return DS.emerald;
      case InAppNotifSeverity.warning: return DS.amber;
      case InAppNotifSeverity.error:   return DS.rose;
      case InAppNotifSeverity.info:    return DS.violet;
    }
  }

  IconData get _icon {
    switch (widget.notif.severity) {
      case InAppNotifSeverity.success: return Icons.check_circle_rounded;
      case InAppNotifSeverity.warning: return Icons.warning_rounded;
      case InAppNotifSeverity.error:   return Icons.error_rounded;
      case InAppNotifSeverity.info:    return Icons.info_rounded;
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    final hasBody = widget.notif.body.isNotEmpty;
    final hasTitle = widget.notif.title.isNotEmpty;
    final isAuto = widget.notif.type == InAppNotifType.informational;

    return AnimatedSlide(
      offset: _visible ? Offset.zero : const Offset(0, -1.3),
      duration: Duration(milliseconds: _visible ? 380 : 260),
      curve: _visible ? Curves.easeOutBack : Curves.easeInQuart,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: Duration(milliseconds: _visible ? 240 : 180),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            // swipe up → dismiss
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -200) _dismiss();
            },
            // tap → dismiss auto banners
            onTap: isAuto ? _dismiss : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    // Deep glass with a strong dark base so text is always readable
                    color: DS.surface1.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.40),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.50),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                      // Soft colour glow matching severity
                      BoxShadow(
                        color: accent.withValues(alpha: 0.14),
                        blurRadius: 20,
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      14,
                      hasBody ? 12 : 14,
                      isAuto ? 14 : 6,
                      hasBody ? 12 : 14,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [

                        // ── Icon pill ────────────────────────────────────
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(_icon, color: accent, size: 17),
                        ),

                        const SizedBox(width: 11),

                        // ── Text ─────────────────────────────────────────
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (hasTitle)
                                Text(
                                  widget.notif.title,
                                  style: TextStyle(
                                    color: DS.textPrimary,
                                    fontSize: hasBody ? 13.0 : 14.0,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                ),
                              if (hasBody) ...[
                                if (hasTitle) const SizedBox(height: 2),
                                Text(
                                  widget.notif.body,
                                  style: const TextStyle(
                                    color: DS.textSecondary,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(width: 8),

                        // ── Trailing ──────────────────────────────────────
                        if (isAuto)
                          _CountdownArc(
                            duration: widget.notif.autoDismiss,
                            color: accent,
                          )
                        else ...[
                          // Thin separator
                          const SizedBox(
                            width: 1,
                            height: 28,
                            child: ColoredBox(color: DS.border),
                          ),
                          _CloseBtn(onTap: _dismiss),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Close button
// ─────────────────────────────────────────────────────────────────────────────

class _CloseBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Icon(Icons.close_rounded, size: 16, color: DS.textMuted),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Countdown arc (thin ring that depletes over autoDismiss duration)
// ─────────────────────────────────────────────────────────────────────────────

class _CountdownArc extends StatefulWidget {
  final Duration duration;
  final Color color;
  const _CountdownArc({required this.duration, required this.color});

  @override
  State<_CountdownArc> createState() => _CountdownArcState();
}

class _CountdownArcState extends State<_CountdownArc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          value: 1.0 - _ctrl.value,
          strokeWidth: 2,
          strokeCap: StrokeCap.round,
          backgroundColor: widget.color.withValues(alpha: 0.12),
          color: widget.color,
        ),
      ),
    );
  }
}