part of 'premium_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Aurora background — ambient gradient blobs
// ═══════════════════════════════════════════════════════════════════════════

class _Aurora extends StatelessWidget {
  const _Aurora();

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0D0A22),   // тёмно-фиолетовый сверху
              Color(0xFF07070F),   // нейтральный чёрный в центре
              Color(0xFF07070D),   // почти чёрный снизу
            ],
            stops: [0.0, 0.50, 1.0],
          ),
        ),
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Header
// ═══════════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final bool isManage;
  final bool isExpired;
  final double? balanceRub;
  final String currency;
  const _Header({
    required this.isManage,
    this.isExpired = false,
    this.balanceRub,
    this.currency = 'RUB',
  });

  @override
  Widget build(BuildContext context) {
    final String eyebrow;
    final String title;
    if (isExpired) {
      eyebrow = 'ПОДПИСКА';
      title   = 'Истекла';
    } else if (isManage) {
      eyebrow = 'УПРАВЛЕНИЕ';
      title   = 'Моя подписка';
    } else {
      eyebrow = 'ТАРИФ';
      title   = 'Выберите план';
    }

    final top    = MediaQuery.of(context).padding.top;
    final canPop = Navigator.canPop(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(canPop ? 8 : 20, top + 16, 20, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (canPop) ...[
          GestureDetector(
            onTap: () => Navigator.pop(context),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: DS.surface1,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DS.border),
              ),
              child: const Center(
                child: Icon(Icons.arrow_back_ios_new_rounded, color: DS.textSecondary, size: 16),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              eyebrow,
              style: const TextStyle(
                color: DS.textFaint, fontSize: 10,
                fontWeight: FontWeight.w700, letterSpacing: 2.5,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              title,
              style: TextStyle(
                color: isExpired ? DS.rose : DS.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                height: 1,
              ),
            ),
          ]),
        ),
        if (balanceRub != null) _BalanceChip(rub: balanceRub!, currency: currency),
      ]),
    );
  }
}

