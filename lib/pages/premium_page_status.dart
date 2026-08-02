part of 'premium_page.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Subscription status band (replaces the old large _ActiveCard)
//
//  Design: Itten complementary pair — cool indigo base + warm gold accent.
//  Compact horizontal strip so the action section (renew/change) is the focus.
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  Active membership card — compact context banner.
//  Full subscription stats live on the Subscription page; here we show only
//  the key membership signal (status + plan + days) before the action buttons.
//  Background #1C1A3A is visibly brighter than aurora #0D0A22.
// ═══════════════════════════════════════════════════════════════════════════

class _ActiveCard extends StatelessWidget {
  final MeSubscription sub;
  const _ActiveCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final expDate  = sub.expireDate;
    final daysLeft = expDate?.difference(DateTime.now()).inDays;
    final planName = sub.planName ?? (sub.isTrial ? 'Пробный' : 'Premium');

    // Urgency palette: calm gold → warm amber → alert rose
    final Color accent = daysLeft == null || daysLeft > 7
        ? DS.gold
        : daysLeft > 3
            ? const Color(0xFFFBBF24)
            : DS.rose;

    // Badge colour: teal for a healthy active sub (green = "all OK" signal).
    // Trial and urgency states keep the urgency accent.
    final Color badgeColor = (!sub.isTrial && accent == DS.gold)
        ? _teal
        : accent;

    final String daysLabel = daysLeft == null
        ? '—'
        : daysLeft >= 0
            ? '$daysLeft ${_pluralDays(daysLeft)}'
            : 'истекла';

