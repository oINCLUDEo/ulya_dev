part of 'premium_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Success overlay
// ═══════════════════════════════════════════════════════════════════════════

// ── Particle data ─────────────────────────────────────────────────────────────

class _Particle {
  final double angle;   // radians
  final double speed;   // relative 0.5–1.5
  final double delay;   // normalised 0.0–0.35 (start offset)
  final Color  color;
  final double radius;  // px 3–7

  const _Particle({
    required this.angle,
    required this.speed,
    required this.delay,
    required this.color,
    required this.radius,
  });
}

class _ParticlePainter extends CustomPainter {
  final double progress;
  final List<_Particle> particles;
  // Vertical offset so particles burst from the icon, not screen centre
  final double originOffsetY;

  const _ParticlePainter({
    required this.progress,
    required this.particles,
    this.originOffsetY = -60,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + originOffsetY;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in particles) {
      if (progress <= p.delay) continue;
      final t = ((progress - p.delay) / (1.0 - p.delay)).clamp(0.0, 1.0);
      // Quick fade-in, slow fade-out
      final opacity = t < 0.45 ? t / 0.45 : (1.0 - t) / 0.55;
      final dist = p.speed * t * 190;
      final dx = cx + dist * cos(p.angle);
      final dy = cy + dist * sin(p.angle) + 55 * t * t; // gravity bow
      final r  = (p.radius * (1.0 - t * 0.35)).clamp(1.0, 12.0);
      paint.color = p.color.withValues(alpha: (opacity * 0.92).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(dx, dy), r, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}

// ── Success overlay ───────────────────────────────────────────────────────────

class _SuccessOverlay extends StatefulWidget {
  final bool isUpgrade;
  final VoidCallback? onDismiss;
  const _SuccessOverlay({required this.isUpgrade, this.onDismiss});

  @override
  State<_SuccessOverlay> createState() => _SuccessOverlayState();
}

class _SuccessOverlayState extends State<_SuccessOverlay>
    with TickerProviderStateMixin {
  // Main sequence: fade-in → icon scale → text slide
  late final AnimationController _mainCtrl;
  // Particle burst, fires after icon pops
  late final AnimationController _particleCtrl;
  // Expanding ring pulse after icon lands
  late final AnimationController _pulseCtrl;

  late final Animation<double> _fadeIn;
  late final Animation<double> _scaleIcon;
  late final Animation<double> _fadeText;
  late final Animation<double> _slideText;

  late final List<_Particle> _particles;

  static const _particleColors = [
    Color(0xFF7C6FF7), // violet
    Color(0xFF2DD4BF), // teal
    Color(0xFFFBBF24), // amber
    Color(0xFF34D399), // emerald
    Color(0xFF60A5FA), // sky-blue
    Color(0xFFF472B6), // pink
  ];

  @override
  void initState() {
    super.initState();

    // Pre-generate particles with randomised properties
    final rng = Random();
    _particles = List.generate(22, (i) {
      final baseAngle = (i / 22) * 2 * pi;
      return _Particle(
        angle:  baseAngle + (rng.nextDouble() - 0.5) * 0.6,
        speed:  0.55 + rng.nextDouble() * 0.9,
        delay:  rng.nextDouble() * 0.3,
        color:  _particleColors[rng.nextInt(_particleColors.length)],
        radius: 3.0 + rng.nextDouble() * 4.0,
      );
    });

    _mainCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _particleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1300));
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650));

