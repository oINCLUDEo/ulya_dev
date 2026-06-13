part of 'home_page.dart';

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
  // Finger-press spring (orb scales down on touch).
  late final AnimationController _pressCtrl;
  // Gentle "breathing" while connected — makes the orb feel alive.
  late final AnimationController _breatheCtrl;

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
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      lowerBound: 0,
      upperBound: 1,
    );
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (widget.isLoading) _spinCtrl.repeat();
    if (_ringsActive) _pulseCtrl.repeat();
    if (widget.isConnected) _breatheCtrl.repeat(reverse: true);
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
    if (widget.isConnected && !old.isConnected) {
      _breatheCtrl.repeat(reverse: true);
    } else if (!widget.isConnected && old.isConnected) {
      _breatheCtrl
        ..stop()
        ..animateTo(0, duration: const Duration(milliseconds: 300));
    }
  }

  void _onTapDown() {
    if (widget.isLoading) return;
    HapticFeedback.selectionClick();
    _pressCtrl.forward();
  }

  void _releasePress() => _pressCtrl.reverse();

  @override
  void dispose() {
    _spinCtrl.dispose();
    _pulseCtrl.dispose();
    _pressCtrl.dispose();
    _breatheCtrl.dispose();
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
              GestureDetector(
                onTapDown: (_) => _onTapDown(),
                onTapUp: (_) => _releasePress(),
                onTapCancel: _releasePress,
                onTap: widget.isLoading ? null : widget.onTap,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_spinCtrl, _pressCtrl, _breatheCtrl]),
                  builder: (_, child) {
                    // Press dips the orb to 0.92; breathing adds a slow ±2.5%
                    // swell only while connected.
                    final press = 1 - _pressCtrl.value * 0.08;
                    final breathe =
                        widget.isConnected ? 1 + _breatheCtrl.value * 0.025 : 1.0;
                    return Transform.scale(
                      scale: press * breathe,
                      child: AnimatedContainer(
                      duration: const Duration(milliseconds: 350),
                      width: 128,
                      height: 128,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // Radial gradient gives the flat disc real depth: a soft
                        // top-left highlight fading to a darker lower-right.
                        gradient: RadialGradient(
                          center: const Alignment(-0.35, -0.45),
                          radius: 1.05,
                          colors: [
                            Color.lerp(_color, Colors.white, 0.24)!,
                            _color,
                            Color.lerp(_color, Colors.black, 0.20)!,
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
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
                              child: CustomPaint(
                                size: const Size(56, 56),
                                painter: _SweepArcPainter(),
                              ),
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

// ── Sweep-arc spinner shown inside the orb while connecting ──────────────────
// A 270° arc whose tail fades to transparent (SweepGradient); the parent spins
// it via _spinCtrl. Reads as a smooth indeterminate progress ring instead of a
// rotating refresh glyph.
class _SweepArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF)],
        stops: [0.0, 1.0],
      ).createShader(rect);
    canvas.drawArc(rect, 0, math.pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(_SweepArcPainter oldDelegate) => false;
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
  /// When false, the glyph stays perfectly static and just dims while
  /// loading — for icons where any rotation reads as a glitch (e.g. a
  /// speedometer). Progress feedback is the per-row scan animation instead.
  final bool spinWhenLoading;
  const VpnIconBtn({
    super.key,
    required this.loading,
    required this.icon,
    this.onTap,
    this.spinWhenLoading = true,
  });

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
    if (widget.loading && widget.spinWhenLoading) _rotCtrl.repeat();
  }

  @override
  void didUpdateWidget(VpnIconBtn old) {
    super.didUpdateWidget(old);
    if (!widget.spinWhenLoading) return;
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
      child: (widget.loading && !widget.spinWhenLoading)
          ? Icon(widget.icon,
              color: DS.textSecondary.withValues(alpha: 0.35), size: 20)
          : RotationTransition(
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