    final String expiryLabel = expDate == null
        ? '—'
        : '${expDate.day.toString().padLeft(2, '0')}'
          '.${expDate.month.toString().padLeft(2, '0')}'
          '.${expDate.year}';

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_r16),
        gradient: const LinearGradient(
          colors: [_cg1, _cg2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: accent.withValues(alpha: 0.30),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── Top stripe — animated shimmer (Itten: gold ↔ violet) ───────────
        _ShimmerStripe(leading: accent, trailing: DS.violet),

        // ── Main row: status pill + plan name + days remaining ────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _PulsingDot(color: badgeColor),
                const SizedBox(width: 5),
                Text(
                  sub.isTrial ? 'ПРОБНЫЙ' : 'АКТИВНА',
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                planName,
                style: const TextStyle(
                  color: _t0, fontSize: 14, fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              daysLabel,
              style: TextStyle(
                color: accent, fontSize: 14, fontWeight: FontWeight.w700,
              ),
            ),
          ]),
        ),

        // ── Bottom row: expiry + autopay ──────────────────────────────────
        Container(height: 1, color: _b0),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 11),
          child: Row(children: [
            PhosphorIcon(PhosphorIconsRegular.calendarBlank,
                color: accent, size: 13),
            const SizedBox(width: 5),
            Text(
              'до $expiryLabel',
              style: TextStyle(
                color: accent, fontSize: 12, fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            PhosphorIcon(
              PhosphorIconsRegular.arrowsClockwise,
              color: sub.autopayEnabled ? _teal : _t2,
              size: 13,
            ),
            const SizedBox(width: 5),
            Text(
              sub.autopayEnabled ? 'Автопродление' : 'Без автопродления',
              style: TextStyle(
                color: sub.autopayEnabled ? _teal : _t2, fontSize: 12,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Expired subscription band
// ═══════════════════════════════════════════════════════════════════════════

class _ExpiredCard extends StatelessWidget {
  final MeSubscription sub;
  const _ExpiredCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final planName  = sub.planName ?? 'Premium';
    final expiredAt = sub.formattedExpiry;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_r16),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF2A1420),   // заметный тёмно-розовый — хорошо виден на фоне страницы
            const Color(0xFF1E0E18),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: DS.rose.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Stack(
        children: [
          // Лёгкое свечение сверху-слева
          Positioned(
            top: 0, left: 0, right: 0, height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomCenter,
                  colors: [
                    DS.rose.withValues(alpha: 0.10),
                    DS.rose.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Row(children: [
              // Иконка в цветном контейнере
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: DS.rose.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: PhosphorIcon(
                    PhosphorIconsFill.warningCircle,
                    color: DS.rose, size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      planName,
                      style: const TextStyle(
                          color: _t0, fontSize: 15,
                          fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Истекла $expiredAt',
                      style: TextStyle(
                          color: DS.rose.withValues(alpha: 0.75),
                          fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plan context strip — sits between status card and ActionToggle.
//  Active: shows exact expiry date + autopay state.
//  Expired: shows what the plan included (context for renewal decision).
// ═══════════════════════════════════════════════════════════════════════════

class _PlanContextStrip extends StatelessWidget {
  final MeSubscription sub;
  final bool expired;
  final String? cheapestPriceLabel;   // e.g. "99 ₽/мес"
  const _PlanContextStrip({required this.sub, this.expired = false, this.cheapestPriceLabel});

  @override
  Widget build(BuildContext context) {
    if (expired) {
      // "What you had" — context for renewal
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _premSurface,
          borderRadius: BorderRadius.circular(_r16),
          border: Border.all(color: _b1),
        ),
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 16, runSpacing: 7,
                children: [
                  _CtxItem(
                    icon: Icons.devices_rounded,
                    label: '${sub.deviceLimit} ${_devWord(sub.deviceLimit)}',
                    color: _t1,
                  ),
                  _CtxItem(
                    icon: sub.trafficLimitGb == 0
                        ? Icons.all_inclusive_rounded
                        : Icons.storage_rounded,
                    label: sub.trafficLimitGb == 0
                        ? 'Без лимита'
                        : '${sub.trafficLimitGb} ГБ',
                    color: _t1,
                  ),
                ],
              ),
            ),
            if (cheapestPriceLabel != null) ...[
              const SizedBox(width: 12),
              Text(
                cheapestPriceLabel!,
                style: const TextStyle(
                  color: _t0, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      );
    }

    // Active: exact expiry + autopay status
    final expDate  = sub.expireDate;
    final daysLeft = expDate?.difference(DateTime.now()).inDays;
    final urgency  = (daysLeft != null && daysLeft <= 7) ? DS.rose
                   : (daysLeft != null && daysLeft <= 30) ? const Color(0xFFFBBF24)
                   : DS.gold;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          if (expDate != null)
            _CtxItem(
              icon: PhosphorIconsRegular.calendarCheck,
              label: 'до ${sub.formattedExpiry}',
              color: urgency,
            ),
          _CtxItem(
            icon: sub.autopayEnabled
                ? PhosphorIconsFill.arrowsClockwise
                : PhosphorIconsRegular.arrowsClockwise,
            label: sub.autopayEnabled ? 'Автопродление' : 'Без автопродления',
            color: sub.autopayEnabled ? _teal : _t2,
          ),
        ],
      ),
    );
  }

  static String _devWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'устройств';
    if (m10 == 1) return 'устройство';
    if (m10 >= 2 && m10 <= 4) return 'устройства';
    return 'устройств';
  }
}

// One icon + label pair used in _PlanContextStrip
class _CtxItem extends StatelessWidget {
  final IconData icon;
  final String   label;
  final Color    color;
  const _CtxItem({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color.withValues(alpha: 0.80), size: 13),
      const SizedBox(width: 5),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    ],
  );
}

class _TrafficBar extends StatefulWidget {
  final double fraction;
  const _TrafficBar({required this.fraction});

  @override
  State<_TrafficBar> createState() => _TrafficBarState();
}

class _TrafficBarState extends State<_TrafficBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (context, child) {
      final v = _anim.value * widget.fraction;
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 7,
          color: _b1,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: v > 0.85
                      ? [DS.gold, DS.rose]
                      : [_teal, _sky],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
      );
    },
  );
}

// ── Animated shimmer stripe — white flash sweeping left → right ──────────────

class _ShimmerStripe extends StatefulWidget {
  final Color leading;   // e.g. gold / amber / rose (urgency accent)
  final Color trailing;  // e.g. violet (brand colour)
  const _ShimmerStripe({required this.leading, required this.trailing});

  @override
  State<_ShimmerStripe> createState() => _ShimmerStripeState();
}

class _ShimmerStripeState extends State<_ShimmerStripe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 3,
    child: Stack(children: [
      // Base: static colour band (always visible)
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [widget.leading, widget.trailing],
            ),
          ),
        ),
      ),
      // Sweep: a diagonal white flash that glides left → right.
      // x goes −1.6 → +1.6, so the beam is fully off-screen at both
      // endpoints and the loop restart is seamless (no jump).
      AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) {
          final x = -1.6 + _ctrl.value * 3.2;
          return Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(x - 0.4, -1),
                  end:   Alignment(x + 0.4,  1),
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ]),
  );
}