    _fadeIn    = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.00, 0.25, curve: Curves.easeOut));
    _scaleIcon = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.08, 0.50, curve: Curves.elasticOut));
    _fadeText  = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.48, 0.74, curve: Curves.easeOut));
    _slideText = CurvedAnimation(parent: _mainCtrl,
        curve: const Interval(0.48, 0.74, curve: Curves.easeOutCubic));

    _mainCtrl.forward();

    // Staggered trigger: particles + haptic when icon starts landing
    Future<void>.delayed(const Duration(milliseconds: 230), () {
      if (!mounted) return;
      HapticFeedback.heavyImpact();
      _particleCtrl.forward();
    });
    // Pulse ring fires right as elasticOut settles
    Future<void>.delayed(const Duration(milliseconds: 460), () {
      if (mounted) _pulseCtrl.forward();
    });
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _particleCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // Fetches the user's referral code fresh (rather than trusting a possibly
  // stale global cache) — this overlay is the highest-attention moment right
  // after a purchase, so it's worth the extra round-trip to get it right.
  Future<void> _onInviteTap() async {
    HapticFeedback.selectionClick();
    try {
      final info = await ReferralService.getInfo();
      if (info == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Реферальная программа сейчас недоступна'),
            backgroundColor: DS.surface2,
          ));
        }
        return;
      }
      final png = await renderReferralCardPng(info);
      if (png != null) {
        await SharePlus.instance.share(ShareParams(
          files: [
            XFile.fromData(png, mimeType: 'image/png', name: 'ulya_invite.png'),
          ],
          text: info.shareText,
        ));
        return;
      }
      await SharePlus.instance.share(ShareParams(text: info.shareText));
    } catch (e) {
      appLogger.error('SuccessOverlay', 'invite share failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onDismiss,
    behavior: HitTestBehavior.opaque,
    child: FadeTransition(
      opacity: _fadeIn,
      child: Container(
        color: DS.surface0.withValues(alpha: 0.97),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Particle burst ──────────────────────────────────────────
            AnimatedBuilder(
              animation: _particleCtrl,
              builder: (_, _) => CustomPaint(
                painter: _ParticlePainter(
                  progress:      _particleCtrl.value,
                  particles:     _particles,
                  originOffsetY: -70,
                ),
              ),
            ),

            // ── Main content ────────────────────────────────────────────
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [

                // Icon + expanding pulse ring
                AnimatedBuilder(
                  animation: Listenable.merge([_scaleIcon, _pulseCtrl]),
                  builder: (_, child) => Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      // Pulse ring
                      if (_pulseCtrl.value > 0)
                        Opacity(
                          opacity: (1.0 - _pulseCtrl.value).clamp(0.0, 1.0),
                          child: Container(
                            width:  108 + _pulseCtrl.value * 72,
                            height: 108 + _pulseCtrl.value * 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: _teal.withValues(alpha: 0.55),
                                  width: 2.5),
                            ),
                          ),
                        ),
                      child!,
                    ],
                  ),
                  child: ScaleTransition(
                    scale: _scaleIcon,
                    child: Container(
                      width: 108, height: 108,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                            colors: [_teal, Color(0xFF059669)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight),
                        boxShadow: [
                          BoxShadow(color: _teal.withValues(alpha: 0.55),
                              blurRadius: 50, offset: const Offset(0, 10)),
                          BoxShadow(color: _teal.withValues(alpha: 0.25),
                              blurRadius: 90, spreadRadius: 10),
                        ],
                      ),
                      child: const Icon(
                          Icons.check_rounded, color: Colors.white, size: 54),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Text slides up as it fades in (dopamine payoff moment)
                AnimatedBuilder(
                  animation: _fadeText,
                  builder: (_, _) => Opacity(
                    opacity: _fadeText.value,
                    child: Transform.translate(
                      offset: Offset(0, 22 * (1.0 - _slideText.value)),
                      child: Column(children: [
                        Text(
                          widget.isUpgrade ? 'Готово!' : 'Подписка активна',
                          style: const TextStyle(
                              color: _t0, fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.isUpgrade
                              ? 'Изменения применены'
                              : 'Добро пожаловать',
                          style: const TextStyle(color: _t1, fontSize: 16),
                        ),
                        const SizedBox(height: 26),
                        // Invite nudge — this is the highest-attention moment
                        // right after a purchase, so it's the best place to
                        // surface the referral programme.
                        GestureDetector(
                          onTap: _onInviteTap,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 12),
                            decoration: BoxDecoration(
                              color: DS.violet.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(50),
                              border: Border.all(
                                  color: DS.violet.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(PhosphorIconsFill.gift,
                                    size: 16, color: DS.violet),
                                const SizedBox(width: 8),
                                const Text(
                                  'Пригласить друга — получить бонус',
                                  style: TextStyle(
                                    color: _t0,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  _TariffSelectCard — compact tariff row for change-tariff step 1
// ═══════════════════════════════════════════════════════════════════════════

class _TariffSelectCard extends StatefulWidget {
  final TariffInfo tariff;
  final bool selected;
  final String? badgeLabel;
  final bool showStepper;
  final int deviceCount;
  final int deviceMin;
  final int deviceMax;
  final VoidCallback onTap;
  final VoidCallback onDeviceDecrement;
  final VoidCallback onDeviceIncrement;

  const _TariffSelectCard({
    required this.tariff,
    required this.selected,
    required this.onTap,
    required this.onDeviceDecrement,
    required this.onDeviceIncrement,
    this.badgeLabel,
    this.showStepper = false,
    this.deviceCount = 5,
    this.deviceMin = 5,
    this.deviceMax = 8,
  });

  @override
  State<_TariffSelectCard> createState() => _TariffSelectCardState();
}

class _TariffSelectCardState extends State<_TariffSelectCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final t        = widget.tariff;
    final selected = widget.selected;
    final cheapest = t.cheapestPeriod;
    final (iconData, accent) = _TariffRadioCardState._tariffStyle(t);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
          onTapDown:   (_) => setState(() => _pressed = true),
          onTapUp:     (_) { widget.onTap(); setState(() => _pressed = false); },
          onTapCancel: ()  => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.98 : 1.0,
            duration: _pressed
                ? const Duration(milliseconds: 70)
                : const Duration(milliseconds: 280),
            curve: _pressed ? Curves.easeIn : Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: 0.08)
                    : _premSurface,
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(
                  color: selected ? accent.withValues(alpha: 0.75) : _b1,
                  width: 1.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Иконка тарифа в цветном контейнере
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: selected ? 0.18 : 0.12),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Center(
                            child: PhosphorIcon(iconData,
                                color: selected ? accent : accent.withValues(alpha: 0.75),
                                size: 20),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _TariffRadioCard._cleanTariffName(t.name),
                                style: TextStyle(
                                  color: selected ? _t0 : _t1,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(children: [
                                _MetaChip(
                                  icon: t.trafficLimitGb == 0
                                      ? Icons.all_inclusive_rounded
                                      : Icons.storage_rounded,
                                  label: t.trafficLimitGb == 0
                                      ? 'Без лимита'
                                      : '${t.trafficLimitGb} ГБ',
                                ),
                                const SizedBox(width: 8),
                                _MetaChip(
                                  icon: Icons.devices_rounded,
                                  label: '${t.deviceLimit} устр.',
                                ),
                              ]),
                            ],
                          ),
                        ),
                        if (cheapest != null) ...[
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${cheapest.priceRub.toStringAsFixed(0)} ₽',
                                style: TextStyle(
                                  color: selected ? accent : _t0,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Text(
                                '/мес',
                                style: TextStyle(
                                  color: _t1,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    if (widget.showStepper) ...[
                      const SizedBox(height: 12),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0A0F),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Устройства',
                                    style: TextStyle(color: _t1, fontSize: 11)),
                                const SizedBox(height: 2),
                                Text(
                                  '${widget.deviceCount} из ${widget.deviceMax}',
                                  style: const TextStyle(
                                    color: _t0,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            Row(children: [
                              _StepperBtn(
                                icon: Icons.remove_rounded,
                                enabled: widget.deviceCount > widget.deviceMin,
                                onTap: widget.onDeviceDecrement,
                                accent: accent,
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                child: Text(
                                  '${widget.deviceCount}',
                                  style: const TextStyle(
                                    color: _t0,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              _StepperBtn(
                                icon: Icons.add_rounded,
                                enabled: widget.deviceCount < widget.deviceMax,
                                onTap: widget.onDeviceIncrement,
                                accent: accent,
                                filled: true,
                              ),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.badgeLabel != null)
          Positioned(
            top: -10,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: DS.violet,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.badgeLabel!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: _t1),
      const SizedBox(width: 4),
      Text(label,
          style: const TextStyle(
              color: _t1, fontSize: 11, fontWeight: FontWeight.w500)),
    ],
  );
}

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final bool filled;
  final Color accent;
  final VoidCallback onTap;

  const _StepperBtn({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.accent,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: AnimatedOpacity(
      opacity: enabled ? 1.0 : 0.4,
      duration: const Duration(milliseconds: 150),
      child: Container(
        width: 30, height: 30,
        decoration: BoxDecoration(
          color: filled && enabled ? accent : _premSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _b1),
        ),
        child: Icon(icon,
            size: 16,
            color: filled && enabled ? Colors.white : _t1),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  _CurrentTariffMini — mini card showing the current subscription
// ═══════════════════════════════════════════════════════════════════════════

class _CurrentTariffMini extends StatelessWidget {
  final MeSubscription sub;
  final List<TariffInfo> tariffs;
  const _CurrentTariffMini({required this.sub, required this.tariffs});

  @override
  Widget build(BuildContext context) {
    final subName = (sub.planName ?? '').toLowerCase().trim();
    TariffInfo? cur;
    if (subName.isNotEmpty) {
      try {
        cur = tariffs.firstWhere((t) => t.name.toLowerCase().trim() == subName);
      } catch (_) {}
    }

    final trafficLabel = cur != null
        ? (cur.trafficLimitGb == 0 ? 'Без лимита' : '${cur.trafficLimitGb} ГБ')
        : null;
    final deviceLabel = cur != null ? '${cur.deviceLimit} устр.' : null;
    final cheapestPriceRub = cur?.cheapestPeriod?.priceRub;

    final metaParts = <String>[
      ?trafficLabel,
      ?deviceLabel,
      if (cheapestPriceRub != null) '${cheapestPriceRub.toStringAsFixed(0)} ₽/мес',
    ];
    final meta = metaParts.join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'У ВАС СЕЙЧАС',
          style: TextStyle(
            color: _t2, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 8),
        // Tier 1 — the anchor the whole renew/change decision is made against.
        AccentCard(
          accent: DS.violet,
          radius: DS.radiusSm,
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
          child: Row(children: [
            const AccentIconBox(
              accent: DS.violet,
              size: 32,
              icon: Icon(Icons.shield_rounded, color: DS.violet, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sub.planName ?? 'Текущий тариф',
                    style: const TextStyle(
                      color: _t0, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  if (meta.isNotEmpty)
                    Text(meta, style: const TextStyle(color: _t1, fontSize: 11)),
                ],
              ),
            ),
          ]),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  _BalanceUsageToggle — balance deduction toggle
// ═══════════════════════════════════════════════════════════════════════════

class _BalanceUsageToggle extends StatelessWidget {
  final double balanceRub;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  const _BalanceUsageToggle({
    required this.balanceRub,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: _premSurface,
      borderRadius: BorderRadius.circular(DS.radiusSm),
      border: Border.all(color: _b1),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Row(children: [
      Icon(Icons.account_balance_wallet_rounded,
          size: 18, color: enabled ? _teal : _t1),
      const SizedBox(width: 10),
      Expanded(
        child: Text.rich(
          TextSpan(
            text: 'Списать с баланса ',
            style: const TextStyle(color: _t0, fontSize: 13),
            children: [
              TextSpan(
                text: '(${balanceRub.toStringAsFixed(0)} ₽)',
                style: const TextStyle(color: _t1),
              ),
            ],
          ),
        ),
      ),
      Switch(
        value: enabled,
        onChanged: onToggle,
        activeThumbColor: _teal,
        activeTrackColor: _teal.withValues(alpha: 0.5),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  _BreakdownRow — single row in cost breakdown table
// ═══════════════════════════════════════════════════════════════════════════

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;
  final bool strikethrough;

  const _BreakdownRow({
    required this.label,
    required this.value,
    this.accent,
    this.strikethrough = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = accent ?? (strikethrough ? _t2 : _t1);
    final valueColor = accent ?? (strikethrough ? _t2 : _t0);
    final decoration = strikethrough ? TextDecoration.lineThrough : TextDecoration.none;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                color: labelColor, fontSize: 13, decoration: decoration,
                decorationColor: _t2)),
        Text(value,
            style: TextStyle(
                color: valueColor, fontSize: 13, decoration: decoration,
                decorationColor: _t2)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  _TrialCta — "activate free trial" card shown to logged-in users on the
//  plans screen, only when /subscription/trial reports the trial is still
//  available. Mirrors the look of the onboarding trial-offer card so the
//  user reads it as a continuation, not a new feature.
// ═══════════════════════════════════════════════════════════════════════════
class _TrialCta extends StatelessWidget {
  final int days;
  final bool loading;
  final VoidCallback onTap;
  const _TrialCta({
    required this.days,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2A1F0E), Color(0xFF1A130A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.gold.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: DS.gold.withValues(alpha: 0.18),
            blurRadius: 22,
            spreadRadius: -6,
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: DS.gold.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DS.gold.withValues(alpha: 0.4)),
          ),
          child: Icon(PhosphorIconsFill.gift, color: DS.gold, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Пробный период',
                style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.2),
              ),
              const SizedBox(height: 3),
              Text(
                '$days ${_daysWord(days)} бесплатно, без оплаты',
                style: const TextStyle(
                    color: DS.textSecondary,
                    fontSize: 12.5,
                    height: 1.3),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 38,
          child: FilledButton(
            onPressed: loading ? null : onTap,
            style: FilledButton.styleFrom(
              backgroundColor: DS.gold,
              foregroundColor: const Color(0xFF1F1607),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DS.radiusSm)),
              textStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
            ),
            child: loading
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF1F1607)),
                  )
                : const Text('Активировать'),
          ),
        ),
      ]),
    );
  }

  static String _daysWord(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'день';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
    return 'дней';
  }
}