class _BalanceChip extends StatelessWidget {
  final double rub; final String currency;
  const _BalanceChip({required this.rub, required this.currency});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
    decoration: BoxDecoration(
      color: DS.surface1,
      borderRadius: BorderRadius.circular(50),
      border: Border.all(color: DS.border),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 7, height: 7,
        decoration: const BoxDecoration(color: _teal, shape: BoxShape.circle),
      ),
      const SizedBox(width: 7),
      Text(
        '${rub.toStringAsFixed(0)} $currency',
        style: const TextStyle(
            color: DS.textPrimary, fontSize: 13, fontWeight: FontWeight.w700),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Action toggle — "Продлить / Сменить тариф" tab switcher
// ═══════════════════════════════════════════════════════════════════════════

class _ActionToggle extends StatelessWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _ActionToggle({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: DS.surface1,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: DS.border),
    ),
    child: Row(children: [
      for (int i = 0; i < labels.length; i++)
        Expanded(
          child: GestureDetector(
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              decoration: BoxDecoration(
                gradient: selected == i
                    ? const LinearGradient(
                        colors: [DS.violet, _indigoD],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight)
                    : null,
                borderRadius: BorderRadius.circular(11),
                boxShadow: selected == i
                    ? [BoxShadow(
                        color: DS.violet.withValues(alpha: 0.32),
                        blurRadius: 14, offset: const Offset(0, 3))]
                    : null,
              ),
              child: Center(
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: selected == i ? Colors.white : DS.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Features banner — top "what you get" list
// ═══════════════════════════════════════════════════════════════════════════

class _FeaturesBanner extends StatefulWidget {
  const _FeaturesBanner();

  static const items = [
    (PhosphorIconsFill.youtubeLogo,        'YouTube без рекламы',           Color(0xFFFF4444)),
    (PhosphorIconsFill.gauge,              'Максимальная скорость',          Color(0xFFD4A84B)),
    (PhosphorIconsFill.globeHemisphereEast,'Серверы по всему миру',          Color(0xFF7C6FF7)),
    (PhosphorIconsFill.headset,            'Приоритетная поддержка 24/7',    Color(0xFF2DD4BF)),
  ];

  @override
  State<_FeaturesBanner> createState() => _FeaturesBannerState();
}

class _FeaturesBannerState extends State<_FeaturesBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // 4 items × 60 ms stagger + 320 ms reveal = 500 ms total
  static const _staggerMs = 60.0;
  static const _revealMs  = 320.0;
  static const _n         = 4;      // == _FeaturesBanner.items.length
  static const _totalMs   = 500.0;  // (4−1)×60 + 320

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
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
      builder: (_, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < _n; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              Builder(builder: (_) {
                final start = (i * _staggerMs) / _totalMs;
                final end   = (i * _staggerMs + _revealMs) / _totalMs;
                final local = ((_ctrl.value - start) / (end - start)).clamp(0.0, 1.0);
                final v     = Curves.easeOutCubic.transform(local);
                return Opacity(
                  opacity: v,
                  child: Transform.scale(
                    scale: 0.97 + 0.03 * v,
                    alignment: Alignment.centerLeft,
                    child: _FeatureRow(
                      icon:  _FeaturesBanner.items[i].$1,
                      label: _FeaturesBanner.items[i].$2,
                      color: _FeaturesBanner.items[i].$3,
                    ),
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final PhosphorIconData icon;
  final String label;
  final Color  color;
  const _FeatureRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(children: [
    // Circle background + icon
    Container(
      width: 42, height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        shape: BoxShape.circle,
      ),
      child: Center(child: PhosphorIcon(icon, color: color, size: 22)),
    ),
    const SizedBox(width: 14),
    Expanded(
      child: Text(label, style: const TextStyle(
          color: DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w600)),
    ),
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Period strip — horizontal pill selector ("1 мес / 3 мес / 1 год …")
// ═══════════════════════════════════════════════════════════════════════════

class _PeriodStrip extends StatelessWidget {
  final List<int>         days;
  final int               selected;
  final List<TariffInfo>  tariffs;   // to compute per-period discount hints
  final ValueChanged<int> onChanged;

  const _PeriodStrip({
    required this.days,
    required this.selected,
    required this.tariffs,
    required this.onChanged,
  });

  /// Max discount % across all tariffs for [d] days period.
  int _maxDiscount(int d) {
    int best = 0;
    for (final t in tariffs) {
      try {
        final p = t.periods.firstWhere((p) => p.days == d);
        if (p.discountPercent > best) best = p.discountPercent;
      } catch (_) {}
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ПЕРИОД ПОДПИСКИ',
          style: TextStyle(
            color: DS.textFaint, fontSize: 10,
            fontWeight: FontWeight.w700, letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // extra top padding so discount badges (-N%) don't clip
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Row(
            children: [
              for (int i = 0; i < days.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _PeriodPill(
                  label:    _PremiumPageState._daysLabel(days[i]),
                  discount: _maxDiscount(days[i]),
                  selected: days[i] == selected,
                  onTap: () => onChanged(days[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PeriodPill extends StatefulWidget {
  final String label;
  final int    discount;
  final bool   selected;
  final VoidCallback onTap;
  const _PeriodPill({
    required this.label,
    required this.discount,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PeriodPill> createState() => _PeriodPillState();
}

class _PeriodPillState extends State<_PeriodPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:  (_) => setState(() => _pressed = true),
      onTapUp:    (_) { widget.onTap(); setState(() => _pressed = false); },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.91 : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 80)
            : const Duration(milliseconds: 400),
        curve: _pressed ? Curves.easeIn : Curves.elasticOut,
        child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              gradient: widget.selected
                  ? const LinearGradient(
                      colors: [DS.violet, _indigoD],
                      begin: Alignment.topLeft, end: Alignment.bottomRight)
                  : null,
              color: widget.selected ? null : DS.surface1,
              borderRadius: BorderRadius.circular(50),
              border: Border.all(
                color: widget.selected ? DS.violet : DS.border,
                width: 1.5,
              ),
              boxShadow: widget.selected
                  ? [BoxShadow(
                      color: DS.violet.withValues(alpha: 0.35),
                      blurRadius: 12, offset: const Offset(0, 3))]
                  : null,
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.selected ? Colors.white : DS.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          // Discount badge
          if (widget.discount > 0)
            Positioned(
              top: -8, right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: DS.gold,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '-${widget.discount}%',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 9, fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    ));   // AnimatedScale
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tariff radio card — compact row: icon | name+chips | price | radio
// ═══════════════════════════════════════════════════════════════════════════

class _TariffRadioCard extends StatefulWidget {
  final TariffInfo   tariff;
  final bool         selected;
  final TariffPeriod? period;
  final String?      badgeLabel;
  final VoidCallback onTap;

  const _TariffRadioCard({
    required this.tariff,
    required this.selected,
    required this.period,
    required this.onTap,
    this.badgeLabel,
  });

  static String _cleanTariffName(String name) =>
      name.replaceFirst(RegExp(r'^[^a-zA-Zа-яёА-ЯЁ]+'), '').trim();

  @override
  State<_TariffRadioCard> createState() => _TariffRadioCardState();
}

class _TariffRadioCardState extends State<_TariffRadioCard> {
  bool _pressed = false;

  static (PhosphorIconData, Color) _tariffStyle(TariffInfo t) {
    final n = _TariffRadioCard._cleanTariffName(t.name).toLowerCase();
    if (n.contains('семей') || n.contains('family')) {
      return (PhosphorIconsFill.usersThree, const Color(0xFF7C6FF7));
    }
    if (n.contains('безлимит') || n.contains('unlimit') || n.contains('безлим')) {
      return (PhosphorIconsFill.rocketLaunch, DS.gold);
    }
    if (n.contains('популяр') || n.contains('popular') || n.contains('стандарт')) {
      return (PhosphorIconsFill.fire, const Color(0xFFFF6B3D));
    }
    if (n.contains('базов') || n.contains('basic') || n.contains('старт') || n.contains('lite')) {
      return (PhosphorIconsFill.shieldCheck, _silver);
    }
    if (n.contains('бизнес') || n.contains('business') || n.contains('корпор')) {
      return (PhosphorIconsFill.crown, DS.gold);
    }
    // Tier fallback
    return switch (t.tierLevel) {
      >= 3 => (PhosphorIconsFill.crown,      DS.gold),
      2    => (PhosphorIconsFill.fire,        const Color(0xFFFF6B3D)),
      _    => (PhosphorIconsFill.shieldCheck, _silver),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (iconData, accent) = _tariffStyle(widget.tariff);
    final price   = widget.period?.priceRub;
    final monthly = widget.period?.pricePerMonthRub;
    final selected = widget.selected;

    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: _pressed
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 260),
      curve: _pressed ? Curves.easeIn : Curves.easeOutCubic,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
        // ── Card body ─────────────────────────────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.08)
                : DS.surface1,
            borderRadius: BorderRadius.circular(_r16),
            border: Border.all(
              color: selected ? accent.withValues(alpha: 0.75) : DS.border,
              width: 1.5,           // constant — no layout shift on select
            ),
            boxShadow: selected
                ? [BoxShadow(
                    color: accent.withValues(alpha: 0.20),
                    blurRadius: 22, offset: const Offset(0, 6))]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onHighlightChanged: (h) => setState(() => _pressed = h),
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(_r16),
              splashColor: accent.withValues(alpha: 0.08),
              highlightColor: accent.withValues(alpha: 0.04),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Row(children: [

                  // ── Tier icon (no background, bare glow) ─────────────────
                  SizedBox(
                    width: 40,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        padding: const EdgeInsets.all(4),
                        decoration: selected
                            ? BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [BoxShadow(
                                  color: accent.withValues(alpha: 0.40),
                                  blurRadius: 14, spreadRadius: 0)],
                              )
                            : null,
                        child: PhosphorIcon(iconData, color: selected ? accent : accent.withValues(alpha: 0.55), size: 30),
                      ),
                    ),
                  ),
                  const SizedBox(width: 13),

                  // ── Name + feature chips ──────────────────────────────────
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _TariffRadioCard._cleanTariffName(widget.tariff.name),
                          style: TextStyle(
                            color: selected ? DS.textPrimary : DS.textSecondary,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.tariff.trafficLimitGb == 0)
                              _MiniPhosphorChip(
                                  icon: PhosphorIconsFill.infinity,
                                  label: 'Безлимит',
                                  color: DS.gold)
                            else
                              _MiniPhosphorChip(
                                  icon: PhosphorIconsRegular.database,
                                  label: 'Обход: ${widget.tariff.trafficLimitGb} ГБ',
                                  color: _sky),
                            const SizedBox(height: 4),
                            _MiniPhosphorChip(
                                icon: PhosphorIconsRegular.devices,
                                label: widget.tariff.deviceLabel,
                                color: _indigoB),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),

                  // ── Price column ──────────────────────────────────────────
                  if (price != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 88),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${price.toStringAsFixed(0)} ₽',
                            style: TextStyle(
                              color: selected ? accent : DS.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            monthly != null && widget.period!.days > 31
                                ? '~${monthly.round()} ₽/мес'
                                : '/мес',
                            style: const TextStyle(color: DS.textFaint, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 10),

                  // ── Radio circle ──────────────────────────────────────────
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? accent : Colors.transparent,
                      border: Border.all(
                        color: selected ? accent : DS.textFaint,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Center(
                            child: Container(
                              width: 8, height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          )
                        : null,
                  ),
                ]),
              ),
            ),
          ),
        ),

        // ── Badge chip floating above the card ───────────────────────────
        if (widget.badgeLabel != null)
          Positioned(
            top: -14,
            right: 18,
            child: _BadgeChip(label: widget.badgeLabel!, tier: widget.tariff.tierLevel),
          ),
      ],
      ),    // Stack
    );     // AnimatedScale
  }
}

// ── Phosphor chip (used in accordion header) ──────────────────────────────
class _MiniPhosphorChip extends StatelessWidget {
  final PhosphorIconData icon;
  final String label;
  final Color color;
  const _MiniPhosphorChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      PhosphorIcon(icon, size: 11, color: color),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}


// Tier badge chip (Популярный, Премиум, etc.)
class _BadgeChip extends StatefulWidget {
  final String label;
  final int tier;
  const _BadgeChip({required this.label, required this.tier});

  @override
  State<_BadgeChip> createState() => _BadgeChipState();
}

class _BadgeChipState extends State<_BadgeChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() { _glow.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const c = DS.gold;
    // Solid dark pill — always legible regardless of card selection state
    // (gold-accent selected cards would swallow a translucent gold badge).
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          // Near-black bg: maximum contrast on every card variant
          color: const Color(0xFF09091A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: c.withValues(alpha: 0.55 + 0.45 * _glow.value),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: c.withValues(alpha: 0.12 + 0.28 * _glow.value),
              blurRadius: 8 + 10 * _glow.value,
              spreadRadius: 0,
            ),
          ],
        ),
        child: child,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('★ ',
              style: TextStyle(
                  color: DS.gold, fontSize: 8, height: 1.1)),
          Text(widget.label,
              style: const TextStyle(
                  color: Color(0xFFFFF8E7),   // warm white — readable on dark
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Tariff period tile — animated selectable row (prices pre-loaded from model)
// ═══════════════════════════════════════════════════════════════════════════

class _TariffPeriodTile extends StatefulWidget {
  final TariffPeriod period;
  final bool selected;
  final VoidCallback onTap;

  const _TariffPeriodTile({
    required this.period,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TariffPeriodTile> createState() => _TariffPeriodTileState();
}

class _TariffPeriodTileState extends State<_TariffPeriodTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final period     = widget.period;
    final selected   = widget.selected;
    final priceRub   = period.priceRub;
    final monthlyRub = period.pricePerMonthRub;
    final discount   = period.discountPercent;
    final origRub    = period.originalPriceRub;

    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) { widget.onTap(); setState(() => _pressed = false); },
      onTapCancel: ()  => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 70)
            : const Duration(milliseconds: 380),
        curve: _pressed ? Curves.easeIn : Curves.elasticOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected ? const Color(0x1A7C6BFF) : DS.surface1,
            borderRadius: BorderRadius.circular(DS.radiusSm),
            border: Border.all(
              color: selected ? DS.violet : DS.border,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Row(children: [

            // ── Animated radio ─────────────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22, height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? DS.violet : Colors.transparent,
                border: Border.all(
                  color: selected ? DS.violet : DS.textFaint,
                  width: 2,
                ),
                boxShadow: selected
                    ? [BoxShadow(
                        color: DS.violet.withValues(alpha: 0.45),
                        blurRadius: 8)]
                    : null,
              ),
              child: selected
                  ? const Center(
                      child: Icon(Icons.check_rounded, size: 13, color: Colors.white))
                  : null,
            ),

            const SizedBox(width: 14),

            // ── Period label + monthly hint ────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    period.label,
                    style: TextStyle(
                      color: selected ? DS.textPrimary : DS.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (monthlyRub != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      '~${monthlyRub.round()} ₽/мес',
                      style: TextStyle(
                        color: selected
                            ? _indigoB.withValues(alpha: 0.85)
                            : DS.textFaint,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Price column ───────────────────────────────────────────────
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (discount > 0)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: selected
                          ? const LinearGradient(
                              colors: [Color(0xFF2DD4BF), Color(0xFF059669)])
                          : null,
                      color: selected ? null : _teal.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '−$discount%',
                      style: TextStyle(
                        color: selected ? Colors.white : _teal,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                if (origRub != null)
                  Text(
                    '${origRub.toStringAsFixed(0)} ₽',
                    style: const TextStyle(
                      color: DS.textFaint, fontSize: 11,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: DS.textFaint,
                    ),
                  ),
                Text(
                  '${priceRub.toStringAsFixed(0)} ₽',
                  style: TextStyle(
                    color: selected ? _indigoB : DS.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plan picker card  — for new users (legacy flow, no tariffs)
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  Plan purchase card — animated shimmer sweep + pulsing border glow.
//  The border oscillates between violet and gold (Itten pair) to draw the eye.
// ═══════════════════════════════════════════════════════════════════════════

class _PlanCard extends StatefulWidget {
  final List<PeriodOption> periods;
  final String? selectedId;
  final String? bestId;
  final ValueChanged<String> onPeriodChanged;

  const _PlanCard({
    required this.periods,
    required this.selectedId,
    required this.bestId,
    required this.onPeriodChanged,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> with TickerProviderStateMixin {
  // Diagonal shimmer sweep across the card surface
  late final AnimationController _shimmerCtrl;
  // Border glow pulse: violet ↔ gold (Itten complementary)
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    )..repeat();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selectedId != null
        ? widget.periods.firstWhere(
            (p) => p.id == widget.selectedId,
            orElse: () => widget.periods.first)
        : widget.periods.first;
    final priceRub = sel.basePriceKopeks / 100;
    final origRub  = sel.originalPriceKopeks > sel.basePriceKopeks
        ? sel.originalPriceKopeks / 100 : null;
    final traffic  = _trafficLabel(sel);
    final devices  = _devicesLabel(sel);

    return AnimatedBuilder(
      animation: Listenable.merge([_shimmerCtrl, _glow]),
      builder: (_, child) {
        final g = _glow.value;
        return Stack(
          children: [
            // ── Main card ─────────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                // Deep indigo gradient — same rich tone as Subscription hero card.
                gradient: const LinearGradient(
                  colors: [_cg1, _cg2],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(_r22),
                border: Border.all(
                  color: Color.lerp(
                    DS.violet.withValues(alpha: 0.28),
                    DS.gold.withValues(alpha: 0.50),
                    g,
                  )!,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: DS.violet.withValues(alpha: 0.10 + g * 0.18),
                    blurRadius: 50 + g * 22,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: DS.gold.withValues(alpha: g * 0.10),
                    blurRadius: 28,
                    offset: Offset.zero,
                  ),
                ],
              ),
              child: Column(children: [

                // ── Period selector ────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                  child: Row(children: [
                    for (int i = 0; i < widget.periods.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: _PeriodChip(
                          period: widget.periods[i],
                          selected: widget.periods[i].id == widget.selectedId,
                          isBest: widget.periods[i].id == widget.bestId,
                          onTap: () => widget.onPeriodChanged(widget.periods[i].id),
                        ),
                      ),
                    ],
                  ]),
                ),

                // ── Price block ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 0),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (origRub != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(children: [
                              Text(
                                '${origRub.toStringAsFixed(0)} ₽',
                                style: const TextStyle(
                                  color: DS.textFaint,
                                  fontSize: 15,
                                  decoration: TextDecoration.lineThrough,
                                  decorationColor: DS.textFaint,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: DS.gold.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '−${sel.discountPercent}%',
                                  style: const TextStyle(
                                      color: DS.gold,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800),
                                ),
                              ),
                            ]),
                          ),
                        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                    begin: const Offset(0, 0.15),
                                    end: Offset.zero)
                                    .animate(CurvedAnimation(
                                        parent: anim,
                                        curve: Curves.easeOut)),
                                child: child,
                              ),
                            ),
                            child: Text(
                              priceRub.toStringAsFixed(0),
                              key: ValueKey(sel.id),
                              style: const TextStyle(
                                color: DS.textPrimary, fontSize: 68,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -3, height: 1,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 10, left: 4),
                            child: Text('₽', style: TextStyle(
                                color: DS.textSecondary,
                                fontSize: 24,
                                fontWeight: FontWeight.w700)),
                          ),
                        ]),
                        const SizedBox(height: 5),
                        Text(
                          'за период · ${sel.label.toLowerCase()}',
                          style: const TextStyle(color: DS.textFaint, fontSize: 13),
                        ),
                      ]),
                    ),
                  ]),
                ),

                Container(
                    margin: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                    height: 1,
                    color: DS.border),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                  child: Row(children: [
                    _FeatureChip(
                        icon: Icons.bolt_rounded,
                        label: traffic,
                        color: _sky),
                    const SizedBox(width: 8),
                    _FeatureChip(
                        icon: Icons.devices_rounded,
                        label: devices,
                        color: DS.violet),
                    const SizedBox(width: 8),
                    const _FeatureChip(
                        icon: Icons.verified_user_rounded,
                        label: 'Без логов',
                        color: _teal),
                  ]),
                ),
              ]),
            ),

            // ── Diagonal shimmer sweep overlay ─────────────────────────────
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_r22),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(
                          -2.5 + _shimmerCtrl.value * 5.0, -1.0),
                        end: Alignment(
                          -2.0 + _shimmerCtrl.value * 5.0, 1.0),
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: 0.04),
                          Colors.white.withValues(alpha: 0.09),
                          Colors.white.withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static String _trafficLabel(PeriodOption p) {
    final tCfg = p.traffic;
    if (tCfg == null) return '∞ ГБ';
    int? val = tCfg.defaultValue;
    if (val == null && tCfg.options.isNotEmpty) {
      val = tCfg.options
          .firstWhere((o) => o.isDefault, orElse: () => tCfg.options.first)
          .value;
    }
    if (val == null || val == 0) return '∞ ГБ';
    return '$val ГБ';
  }

  static String _devicesLabel(PeriodOption p) {
    final dCfg = p.devices;
    if (dCfg == null) return '1 устр.';
    final val = dCfg.defaultValue ?? dCfg.minimum;
    return '$val устр.';
  }
}

// Period chip — pulsing amber glow on the "best value" chip
class _PeriodChip extends StatefulWidget {
  final PeriodOption period;
  final bool selected, isBest;
  final VoidCallback onTap;
  const _PeriodChip({
    required this.period, required this.selected,
    required this.isBest, required this.onTap,
  });

  @override
  State<_PeriodChip> createState() => _PeriodChipState();
}

class _PeriodChipState extends State<_PeriodChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double>   _glow;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _glow = CurvedAnimation(parent: _pulse, curve: Curves.easeInOut);
    if (widget.isBest) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PeriodChip old) {
    super.didUpdateWidget(old);
    if (widget.isBest && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.isBest && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Non-best chips keep the simple AnimatedContainer transition
    if (!widget.isBest) {
      return GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            gradient: widget.selected
                ? const LinearGradient(
                    colors: [DS.violet, _indigoD],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight)
                : null,
            color: widget.selected ? null : DS.border,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? Colors.transparent
                  : DS.violet.withValues(alpha: 0.22),
              width: 1.5,
            ),
            boxShadow: widget.selected
                ? [BoxShadow(
                    color: DS.violet.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4))]
                : null,
          ),
          child: _label(),
        ),
      );
    }