class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.7, end: 1.3)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(
            color: widget.color.withValues(alpha: 0.7), blurRadius: 5)],
      ),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Manage section — renew / traffic / devices
// ═══════════════════════════════════════════════════════════════════════════

class _ManageSection extends StatelessWidget {
  final MeSubscription sub;
  final SubscriptionOptions? options;
  final bool loading;

  // Renew
  final String? renewPeriodId;
  final String? bestRenewId;
  final Map<String, int?> renewPrices;
  final ValueChanged<String> onRenewPeriodChanged;
  final VoidCallback onRenewTap;

  // Traffic
  final bool trafficAvailable;
  final List<TrafficTopupPackage> topupPackages;
  final int? selectedTrafficGb;
  final Map<int, int?> trafficPrices;
  final ValueChanged<int> onTrafficChanged;
  final VoidCallback onTrafficTap;

  // Devices
  final bool devicesAvailable;
  final List<int> devicesOpts;
  final int? selectedDevicesAdd;
  final Map<int, int?> devicesPrices;
  final ValueChanged<int> onDevicesChanged;
  final VoidCallback onDevicesTap;

  const _ManageSection({
    required this.sub,
    required this.options,
    required this.loading,
    required this.renewPeriodId,
    required this.bestRenewId,
    required this.renewPrices,
    required this.onRenewPeriodChanged,
    required this.onRenewTap,
    required this.trafficAvailable,
    required this.topupPackages,
    required this.selectedTrafficGb,
    required this.trafficPrices,
    required this.onTrafficChanged,
    required this.onTrafficTap,
    required this.devicesAvailable,
    required this.devicesOpts,
    required this.selectedDevicesAdd,
    required this.devicesPrices,
    required this.onDevicesChanged,
    required this.onDevicesTap,
  });

