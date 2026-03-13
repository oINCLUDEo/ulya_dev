import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/me_response.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../theme/app_colors.dart';
import '../widgets/purple_header.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────

class _DS {
  // Accent palette
  static const violet = Color(0xFF7C6FF7);
  static const violetDim = Color(0xFF5A52C0);
  static const emerald = Color(0xFF34D399);
  static const amber = Color(0xFFFBBF24);
  static const rose = Color(0xFFF87171);

  // Surfaces
  static const surface0 = Color(0xFF0F0F14);
  static const surface1 = Color(0xFF17171F);
  static const surface2 = Color(0xFF1E1E2A);
  static const surface3 = Color(0xFF26263A);

  // Text
  static const textPrimary = Color(0xFFEEEEF8);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted = Color(0xFF55556A);

  // Borders
  static const border = Color(0xFF2A2A3D);
  static const borderAccent = Color(0xFF4A44AA);

  static const radius = 20.0;
  static const radiusSm = 12.0;
  static const radiusXs = 8.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// PremiumPage – stateful shell (logic unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class PremiumPage extends StatefulWidget {
  const PremiumPage({super.key});

  @override
  State<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends State<PremiumPage> with WidgetsBindingObserver {
  SubscriptionOptions? _options;
  CalcResult? _calc;
  bool _loadingOptions = false;
  bool _loadingCalc = false;
  bool _purchasing = false;

  Timer? _pollTimer;
  int _pollAttempt = 0;
  bool _pollingForPayment = false;
  bool _pendingPaymentPoll = false;
  static const int _maxPollAttempts = 30;
  static const Duration _pollInterval = Duration(seconds: 4);

  String? _selectedPeriodId;
  int? _selectedTraffic;
  int? _selectedDevices;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    _loadOptions();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingPaymentPoll) {
      _pendingPaymentPoll = false;
      _startPaymentPolling();
    }
  }

  void _startPaymentPolling() {
    if (!mounted) return;
    _pollTimer?.cancel();
    setState(() {
      _pollingForPayment = true;
      _pollAttempt = 0;
    });
    _pollTimer = Timer.periodic(_pollInterval, _onPollTick);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refresh();
    if (!mounted) { timer.cancel(); return; }

    final me = meNotifier.value;
    final sub = me?.subscription;
    final confirmed = sub != null && sub.isActive && !sub.isTrial;

    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel();
      _pollTimer = null;
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        await _loadOptions();
        if (mounted) _showSnackBar('✅ Подписка активирована!', isError: false);
      } else {
        if (mounted) {
          _showSnackBar('Платёж ещё не подтверждён. Проверьте статус позже.', isError: false);
        }
      }
    }
  }

  void _onAuthChanged() { if (mounted) _loadOptions(); }
  void _onMeChanged() { if (mounted) setState(() {}); }

  Future<void> _loadOptions() async {
    final auth = authStateNotifier.value;
    if (!auth.isLoggedIn) {
      if (mounted) setState(() => _options = null);
      return;
    }
    if (mounted) setState(() => _loadingOptions = true);
    try {
      final opts = await SubscriptionApiService.getOptions();
      if (mounted) {
        setState(() {
          _options = opts;
          if (opts != null && opts.periods.isNotEmpty) {
            _selectedPeriodId ??= opts.periods.first.id;
            if (_selectedTraffic == null) {
              final period = opts.periods.first;
              final traffic = period.traffic;
              if (traffic != null) {
                _selectedTraffic = traffic.defaultValue ?? traffic.currentValue;
                if (_selectedTraffic == null && traffic.options.isNotEmpty) {
                  _selectedTraffic = traffic.options.first.value;
                }
              }
            }
            if (_selectedDevices == null) {
              final period = opts.periods.first;
              final devices = period.devices;
              if (devices != null) {
                _selectedDevices = devices.defaultValue ?? devices.currentValue ?? devices.minimum;
              } else {
                _selectedDevices = 1;
              }
            }
          }
        });
        await _recalcPrice();
      }
    } catch (e) {
      debugPrint('PremiumPage._loadOptions error: $e');
    }
    if (mounted) setState(() => _loadingOptions = false);
  }

  Future<void> _recalcPrice() async {
    final periodId = _selectedPeriodId;
    if (periodId == null) return;
    if (mounted) setState(() => _loadingCalc = true);
    try {
      final result = await SubscriptionApiService.calcPrice(
        periodId: periodId,
        trafficValue: _selectedTraffic,
        devices: _selectedDevices,
      );
      if (mounted) setState(() => _calc = result);
    } catch (e) {
      debugPrint('PremiumPage._recalcPrice error: $e');
    }
    if (mounted) setState(() => _loadingCalc = false);
  }

  void _onPeriodSelected(String periodId) {
    if (_selectedPeriodId == periodId) return;
    final opts = _options;
    if (opts == null) return;
    setState(() {
      _selectedPeriodId = periodId;
      final period = opts.periods.firstWhere((p) => p.id == periodId, orElse: () => opts.periods.first);
      final traffic = period.traffic;
      if (traffic != null && traffic.options.isNotEmpty) {
        final defaultOpt = traffic.options.where((o) => o.isDefault).firstOrNull ?? traffic.options.first;
        _selectedTraffic = defaultOpt.value;
      }
      final devices = period.devices;
      if (devices != null) {
        _selectedDevices = devices.defaultValue ?? devices.minimum;
      }
    });
    _recalcPrice();
  }

  void _onTrafficSelected(int value) {
    if (_selectedTraffic == value) return;
    setState(() => _selectedTraffic = value);
    _recalcPrice();
  }

  void _onDevicesSelected(int value) {
    if (_selectedDevices == value) return;
    setState(() => _selectedDevices = value);
    _recalcPrice();
  }

  Future<void> _onBuyPressed() async {
    final periodId = _selectedPeriodId;
    if (periodId == null) return;
    setState(() => _purchasing = true);
    try {
      final result = await SubscriptionApiService.buySubscription(
        periodId: periodId,
        trafficValue: _selectedTraffic,
        devices: _selectedDevices,
      );
      if (!mounted) return;
      if (result == null) {
        _showSnackBar('Ошибка соединения с сервером', isError: true);
      } else if (result.isSuccess) {
        _showSnackBar('✅ Подписка активирована!', isError: false);
        await MeService.refresh();
        await _loadOptions();
      } else if (result.requiresPayment && result.paymentUrl != null) {
        await _openPaymentUrl(result.paymentUrl!);
      } else {
        _showSnackBar(result.message ?? 'Ошибка при покупке', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnackBar('Ошибка: $e', isError: true);
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _onUpgradePressed(String periodId, {int? trafficAdd, int? devicesAdd}) async {
    setState(() => _purchasing = true);
    try {
      final result = await SubscriptionApiService.upgradeSubscription(
        periodId: periodId,
        trafficAdd: trafficAdd,
        devicesAdd: devicesAdd,
      );
      if (!mounted) return;
      if (result == null) {
        _showSnackBar('Ошибка соединения с сервером', isError: true);
      } else if (result.isSuccess) {
        _showSnackBar('✅ Подписка улучшена!', isError: false);
        await MeService.refresh();
        await _loadOptions();
      } else if (result.requiresPayment && result.paymentUrl != null) {
        await _openPaymentUrl(result.paymentUrl!);
      } else {
        _showSnackBar(result.message ?? 'Ошибка при улучшении', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnackBar('Ошибка: $e', isError: true);
    }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _openPaymentUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          _showSnackBar('Страница оплаты открыта. После оплаты вернитесь в приложение.', isError: false);
          _pendingPaymentPoll = true;
        }
      } else {
        if (mounted) _showSnackBar('Не удалось открыть страницу оплаты', isError: true);
      }
    } catch (e) {
      if (mounted) _showSnackBar('Ошибка при открытии оплаты', isError: true);
    }
  }

  void _showSnackBar(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
        backgroundColor: isError ? _DS.rose : _DS.emerald,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.radiusSm)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me = meNotifier.value;
    final sub = me?.subscription;
    final hasActivePaidSub = sub != null && sub.isActive && !sub.isTrial;
    final isNewUser = !auth.isLoggedIn || (sub == null && !hasActivePaidSub);

    return Scaffold(
      backgroundColor: _DS.surface0,
      body: RefreshIndicator(
        color: _DS.violet,
        backgroundColor: _DS.surface2,
        onRefresh: _loadOptions,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // ── Header ──────────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: _PremiumHeader(hasActiveSub: hasActivePaidSub),
            ),

            // ── Body ────────────────────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!auth.isLoggedIn) ...[
                    _BenefitsSection(),
                    const SizedBox(height: 16),
                    _NotLoggedInCard(onLoginTap: () => showAuthBottomSheet(context)),
                  ] else if (_pollingForPayment) ...[
                    const SizedBox(height: 32),
                    const _PaymentPollingCard(),
                  ] else if (_loadingOptions && _options == null) ...[
                    const SizedBox(height: 100),
                    const Center(child: _LoadingIndicator()),
                  ] else if (_options != null) ...[
                    // Balance
                    _BalanceCard(
                      balanceRub: _options!.balanceRub,
                      currency: _options!.currency,
                    ),
                    const SizedBox(height: 12),

                    if (hasActivePaidSub) ...[
                      _SectionLabel('Продлить подписку'),
                      const SizedBox(height: 8),
                      _UpgradeDiffCard(
                        sub: sub,
                        options: _options!,
                        onUpgrade: _onUpgradePressed,
                        loading: _purchasing,
                      ),
                    ] else ...[
                      if (isNewUser) ...[
                        _BenefitsSection(),
                        const SizedBox(height: 16),
                      ],
                      _SectionLabel(
                        sub?.isTrial == true
                            ? 'Перейти на платную подписку'
                            : 'Настройте подписку',
                      ),
                      const SizedBox(height: 8),
                      _SubscriptionBuilderCard(
                        options: _options!,
                        selectedPeriodId: _selectedPeriodId,
                        selectedTraffic: _selectedTraffic,
                        selectedDevices: _selectedDevices,
                        onPeriodSelected: _onPeriodSelected,
                        onTrafficSelected: _onTrafficSelected,
                        onDevicesSelected: _onDevicesSelected,
                      ),
                      const SizedBox(height: 12),

                      _PricePreviewCard(
                        calc: _calc,
                        loading: _loadingCalc,
                        balanceKopeks: _options!.balanceKopeks,
                      ),
                      const SizedBox(height: 16),

                      _BuyButton(
                        loading: _purchasing || _loadingCalc,
                        onPressed: _onBuyPressed,
                        totalKopeks: _calc?.totalKopeks,
                        hasEnoughBalance: _options!.balanceKopeks >= (_calc?.totalKopeks ?? 0),
                      ),
                      const SizedBox(height: 10),
                      const _PaymentDisclaimer(),
                    ],
                  ] else ...[
                    _ErrorCard(onRetry: _loadOptions),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header
// ─────────────────────────────────────────────────────────────────────────────

class _PremiumHeader extends StatelessWidget {
  final bool hasActiveSub;
  const _PremiumHeader({required this.hasActiveSub});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 20, 20, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Премиум',
                  style: TextStyle(
                    color: _DS.textPrimary,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  hasActiveSub ? 'Управление подпиской' : 'Выберите тариф',
                  style: const TextStyle(color: _DS.textSecondary, fontSize: 15),
                ),
              ],
            ),
          ),
          // Premium badge pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF7C6FF7), Color(0xFF4A44AA)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: _DS.violet.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 14),
                SizedBox(width: 5),
                Text('PRO', style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1,
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section label
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      color: _DS.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Benefits
// ─────────────────────────────────────────────────────────────────────────────

class _BenefitsSection extends StatelessWidget {
  static const _items = [
    (Icons.bolt_rounded, 'Высокая скорость', 'Без ограничений пропускной способности'),
    (Icons.shield_rounded, 'Шифрование', 'Военный уровень защиты трафика'),
    (Icons.devices_rounded, 'Мультиустройство', 'Подключайте несколько гаджетов'),
    (Icons.public_rounded, 'Без блокировок', 'Доступ к любым ресурсам'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Возможности'),
        const SizedBox(height: 10),
        _GlassCard(
          child: Column(
            children: List.generate(_items.length, (i) {
              final item = _items[i];
              return Column(
                children: [
                  if (i > 0) const Divider(color: _DS.border, height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: _DS.violet.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(item.$1, color: _DS.violet, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.$2, style: const TextStyle(
                                color: _DS.textPrimary, fontSize: 14, fontWeight: FontWeight.w600,
                              )),
                              const SizedBox(height: 2),
                              Text(item.$3, style: const TextStyle(
                                color: _DS.textSecondary, fontSize: 12,
                              )),
                            ],
                          ),
                        ),
                        const Icon(Icons.check_circle_rounded, color: _DS.emerald, size: 18),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Not logged in
// ─────────────────────────────────────────────────────────────────────────────

class _NotLoggedInCard extends StatelessWidget {
  final VoidCallback onLoginTap;
  const _NotLoggedInCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _DS.violet.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.lock_outline_rounded, color: _DS.violet, size: 30),
          ),
          const SizedBox(height: 16),
          const Text(
            'Войдите, чтобы\nувидеть тарифы',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700, height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          TelegramLoginButton(onTap: onLoginTap),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Balance card
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  final double balanceRub;
  final String currency;
  const _BalanceCard({required this.balanceRub, required this.currency});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _DS.emerald.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_balance_wallet_rounded, color: _DS.emerald, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Баланс счёта', style: TextStyle(color: _DS.textSecondary, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  '${balanceRub.toStringAsFixed(2)} $currency',
                  style: const TextStyle(
                    color: _DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _DS.emerald.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _DS.emerald.withValues(alpha: 0.25)),
            ),
            child: const Text(
              'Активен',
              style: TextStyle(color: _DS.emerald, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription builder
// ─────────────────────────────────────────────────────────────────────────────

class _SubscriptionBuilderCard extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final int? selectedTraffic;
  final int? selectedDevices;
  final ValueChanged<String> onPeriodSelected;
  final ValueChanged<int> onTrafficSelected;
  final ValueChanged<int> onDevicesSelected;

  const _SubscriptionBuilderCard({
    required this.options,
    required this.selectedPeriodId,
    required this.selectedTraffic,
    required this.selectedDevices,
    required this.onPeriodSelected,
    required this.onTrafficSelected,
    required this.onDevicesSelected,
  });

  @override
  Widget build(BuildContext context) {
    final selectedPeriod = options.periods.firstWhere(
          (p) => p.id == selectedPeriodId,
      orElse: () => options.periods.first,
    );
    final hasTraffic = selectedPeriod.traffic?.selectable == true &&
        (selectedPeriod.traffic?.options.isNotEmpty ?? false);
    final hasDevices =
        selectedPeriod.devices != null && selectedPeriod.devices!.options.length > 1;

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Duration
          _BuilderRow(
            icon: Icons.calendar_month_rounded,
            label: 'Срок подписки',
          ),
          const SizedBox(height: 10),
          _PeriodGrid(
            options: options,
            selectedPeriodId: selectedPeriodId,
            onSelected: onPeriodSelected,
          ),

          // Traffic
          if (hasTraffic) ...[
            const SizedBox(height: 20),
            const Divider(color: _DS.border, height: 1),
            const SizedBox(height: 20),
            _BuilderRow(icon: Icons.data_usage_rounded, label: 'Трафик'),
            const SizedBox(height: 10),
            _ChipRow<int>(
              options: selectedPeriod.traffic!.options.map((t) => _Chip<int>(
                value: t.value,
                label: t.value == 0 ? '∞' : '${t.value} ГБ',
              )).toList(),
              selected: selectedTraffic,
              onSelected: onTrafficSelected,
            ),
          ],

          // Devices
          if (hasDevices) ...[
            const SizedBox(height: 20),
            const Divider(color: _DS.border, height: 1),
            const SizedBox(height: 20),
            _BuilderRow(icon: Icons.devices_rounded, label: 'Устройства'),
            const SizedBox(height: 10),
            _ChipRow<int>(
              options: selectedPeriod.devices!.options
                  .map((d) => _Chip<int>(value: d, label: '$d'))
                  .toList(),
              selected: selectedDevices,
              onSelected: onDevicesSelected,
            ),
          ],
        ],
      ),
    );
  }
}

class _BuilderRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _BuilderRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 15, color: _DS.textSecondary),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(
        color: _DS.textSecondary, fontSize: 13, fontWeight: FontWeight.w500,
      )),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Period grid (plan cards)
// ─────────────────────────────────────────────────────────────────────────────

class _PeriodGrid extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final ValueChanged<String> onSelected;

  const _PeriodGrid({
    required this.options,
    required this.selectedPeriodId,
    required this.onSelected,
  });

  String? _bestValueId() {
    PeriodOption? best;
    for (final p in options.periods) {
      if (p.discountPercent > 0 && (best == null || p.discountPercent > best.discountPercent)) {
        best = p;
      }
    }
    return best?.id;
  }

  @override
  Widget build(BuildContext context) {
    final periods = options.periods;
    final bestId = _bestValueId();
    const minW = 80.0;
    final available = MediaQuery.of(context).size.width - 64;
    final cardW = periods.isEmpty
        ? minW
        : ((available - (periods.length - 1) * 8) / periods.length).clamp(minW, 160.0);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < periods.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              SizedBox(
                width: cardW,
                child: _PlanCard(
                  period: periods[i],
                  isSelected: periods[i].id == selectedPeriodId,
                  isBestValue: periods[i].id == bestId,
                  onTap: () => onSelected(periods[i].id),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final PeriodOption period;
  final bool isSelected;
  final bool isBestValue;
  final VoidCallback onTap;

  const _PlanCard({
    required this.period,
    required this.isSelected,
    required this.isBestValue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? _DS.violet.withValues(alpha: 0.15) : _DS.surface2,
          borderRadius: BorderRadius.circular(_DS.radiusSm),
          border: Border.all(
            color: isSelected ? _DS.violet : _DS.border,
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: _DS.violet.withValues(alpha: 0.3), blurRadius: 20, spreadRadius: -6)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Best badge placeholder
            if (isBestValue)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _DS.emerald.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _DS.emerald.withValues(alpha: 0.35)),
                ),
                child: const Text('Выгодно', style: TextStyle(
                  color: _DS.emerald, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.3,
                )),
              )
            else
              const SizedBox(height: 22),

            Text(
              period.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : _DS.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(period.basePriceKopeks / 100).toStringAsFixed(0)} ₽',
              style: TextStyle(
                color: isSelected ? _DS.violet : _DS.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (period.discountPercent > 0) ...[
              const SizedBox(height: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _DS.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '−${period.discountPercent}%',
                  style: const TextStyle(color: _DS.amber, fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic chip row
// ─────────────────────────────────────────────────────────────────────────────

class _Chip<T> {
  final T value;
  final String label;
  const _Chip({required this.value, required this.label});
}

class _ChipRow<T> extends StatelessWidget {
  final List<_Chip<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;

  const _ChipRow({required this.options, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSel = opt.value == selected;
        return GestureDetector(
          onTap: () => onSelected(opt.value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isSel ? _DS.violet.withValues(alpha: 0.18) : _DS.surface3,
              borderRadius: BorderRadius.circular(_DS.radiusXs),
              border: Border.all(
                color: isSel ? _DS.violet : _DS.border,
                width: isSel ? 1.5 : 1,
              ),
            ),
            child: Text(
              opt.label,
              style: TextStyle(
                color: isSel ? _DS.violet : _DS.textPrimary,
                fontSize: 14,
                fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Price preview
// ─────────────────────────────────────────────────────────────────────────────

class _PricePreviewCard extends StatelessWidget {
  final CalcResult? calc;
  final bool loading;
  final int balanceKopeks;

  const _PricePreviewCard({
    required this.calc,
    required this.loading,
    required this.balanceKopeks,
  });

  @override
  Widget build(BuildContext context) {
    final totalKopeks = calc?.totalKopeks ?? 0;
    final totalRub = calc?.totalRub ?? 0.0;
    final hasEnough = totalKopeks > 0 && balanceKopeks >= totalKopeks;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _DS.violet.withValues(alpha: 0.12),
            _DS.surface1,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(_DS.radius),
        border: Border.all(color: _DS.violet.withValues(alpha: 0.3)),
      ),
      child: loading
          ? const Center(child: SizedBox(
        height: 28, width: 28,
        child: CircularProgressIndicator(strokeWidth: 2, color: _DS.violet),
      ))
          : Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('К оплате', style: TextStyle(color: _DS.textSecondary, fontSize: 13)),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: Text(
                    '${totalRub.toStringAsFixed(2)} ₽',
                    key: ValueKey(totalKopeks),
                    style: const TextStyle(
                      color: _DS.textPrimary,
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (totalKopeks > 0)
            _StatusPill(
              label: hasEnough ? 'С баланса' : 'Онлайн-оплата',
              color: hasEnough ? _DS.emerald : _DS.amber,
              icon: hasEnough ? Icons.check_circle_outline : Icons.credit_card_rounded,
            ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _StatusPill({required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(
          color: color, fontSize: 12, fontWeight: FontWeight.w600,
        )),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Buy button
// ─────────────────────────────────────────────────────────────────────────────

class _BuyButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;
  final int? totalKopeks;
  final bool hasEnoughBalance;

  const _BuyButton({
    required this.loading,
    required this.onPressed,
    this.totalKopeks,
    this.hasEnoughBalance = true,
  });

  @override
  Widget build(BuildContext context) {
    final needsPayment = !hasEnoughBalance && (totalKopeks ?? 0) > 0;
    final color = needsPayment ? _DS.emerald : _DS.violet;
    final label = loading
        ? ''
        : needsPayment
        ? 'Оплатить ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : (totalKopeks != null && totalKopeks! > 0)
        ? 'Купить за ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : 'Оформить подписку';

    return Container(
      height: 58,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, Color.lerp(color, Colors.black, 0.2)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(_DS.radius),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onPressed,
          borderRadius: BorderRadius.circular(_DS.radius),
          child: Center(
            child: loading
                ? const SizedBox(
              height: 22, width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
                : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  needsPayment ? Icons.payment_rounded : Icons.lock_open_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2,
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Upgrade card (existing subscribers)
// ─────────────────────────────────────────────────────────────────────────────

class _UpgradeDiffCard extends StatefulWidget {
  final MeSubscription sub;
  final SubscriptionOptions options;
  final Future<void> Function(String, {int? trafficAdd, int? devicesAdd}) onUpgrade;
  final bool loading;

  const _UpgradeDiffCard({
    required this.sub,
    required this.options,
    required this.onUpgrade,
    required this.loading,
  });

  @override
  State<_UpgradeDiffCard> createState() => _UpgradeDiffCardState();
}

class _UpgradeDiffCardState extends State<_UpgradeDiffCard> {
  String? _selectedPeriodId;

  @override
  void initState() {
    super.initState();
    if (widget.options.periods.isNotEmpty) {
      _selectedPeriodId = widget.options.periods.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedPeriod = _selectedPeriodId != null
        ? widget.options.periods.firstWhere(
            (p) => p.id == _selectedPeriodId,
        orElse: () => widget.options.periods.first)
        : null;

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Current status strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _DS.emerald.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(_DS.radiusSm),
              border: Border.all(color: _DS.emerald.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_rounded, color: _DS.emerald, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Активна до ${widget.sub.formattedExpiry}',
                    style: const TextStyle(color: _DS.emerald, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const _BuilderRow(icon: Icons.add_circle_outline_rounded, label: 'Продлить на'),
          const SizedBox(height: 10),

          _ChipRow<String>(
            options: widget.options.periods
                .map((p) => _Chip<String>(value: p.id, label: p.label))
                .toList(),
            selected: _selectedPeriodId,
            onSelected: (id) => setState(() => _selectedPeriodId = id),
          ),
          const SizedBox(height: 20),
          const Divider(color: _DS.border, height: 1),
          const SizedBox(height: 20),

          // Diff summary
          _DiffItem(label: 'Трафик', value: widget.sub.trafficLimitGb == 0 ? '∞ ГБ' : '${widget.sub.trafficLimitGb} ГБ', changed: false),
          const SizedBox(height: 10),
          _DiffItem(label: 'Устройства', value: '${widget.sub.deviceLimit}', changed: false),
          const SizedBox(height: 10),
          _DiffItem(
            label: 'Срок',
            value: selectedPeriod != null ? '+ ${selectedPeriod.label}' : '—',
            changed: true,
          ),
          const SizedBox(height: 20),

          _BuyButton(
            loading: widget.loading,
            onPressed: _selectedPeriodId != null ? () => widget.onUpgrade(_selectedPeriodId!) : () {},
            totalKopeks: null,
            hasEnoughBalance: true,
          ),
        ],
      ),
    );
  }
}

class _DiffItem extends StatelessWidget {
  final String label;
  final String value;
  final bool changed;
  const _DiffItem({required this.label, required this.value, required this.changed});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(flex: 2, child: Text(label, style: const TextStyle(color: _DS.textSecondary, fontSize: 13))),
      Expanded(
        flex: 3,
        child: changed
            ? Row(children: [
          const Icon(Icons.arrow_forward_rounded, size: 13, color: _DS.textMuted),
          const SizedBox(width: 4),
          Text(value, style: const TextStyle(
            color: _DS.emerald, fontSize: 13, fontWeight: FontWeight.w600,
          )),
        ])
            : Text(value, style: const TextStyle(color: _DS.textPrimary, fontSize: 13, fontWeight: FontWeight.w500)),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Payment polling card
// ─────────────────────────────────────────────────────────────────────────────

class _PaymentPollingCard extends StatelessWidget {
  const _PaymentPollingCard();

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      accentColor: _DS.violet,
      child: Column(
        children: [
          const SizedBox(
            width: 52, height: 52,
            child: CircularProgressIndicator(strokeWidth: 3, color: _DS.violet),
          ),
          const SizedBox(height: 20),
          const Text('Обрабатываем платёж…', style: TextStyle(
            color: _DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700,
          ), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text(
            'Ожидаем подтверждение от платёжного сервиса.\nЭто может занять до 2 минут.',
            style: TextStyle(color: _DS.textSecondary, fontSize: 13, height: 1.6),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error card
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: _DS.rose.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi_off_rounded, color: _DS.rose, size: 28),
          ),
          const SizedBox(height: 16),
          const Text('Не удалось загрузить тарифы', style: TextStyle(
            color: _DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w600,
          ), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          TextButton(
            onPressed: onRetry,
            child: const Text('Повторить', style: TextStyle(color: _DS.violet, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Payment disclaimer
// ─────────────────────────────────────────────────────────────────────────────

class _PaymentDisclaimer extends StatelessWidget {
  const _PaymentDisclaimer();

  @override
  Widget build(BuildContext context) => const Text(
    'Оплата через YooKassa · Подписка активируется автоматически',
    textAlign: TextAlign.center,
    style: TextStyle(color: _DS.textMuted, fontSize: 11, height: 1.5),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared primitives
// ─────────────────────────────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  final Color? accentColor;

  const _GlassCard({required this.child, this.accentColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(_DS.radius),
        border: Border.all(
          color: accentColor != null
              ? accentColor!.withValues(alpha: 0.35)
              : _DS.border,
        ),
        boxShadow: accentColor != null
            ? [BoxShadow(
          color: accentColor!.withValues(alpha: 0.1),
          blurRadius: 24,
          spreadRadius: -4,
        )]
            : null,
      ),
      child: child,
    );
  }
}

class _LoadingIndicator extends StatelessWidget {
  const _LoadingIndicator();

  @override
  Widget build(BuildContext context) => const CircularProgressIndicator(
    color: _DS.violet, strokeWidth: 2.5,
  );
}