    // Best chip — animated pulse on border + shadow
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _glow,
        builder: (_, child) {
          final g = _glow.value;
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              gradient: widget.selected
                  ? const LinearGradient(
                      colors: [DS.violet, _indigoD],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight)
                  : null,
              color: widget.selected ? null : DS.border,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? Colors.transparent
                    : DS.gold.withValues(alpha: 0.48 + g * 0.42),
                width: 1.5,
              ),
              boxShadow: [
                if (widget.selected)
                  BoxShadow(
                    color: DS.violet.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  )
                else
                  BoxShadow(
                    color: DS.gold.withValues(alpha: 0.14 + g * 0.28),
                    blurRadius: 10 + g * 14,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: _label(),
          );
        },
      ),
    );
  }

  Widget _label() => Column(mainAxisSize: MainAxisSize.min, children: [
    Text(
      '★ ВЫГОДНО',
      style: TextStyle(
        color: widget.selected
            ? Colors.white.withValues(alpha: 0.8)
            : DS.gold,
        fontSize: 8,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    ),
    const SizedBox(height: 2),
    Text(
      widget.period.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: widget.selected ? Colors.white : DS.gold,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    ),
  ]);
}

// Feature chip row item
class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _FeatureChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.32)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(height: 5),
        Text(
          label,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ]),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Buy CTA button