  @override
  Widget build(BuildContext context) {
    if (options == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 40),
          child: CircularProgressIndicator(color: DS.violet, strokeWidth: 2.5),
        ),
      );
    }

    final selRenewKopeks = renewPeriodId != null ? renewPrices[renewPeriodId] : null;

    final devicesAllFree = devicesOpts.isNotEmpty &&
        devicesPrices.values.isNotEmpty &&
        devicesPrices.values.every((p) => p != null && p == 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // ── RENEW ──────────────────────────────────────────────────────────────
      _SectionHeader(label: 'ПРОДЛИТЬ', icon: Icons.refresh_rounded),
      const SizedBox(height: 10),
      for (int i = 0; i < options!.periods.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        _PeriodTile(
          period: options!.periods[i],
          selected: options!.periods[i].id == renewPeriodId,
          priceKopeks: renewPrices[options!.periods[i].id],
          months: _parseMonths(options!.periods[i].label),
          onTap: () => onRenewPeriodChanged(options!.periods[i].id),
        ),
      ],
      const SizedBox(height: 14),
      _ActionBtn(
        loading: loading,
        disabled: renewPeriodId == null || selRenewKopeks == null,
        color: DS.violet,
        label: selRenewKopeks != null
            ? 'Продлить за ${(selRenewKopeks / 100).toStringAsFixed(0)} ₽'
            : 'Продлить подписку',
        onTap: onRenewTap,
      ),

      // ── TRAFFIC ────────────────────────────────────────────────────────────
      if (trafficAvailable && topupPackages.isNotEmpty) ...[
        const SizedBox(height: 24),
        _SectionHeader(label: 'ДОКУПИТЬ ТРАФИК', icon: Icons.data_usage_rounded),
        const SizedBox(height: 12),
        _HorizontalOptionRow(
          items: topupPackages.map((p) {
            final k = trafficPrices[p.gb];
            return _OptionItem(
              id: p.gb.toString(),
              topLabel: '+${p.gb} ГБ',
              bottomLabel: k == null ? '…' : (k == 0 ? 'Бесп.' : '${(k / 100).toStringAsFixed(0)} ₽'),
              selected: p.gb == selectedTrafficGb,
              accentColor: _sky,
            );
          }).toList(),
          onSelect: (id) => onTrafficChanged(int.parse(id)),
        ),
        const SizedBox(height: 14),
        _ActionBtn(
          loading: loading,
          disabled: selectedTrafficGb == null || trafficPrices[selectedTrafficGb] == null,
          color: _sky,
          label: selectedTrafficGb != null && trafficPrices[selectedTrafficGb] != null
              ? 'Добавить $selectedTrafficGb ГБ за ${(trafficPrices[selectedTrafficGb]! / 100).toStringAsFixed(0)} ₽'
              : 'Добавить трафик',
          onTap: onTrafficTap,
        ),
      ],

      // ── DEVICES ────────────────────────────────────────────────────────────
      if (devicesAvailable && devicesOpts.isNotEmpty && !devicesAllFree) ...[
        const SizedBox(height: 24),
        _SectionHeader(label: 'УСТРОЙСТВА', icon: Icons.devices_rounded),
        const SizedBox(height: 12),
        _HorizontalOptionRow(
          items: devicesOpts.map((add) {
            final target = sub.deviceLimit + add;
            final k      = devicesPrices[add];
            return _OptionItem(
              id: add.toString(),
              topLabel: '+$add устр.',
              bottomLabel: k == null ? '…' : (k == 0 ? 'Бесп.' : '${(k / 100).toStringAsFixed(0)} ₽'),
              subLabel: '${sub.deviceLimit}→$target',
              selected: add == selectedDevicesAdd,
              accentColor: _indigoB,
            );
          }).toList(),
          onSelect: (id) => onDevicesChanged(int.parse(id)),
        ),
        const SizedBox(height: 14),
        _ActionBtn(
          loading: loading,
          disabled: selectedDevicesAdd == null || devicesPrices[selectedDevicesAdd] == null,
          color: _indigoB,
          label: selectedDevicesAdd != null && devicesPrices[selectedDevicesAdd] != null
              ? 'Добавить $selectedDevicesAdd устр. за ${(devicesPrices[selectedDevicesAdd]! / 100).toStringAsFixed(0)} ₽'
              : 'Добавить устройства',
          onTap: onDevicesTap,
        ),
      ],

      const SizedBox(height: 6),
      const _Disclaimer(),
    ]);
  }

}

// ═══════════════════════════════════════════════════════════════════════════
//  Period tile — full-width selectable row (used in manage/renew, prices async)
// ═══════════════════════════════════════════════════════════════════════════

class _PeriodTile extends StatelessWidget {
  final PeriodOption period;
  final bool selected;
  final int? priceKopeks;
  final int? months;
  final VoidCallback onTap;

  const _PeriodTile({
    required this.period,
    required this.selected,
    required this.priceKopeks,
    required this.months,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final priceRub   = priceKopeks != null ? priceKopeks! / 100 : null;
    final monthlyRub = (months != null && months! > 1 && priceRub != null)
        ? priceRub / months!
        : null;
    final discount   = period.discountPercent;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? DS.violet.withValues(alpha: 0.10)
              : _premSurface,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(
            color: selected ? DS.violet : _b1,
            width: selected ? 1.5 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(
                  color: DS.violet.withValues(alpha: 0.15),
                  blurRadius: 14, offset: const Offset(0, 4))]
              : null,
        ),
        child: Row(children: [

          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? DS.violet : Colors.transparent,
              border: Border.all(
                color: selected ? DS.violet : _t2,
                width: 2,
              ),
            ),
            child: selected
                ? const Center(
                    child: Icon(Icons.check_rounded, size: 11, color: Colors.white))
                : null,
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  period.label,
                  style: TextStyle(
                    color: selected ? _t0 : _t1,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (monthlyRub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '~${monthlyRub.round()} ₽/мес',
                    style: TextStyle(
                      color: selected
                          ? DS.violet.withValues(alpha: 0.75)
                          : _t2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),

          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (discount > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: 5),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _teal.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _teal.withValues(alpha: 0.30),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    '−$discount%',
                    style: const TextStyle(
                      color: _teal,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              if (priceRub != null)
                Text(
                  '${priceRub.toStringAsFixed(0)} ₽',
                  style: TextStyle(
                    color: selected ? DS.violet : _t0,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                )
              else
                const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: _t2)),
            ],
          ),
        ]),
      ),
    );
  }
}

