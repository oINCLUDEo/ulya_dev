import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../main.dart' show DS;
import '../utils/signal_quality.dart';

/// Auto-routed host indicator — same footprint as [QualityBars] so auto and
/// manual rows line up, but static (auto hosts have no single address to
/// probe) with a tooltip clarifying it's a balanced/auto host.
class AutoQualityBars extends StatelessWidget {
  const AutoQualityBars({super.key});

  @override
  Widget build(BuildContext context) {
    const heights = [5.0, 7.5, 10.0, 12.5];
    return Tooltip(
      message: 'Авто-балансировка',
      preferBelow: false,
      child: Container(
        width: 34, height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DS.indigoLight.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DS.radiusXs),
          border: Border.all(color: DS.indigoLight.withValues(alpha: 0.28)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 4; i++) ...[
              Container(
                width: 2.5,
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
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// QualityBars — 4-bar Wi-Fi style indicator, shared by ServersPage and the
// HomePage server picker so a server's signal is visible everywhere the user
// can pick one manually, connected or not.
//
// Quality buckets:
//   noLink / !isAvailable → 0 bars, rose (server unreachable)
//   ping == -2            → animated amber scan (measuring)
//   ping ∈ (-∞, 0)        → 1 rose bar (probe failed)
//   ping == null          → all bars dim violet (never measured; tap to probe)
//   ping <  80            → 4 emerald
//   ping < 180            → 3 emerald
//   ping < 320            → 2 amber
//   ping ≥ 320            → 1 rose
//
// Interaction:
//   tap        → run / re-run probe.
//   long-press → snackbar with the raw "Пинг: N мс" (parent supplies handler).
//   tooltip    → same number on hover/long-touch.
// ─────────────────────────────────────────────────────────────────────────────
class QualityBars extends StatefulWidget {
  final int? ping;
  final bool isAvailable;
  final bool noLink;
  /// Run a fresh TCP probe for this server. Triggered by long-press, and by
  /// tap when the badge has no value to peek at yet.
  final VoidCallback onProbe;

  const QualityBars({
    super.key,
    required this.ping,
    required this.isAvailable,
    required this.noLink,
    required this.onProbe,
  });

  @override
  State<QualityBars> createState() => _QualityBarsState();
}

class _QualityBarsState extends State<QualityBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scanCtrl;
  // Tap-to-peek: while true, the badge renders the raw "120 мс" text instead
  // of the bars. Auto-reverts after [_peekDuration].
  bool _showMs = false;
  Timer? _peekTimer;
  static const Duration _peekDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.ping == -2) _scanCtrl.repeat();
  }

  @override
  void didUpdateWidget(covariant QualityBars old) {
    super.didUpdateWidget(old);
    final wasScanning = old.ping == -2;
    final isScanning = widget.ping == -2;
    if (isScanning && !wasScanning) {
      _scanCtrl.repeat();
      // A new probe is in flight — bail out of "show ms" mode so the user
      // can see the scan animation, otherwise it'd stay on the stale value.
      if (_showMs) {
        _peekTimer?.cancel();
        _showMs = false;
      }
    } else if (!isScanning && wasScanning) {
      _scanCtrl..stop()..reset();
    }
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _peekTimer?.cancel();
    super.dispose();
  }

  /// Single-tap handler. If there's a real ping number to show → flip the
  /// badge into "ms text" mode for [_peekDuration]. Otherwise — re-probe.
  void _onTap() {
    final p = widget.ping;
    final hasValue = p != null && p >= 0;
    if (!hasValue) {
      widget.onProbe();
      return;
    }
    HapticFeedback.selectionClick();
    _peekTimer?.cancel();
    setState(() => _showMs = !_showMs);
    if (_showMs) {
      _peekTimer = Timer(_peekDuration, () {
        if (mounted) setState(() => _showMs = false);
      });
    }
  }

  ({int active, Color color, String tooltip, bool loading, bool offline})
      _state() {
    final p = widget.ping;
    if (widget.noLink || !widget.isAvailable) {
      return (active: 0, color: DS.rose, tooltip: 'Сервер недоступен',
          loading: false, offline: true);
    }
    if (p == -2) {
      return (active: 0, color: DS.amber, tooltip: 'Проверяем…',
          loading: true, offline: false);
    }
    if (p == null) {
      return (active: 0, color: DS.violet, tooltip: 'Нажмите, чтобы проверить',
          loading: false, offline: false);
    }
    if (p < 0) {
      // Probe failed — render an explicit "offline" badge instead of a
      // single red bar, which read as "weak signal" rather than "dead".
      return (active: 0, color: DS.rose,
          tooltip: 'Нет связи. Нажмите, чтобы повторить.',
          loading: false, offline: true);
    }
    final q = signalQualityFromPing(p);
    return (active: q.activeBars, color: q.color, tooltip: '$p мс',
        loading: false, offline: false);
  }

  static const _heights = [5.0, 7.5, 10.0, 12.5];

  Widget _scanBars() {
    return AnimatedBuilder(
      animation: _scanCtrl,
      builder: (_, child) {
        final t = _scanCtrl.value * 4;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 4; i++) ...[
              Container(
                width: 2.5,
                height: _heights[i],
                decoration: BoxDecoration(
                  color: DS.amber.withValues(alpha: _scanAlpha(i, t)),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              if (i < 3) const SizedBox(width: 2),
            ],
          ],
        );
      },
    );
  }

  double _scanAlpha(int i, double t) {
    final d = (i - t).abs();
    final wrapped = math.min(d, 4 - d);
    final n = (1 - wrapped / 2).clamp(0.0, 1.0);
    return 0.18 + 0.67 * n;
  }

  Widget _staticBars(int active, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 4; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: 2.5,
            height: _heights[i],
            decoration: BoxDecoration(
              color: i < active ? color : DS.textMuted.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          if (i < 3) const SizedBox(width: 2),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _state();
    final p = widget.ping;
    final showMsText = _showMs && p != null && p >= 0 && !s.loading;
    return Tooltip(
      message: showMsText ? 'Удерживайте, чтобы обновить' : s.tooltip,
      preferBelow: false,
      child: GestureDetector(
        onTap: _onTap,
        onLongPress: widget.onProbe,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          // Slightly wider when the number is on screen so "120 мс" doesn't
          // get cut. Bar mode keeps its compact 34px footprint.
          width: showMsText ? 48 : 34,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: s.color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(DS.radiusXs),
            border: Border.all(color: s.color.withValues(alpha: 0.28)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: showMsText
                ? Text('$p мс',
                    key: const ValueKey('ms'),
                    style: TextStyle(
                      color: s.color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ))
                : s.offline
                    ? const Icon(PhosphorIconsBold.wifiSlash,
                        key: ValueKey('offline'), size: 13, color: DS.rose)
                    : KeyedSubtree(
                        key: const ValueKey('bars'),
                        child: s.loading
                            ? _scanBars()
                            : _staticBars(s.active, s.color),
                      ),
          ),
        ),
      ),
    );
  }
}
