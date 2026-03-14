import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../main.dart' show DS;

// ─────────────────────────────────────────────────────────────────────────────
// Overlay that listens to NotificationService and stacks banners at the top.
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
          builder: (context, notifs, _) {
            if (notifs.isEmpty) return const SizedBox.shrink();
            final top = MediaQuery.of(context).padding.top + 12;
            return Positioned(
              top: top,
              left: 12,
              right: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: notifs
                    .map((n) => _NotifBanner(
                  key: ValueKey(n.id),
                  notif: n,
                ))
                    .toList(),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Single banner card with slide-in + auto-dismiss
// ─────────────────────────────────────────────────────────────────────────────

class _NotifBanner extends StatefulWidget {
  final InAppNotification notif;
  const _NotifBanner({super.key, required this.notif});

  @override
  State<_NotifBanner> createState() => _NotifBannerState();
}

class _NotifBannerState extends State<_NotifBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

    _ctrl.forward();

    if (widget.notif.type == InAppNotifType.informational) {
      _autoTimer = Timer(widget.notif.autoDismiss, _dismiss);
    }
  }

  void _dismiss() {
    if (!mounted) return;
    _ctrl.reverse().then((_) {
      notificationService.dismiss(widget.notif.id);
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  // ── Colors ─────────────────────────────────────────────────────────────────

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
      case InAppNotifSeverity.success: return Icons.check_circle_outline_rounded;
      case InAppNotifSeverity.warning: return Icons.warning_amber_rounded;
      case InAppNotifSeverity.error:   return Icons.error_outline_rounded;
      case InAppNotifSeverity.info:    return Icons.info_outline_rounded;
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: DS.surface2,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(color: _accent.withValues(alpha: 0.4)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Accent side bar
                  Container(
                    width: 4,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(DS.radiusSm),
                        bottomLeft: Radius.circular(DS.radiusSm),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Icon
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Icon(_icon, color: _accent, size: 20),
                  ),
                  const SizedBox(width: 10),
                  // Text
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.notif.title.isNotEmpty)
                            Text(
                              widget.notif.title,
                              style: const TextStyle(
                                color: DS.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (widget.notif.body.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.notif.body,
                              style: const TextStyle(
                                color: DS.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Close button (for non-informational)
                  if (widget.notif.type != InAppNotifType.informational)
                    GestureDetector(
                      onTap: _dismiss,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(Icons.close_rounded,
                            size: 16, color: DS.textMuted),
                      ),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