// Section header
class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionHeader({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, color: _t2, size: 13),
    const SizedBox(width: 7),
    Text(label, style: const TextStyle(
        color: _t2, fontSize: 10,
        fontWeight: FontWeight.w800, letterSpacing: 1.8)),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: _b1)),
  ]);
}

// Option item data
class _OptionItem {
  final String id;
  final String topLabel;
  final String bottomLabel;
  final String? subLabel;
  final bool selected;
  final Color accentColor;

  const _OptionItem({
    required this.id,
    required this.topLabel,
    required this.bottomLabel,
    this.subLabel,
    required this.selected,
    required this.accentColor,
  });
}

// Horizontal scrollable option row
class _HorizontalOptionRow extends StatelessWidget {
  final List<_OptionItem> items;
  final ValueChanged<String> onSelect;
  const _HorizontalOptionRow({required this.items, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (items.length <= 4) {
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _OptionCard(item: items[i], onTap: () => onSelect(items[i].id))),
            ],
          ],
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: _OptionCard(item: items[i], onTap: () => onSelect(items[i].id)),
          ),
        ],
      ]),
    );
  }
}

// Individual selectable option card
class _OptionCard extends StatelessWidget {
  final _OptionItem item;
  final VoidCallback onTap;
  const _OptionCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 10),
      decoration: BoxDecoration(
        color: item.selected
            ? item.accentColor.withValues(alpha: 0.12)
            : _premSurface,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(
          color: item.selected ? item.accentColor : _b1,
          width: item.selected ? 1.5 : 1,
        ),
        boxShadow: item.selected
            ? [BoxShadow(
                color: item.accentColor.withValues(alpha: 0.18),
                blurRadius: 14, offset: const Offset(0, 4))]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
        Text(
          item.topLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: item.selected ? item.accentColor : _t1,
            fontSize: 13, fontWeight: FontWeight.w700,
          ),
        ),
        if (item.subLabel != null) ...[
          const SizedBox(height: 3),
          Text(
            item.subLabel!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: item.selected ? item.accentColor.withValues(alpha: 0.7) : _t2,
              fontSize: 9,
            ),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          item.bottomLabel,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: item.selected ? item.accentColor : _t0,
            fontSize: 12, fontWeight: FontWeight.w800,
          ),
        ),
      ]),
    ),
  );
}