// ═══════════════════════════════════════════════════════════════════════════

class _BuyButton extends StatelessWidget {
  final bool isLoggedIn, loading, hasBalance;
  final int? priceKopeks;   // null → "Выберите тариф"
  final VoidCallback onTap;
  const _BuyButton({
    required this.isLoggedIn, required this.loading,
    required this.hasBalance, required this.priceKopeks,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final needPay = isLoggedIn && !hasBalance && (priceKopeks ?? 0) > 0;
    final color   = needPay ? _teal : DS.violet;

    final String label;
    if (loading) {
      label = '';
    } else if (!isLoggedIn) {
      label = 'Войти через Telegram';
    } else if (priceKopeks == null) {
      label = 'Выберите тариф';
    } else if (needPay) {
      final rub = (priceKopeks! / 100).toStringAsFixed(0);
      label = 'Оплатить $rub ₽';
    } else {
      final rub = (priceKopeks! / 100).toStringAsFixed(0);
      label = 'Подключить за $rub ₽';
    }

    return GestureDetector(
      onTap: loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 62,
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color, Color.lerp(color, Colors.black, 0.28)!],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(_r16),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: loading ? 0.12 : 0.38),
              blurRadius: 28, offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!isLoggedIn)
                    const Icon(Icons.telegram_rounded, color: Colors.white, size: 20)
                  else
                    PhosphorIcon(PhosphorIconsBold.shieldCheck,
                        color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(label, style: const TextStyle(
                      color: Colors.white, fontSize: 17,
                      fontWeight: FontWeight.w700, letterSpacing: 0.1)),
                ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Referral teaser — surfaced while the purchase decision is being made
//  (not just after checkout, where the success overlay already has its own
//  invite nudge). Framed as lowering the real cost, since that's the
//  strongest angle right where someone is deciding whether to pay.
// ═══════════════════════════════════════════════════════════════════════════

class _ReferralBanner extends StatelessWidget {
  final ReferralInfo info;
  final VoidCallback onTap;
  const _ReferralBanner({required this.info, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final commission = info.commissionPercent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: DS.surface1,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(color: DS.violet.withValues(alpha: 0.30)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(PhosphorIconsFill.gift, color: DS.violet, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Снизьте свою цену',
                    style: TextStyle(
                        color: DS.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  commission > 0
                      ? 'Приглашайте друзей — получайте $commission% с каждого их платежа'
                      : 'Приглашайте друзей и получайте бонусы',
                  style: const TextStyle(color: DS.textSecondary, fontSize: 11.5, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right_rounded,
              color: DS.violet.withValues(alpha: 0.7), size: 20),
        ]),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outline_rounded, size: 11, color: DS.textFaint),
          SizedBox(width: 5),
          Text('Безопасная оплата · YooKassa',
              style: TextStyle(color: DS.textFaint, fontSize: 11)),
        ],
      ),
      const SizedBox(height: 5),
      // Reassurance line — reduces pre-purchase hesitation.
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(PhosphorIconsFill.lightning,
              size: 11, color: DS.gold.withValues(alpha: 0.85)),
          const SizedBox(width: 5),
          const Text('Доступ открывается сразу после оплаты',
              style: TextStyle(color: DS.textFaint, fontSize: 11)),
        ],
      ),
    ],
  );
}