// Shared action button for manage section
class _ActionBtn extends StatefulWidget {
  final bool loading, disabled;
  final Color color;
  final String label;
  final VoidCallback onTap;
  const _ActionBtn({
    required this.loading, required this.disabled,
    required this.color, required this.label, required this.onTap,
  });

  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: _pressed
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 400),
      curve: _pressed ? Curves.easeIn : Curves.elasticOut,
      child: GestureDetector(
        onTapDown:  (_) { if (!widget.loading && !widget.disabled) setState(() => _pressed = true); },
        onTapUp:    (_) { widget.onTap(); setState(() => _pressed = false); },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 56, width: double.infinity,
          decoration: BoxDecoration(
            gradient: widget.disabled
                ? null
                : LinearGradient(
                    colors: [widget.color, Color.lerp(widget.color, Colors.black, 0.28)!],
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
            color: widget.disabled ? _premSurface : null,
            borderRadius: BorderRadius.circular(_r16),
            border: widget.disabled ? Border.all(color: _b1) : null,
            boxShadow: widget.disabled ? null : [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.30),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Center(
            child: widget.loading
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                    child: Text(
                      widget.label,
                      key: ValueKey(widget.label),
                      style: TextStyle(
                        color: widget.disabled ? _t2 : Colors.white,
                        fontSize: 15, fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Not-logged-in card
// ═══════════════════════════════════════════════════════════════════════════

class _LoginCard extends StatelessWidget {
  final VoidCallback onLogin;
  const _LoginCard({required this.onLogin});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(28, 36, 28, 32),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_cg1, _cg2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_r22),
      border: Border.all(color: DS.violet.withValues(alpha: 0.25)),
    ),
    child: Column(children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [DS.violet, _indigoD],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: DS.violet.withValues(alpha: 0.45),
                blurRadius: 28, offset: const Offset(0, 8)),
          ],
        ),
        child: const Icon(Icons.lock_person_rounded, color: Colors.white, size: 38),
      ),
      const SizedBox(height: 22),
      const Text(
        'Войдите, чтобы\nувидеть тарифы',
        textAlign: TextAlign.center,
        style: TextStyle(
            color: _t0, fontSize: 22,
            fontWeight: FontWeight.w800, height: 1.25, letterSpacing: -0.3),
      ),
      const SizedBox(height: 8),
      const Text(
        'Тарифы формируются индивидуально.\nАвторизуйтесь через Telegram.',
        textAlign: TextAlign.center,
        style: TextStyle(color: _t1, fontSize: 14, height: 1.55),
      ),
      const SizedBox(height: 28),
      TelegramLoginButton(onTap: onLogin),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Error card
// ═══════════════════════════════════════════════════════════════════════════

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [_cg1, _cg2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_r22),
      border: Border.all(color: _b1),
    ),
    child: Column(children: [
      Container(
        width: 60, height: 60,
        decoration: BoxDecoration(
            color: DS.rose.withValues(alpha: 0.10), shape: BoxShape.circle),
        child: const Icon(Icons.wifi_off_rounded, color: DS.rose, size: 28),
      ),
      const SizedBox(height: 16),
      const Text('Не удалось загрузить тарифы',
          textAlign: TextAlign.center,
          style: TextStyle(color: _t0, fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('Проверьте подключение к интернету',
          textAlign: TextAlign.center,
          style: TextStyle(color: _t1, fontSize: 13)),
      const SizedBox(height: 20),
      GestureDetector(
        onTap: onRetry,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
          decoration: BoxDecoration(
              color: DS.violet.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(50),
              border: Border.all(color: DS.violet.withValues(alpha: 0.35))),
          child: const Text('Попробовать снова',
              style: TextStyle(color: DS.violet, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  Payment polling card
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
//  Reserve-squad grace card — subscription genuinely expired, but we've left
//  a small, temporary window open while the user decides to renew. Warm/
//  reassuring tone on purpose: this is a courtesy, not a punishment — the
//  copy should read like "we've got you covered for now", not an error.
// ═══════════════════════════════════════════════════════════════════════════

class _GraceCard extends StatelessWidget {
  final MeSubscription sub;
  const _GraceCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final expDate = sub.expireDate;
    final now = DateTime.now();
    final hoursLeft = expDate?.difference(now).inHours;
    final daysLeft = expDate?.difference(now).inDays;

    final String timeLeftLabel;
    if (hoursLeft == null || hoursLeft <= 0) {
      timeLeftLabel = 'вот-вот закончится';
    } else if (daysLeft != null && daysLeft >= 1) {
      timeLeftLabel = 'ещё $daysLeft ${_pluralDays(daysLeft)}';
    } else {
      timeLeftLabel = 'ещё около $hoursLeft ч';
    }

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_r16),
        gradient: const LinearGradient(
          colors: [_cg1, _cg2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: DS.gold.withValues(alpha: 0.32), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: DS.gold.withValues(alpha: 0.14),
            blurRadius: 28,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: DS.gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: PhosphorIcon(
                  PhosphorIconsFill.lifebuoy,
                  color: DS.gold, size: 20,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Мы оставили вам немного доступа',
                    style: TextStyle(
                      color: _t0, fontSize: 15, fontWeight: FontWeight.w700, height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Подписка закончилась, но пока вы решаете — '
                    'мы включили небольшой запасной доступ ($timeLeftLabel). '
                    'Продлите, чтобы вернуть полный тариф.',
                    style: const TextStyle(color: _t1, fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _pluralDays(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'дней';
    if (m10 == 1) return 'день';
    if (m10 >= 2 && m10 <= 4) return 'дня';
    return 'дней';
  }
}

