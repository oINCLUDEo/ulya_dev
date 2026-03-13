import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/me_response.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../theme/app_colors.dart';
import '../widgets/purple_header.dart';
import 'auth_bottom_sheet.dart';

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

  // Payment polling state
  Timer? _pollTimer;
  int _pollAttempt = 0;
  bool _pollingForPayment = false;
  bool _pendingPaymentPoll = false;
  static const int _maxPollAttempts = 30;
  static const Duration _pollInterval = Duration(seconds: 4);

  // Builder state
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
    // When the user returns from the payment browser, start polling.
    if (state == AppLifecycleState.resumed && _pendingPaymentPoll) {
      _pendingPaymentPoll = false;
      _startPaymentPolling();
    }
  }

  /// Starts polling the backend for payment confirmation.
  /// Polls every [_pollInterval] up to [_maxPollAttempts] times.
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

    if (!mounted) {
      timer.cancel();
      return;
    }

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
          _showSnackBar(
            'Платёж ещё не подтверждён. Проверьте статус позже.',
            isError: false,
          );
        }
      }
    }
  }

  void _onAuthChanged() {
    if (mounted) _loadOptions();
  }

  void _onMeChanged() {
    if (mounted) setState(() {});
  }

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
      final period = opts.periods.firstWhere(
            (p) => p.id == periodId,
        orElse: () => opts.periods.first,
      );
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
          _showSnackBar(
            'Страница оплаты открыта. После оплаты вернитесь в приложение.',
            isError: false,
          );
          // Polling starts when the user returns (lifecycle resumed).
          // We register a one-shot observer via a flag.
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
        content: Text(msg),
        backgroundColor: isError ? AppColors.danger : AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me = meNotifier.value;
    final sub = me?.subscription;
    final hasActivePaidSub = sub != null && sub.isActive && !sub.isTrial;
    final isNewUser = !auth.isLoggedIn || (sub == null && !hasActivePaidSub);

    return Scaffold(
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadOptions,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + 16,
                16,
                8,
              ),
              sliver: SliverToBoxAdapter(
                child: PurpleHeader(
                  title: 'Премиум',
                  subtitle: hasActivePaidSub
                      ? 'Управление подпиской'
                      : 'Настройте и купите подписку',
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 8),

                  if (!auth.isLoggedIn) ...[
                    // Show benefits to motivate login
                    const _BenefitsList(),
                    const SizedBox(height: 16),
                    _NotLoggedInCard(
                      onLoginTap: () => showAuthBottomSheet(context),
                    ),
                  ] else if (_pollingForPayment) ...[
                    // Payment processing overlay
                    const SizedBox(height: 24),
                    const _PaymentPollingCard(),
                  ] else if (_loadingOptions && _options == null) ...[
                    const SizedBox(height: 60),
                    const Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    ),
                  ] else if (_options != null) ...[
                    // Balance card
                    _BalanceCard(
                      balanceRub: _options!.balanceRub,
                      currency: _options!.currency,
                    ),
                    const SizedBox(height: 12),

                    if (hasActivePaidSub) ...[
                      // ── Upgrade section ─────────────────────────────────
                      _SectionTitle('Улучшить подписку'),
                      const SizedBox(height: 8),
                      _UpgradeDiffCard(
                        sub: sub,
                        options: _options!,
                        onUpgrade: _onUpgradePressed,
                        loading: _purchasing,
                      ),
                    ] else ...[
                      // ── Benefits for new / trial users ───────────────────
                      if (isNewUser) ...[
                        const _BenefitsList(),
                        const SizedBox(height: 16),
                      ],

                      // ── Unified subscription builder ─────────────────────
                      _SectionTitle(
                        sub?.isTrial == true
                            ? 'Перейти на платную подписку'
                            : 'Настройте подписку',
                      ),
                      const SizedBox(height: 10),
                      _SubscriptionBuilderCard(
                        options: _options!,
                        selectedPeriodId: _selectedPeriodId,
                        selectedTraffic: _selectedTraffic,
                        selectedDevices: _selectedDevices,
                        onPeriodSelected: _onPeriodSelected,
                        onTrafficSelected: _onTrafficSelected,
                        onDevicesSelected: _onDevicesSelected,
                        hidePeriodSelector: false,
                      ),
                      const SizedBox(height: 12),

                      // ── Price preview ───────────────────────────────────
                      _PricePreviewCard(
                        calc: _calc,
                        loading: _loadingCalc,
                        balanceKopeks: _options!.balanceKopeks,
                      ),
                      const SizedBox(height: 16),

                      // ── Buy button ──────────────────────────────────────
                      _BuyButton(
                        loading: _purchasing || _loadingCalc,
                        onPressed: _onBuyPressed,
                        totalKopeks: _calc?.totalKopeks,
                        hasEnoughBalance: _options!.balanceKopeks >=
                            (_calc?.totalKopeks ?? 0),
                      ),
                      const SizedBox(height: 8),
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

// ══════════════════════════════════════════════════════════════════════════════
// Shared components
// ══════════════════════════════════════════════════════════════════════════════

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textNeutralSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ── Benefits list ─────────────────────────────────────────────────────────────

class _BenefitsList extends StatelessWidget {
  const _BenefitsList();

  static const _benefits = [
    (Icons.speed_rounded, 'Высокая скорость соединения'),
    (Icons.lock_rounded, 'Надёжное шифрование трафика'),
    (Icons.devices_rounded, 'Поддержка нескольких устройств'),
    (Icons.public_rounded, 'Доступ к заблокированным сайтам'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Возможности Premium',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          ..._benefits.map(
                (b) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(b.$1, color: const Color(0xFF6C5CE7), size: 17),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    b.$2,
                    style: const TextStyle(
                      color: AppColors.textNeutralMain,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Apple-style plan selector grid ────────────────────────────────────────────

class _PlanSelectorGrid extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final ValueChanged<String> onPeriodSelected;

  const _PlanSelectorGrid({
    required this.options,
    required this.selectedPeriodId,
    required this.onPeriodSelected,
  });

  /// Determine which plan has the highest discount for "Best Value" badge.
  String? _bestValueId() {
    if (options.periods.isEmpty) return null;
    PeriodOption? best;
    for (final p in options.periods) {
      if (p.discountPercent > 0) {
        if (best == null || p.discountPercent > best.discountPercent) {
          best = p;
        }
      }
    }
    return best?.id;
  }

  @override
  Widget build(BuildContext context) {
    final periods = options.periods;
    final bestId = _bestValueId();

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < periods.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _PlanCard(
                period: periods[i],
                isSelected: periods[i].id == selectedPeriodId,
                isBestValue: periods[i].id == bestId,
                onTap: () => onPeriodSelected(periods[i].id),
              ),
            ),
          ],
        ],
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
    const purple = Color(0xFF6C5CE7);
    const green = Color(0xFF00B894);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? purple.withValues(alpha: 0.15)
              : AppColors.graphiteElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? purple : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
            BoxShadow(
              color: purple.withValues(alpha: 0.25),
              blurRadius: 16,
              spreadRadius: -4,
            ),
          ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Best-value badge
            if (isBestValue)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: green.withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Выгоднее',
                  style: TextStyle(
                    color: green,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              )
            else
              const SizedBox(height: 22), // keeps consistent height

            // Plan label
            Text(
              period.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : AppColors.textNeutralMain,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),

            // Price
            Text(
              '${(period.basePriceKopeks / 100).toStringAsFixed(0)} ₽',
              style: TextStyle(
                color: isSelected ? purple : AppColors.textNeutralSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),

            // Discount badge
            if (period.discountPercent > 0) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '−${period.discountPercent}%',
                  style: const TextStyle(
                    color: AppColors.warning,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Payment disclaimer ────────────────────────────────────────────────────────

class _PaymentDisclaimer extends StatelessWidget {
  const _PaymentDisclaimer();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Оплата через YooKassa. После оплаты подписка активируется автоматически.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: AppColors.textNeutralMuted,
        fontSize: 11,
        height: 1.5,
      ),
    );
  }
}

// ── Payment polling card ──────────────────────────────────────────────────────

class _PaymentPollingCard extends StatelessWidget {
  const _PaymentPollingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF6C5CE7).withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6C5CE7).withValues(alpha: 0.12),
            blurRadius: 24,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Обрабатываем платёж…',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Ожидаем подтверждение от платёжного сервиса.\nЭто может занять до 2 минут.',
            style: TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _NotLoggedInCard extends StatelessWidget {
  final VoidCallback onLoginTap;
  const _NotLoggedInCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        children: [
          const Icon(Icons.lock_outline, color: AppColors.textNeutralSecondary, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Войдите, чтобы увидеть тарифы',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: onLoginTap,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Войти через Telegram'),
          ),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final double balanceRub;
  final String currency;
  const _BalanceCard({required this.balanceRub, required this.currency});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.account_balance_wallet_outlined,
              color: AppColors.success,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Баланс',
                style: TextStyle(color: AppColors.textNeutralSecondary, fontSize: 12),
              ),
              Text(
                '${balanceRub.toStringAsFixed(2)} $currency',
                style: const TextStyle(
                  color: AppColors.textNeutralMain,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Subscription Builder ─────────────────────────────────────────────────────

class _SubscriptionBuilderCard extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final int? selectedTraffic;
  final int? selectedDevices;
  final ValueChanged<String> onPeriodSelected;
  final ValueChanged<int> onTrafficSelected;
  final ValueChanged<int> onDevicesSelected;
  final bool hidePeriodSelector;

  const _SubscriptionBuilderCard({
    required this.options,
    required this.selectedPeriodId,
    required this.selectedTraffic,
    required this.selectedDevices,
    required this.onPeriodSelected,
    required this.onTrafficSelected,
    required this.onDevicesSelected,
    this.hidePeriodSelector = false,
  });

  @override
  Widget build(BuildContext context) {
    final selectedPeriod = options.periods.firstWhere(
          (p) => p.id == selectedPeriodId,
      orElse: () => options.periods.first,
    );

    // If only period selector is available and it's hidden, skip the card.
    final hasTraffic = selectedPeriod.traffic?.selectable == true &&
        (selectedPeriod.traffic?.options.isNotEmpty ?? false);
    final hasDevices =
        selectedPeriod.devices != null && selectedPeriod.devices!.options.length > 1;

    if (hidePeriodSelector && !hasTraffic && !hasDevices) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Duration selector (hidden when separate plan grid is shown)
          if (!hidePeriodSelector) ...[
            _RowLabel(icon: Icons.calendar_today_outlined, label: 'Срок подписки'),
            const SizedBox(height: 10),
            _ChipSelector<String>(
              equalWidth: true,
              options: options.periods.map((p) {
                final priceStr = '${(p.basePriceKopeks / 100).toStringAsFixed(0)} ₽';
                String? badge;
                if (p.discountPercent > 0) badge = '−${p.discountPercent}%';
                return _ChipItem<String>(
                  value: p.id,
                  label: p.label,
                  subtitle: priceStr,
                  badge: badge,
                );
              }).toList(),
              selected: selectedPeriodId,
              onSelected: onPeriodSelected,
            ),
          ],

          // Traffic
          if (hasTraffic) ...[
            if (!hidePeriodSelector) const SizedBox(height: 18),
            _RowLabel(icon: Icons.data_usage_outlined, label: 'Трафик'),
            const SizedBox(height: 10),
            _ChipSelector<int>(
              options: selectedPeriod.traffic!.options.map((t) {
                final lbl = t.value == 0 ? '∞ Безлимит' : '${t.value} ГБ';
                return _ChipItem<int>(value: t.value, label: lbl);
              }).toList(),
              selected: selectedTraffic,
              onSelected: onTrafficSelected,
            ),
          ],

          // Devices
          if (hasDevices) ...[
            const SizedBox(height: 18),
            _RowLabel(icon: Icons.devices_outlined, label: 'Устройства'),
            const SizedBox(height: 10),
            _ChipSelector<int>(
              options: selectedPeriod.devices!.options
                  .map((d) => _ChipItem<int>(value: d, label: '$d'))
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

class _RowLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  const _RowLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.textNeutralSecondary, size: 15),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textNeutralSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _ChipItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final String? badge;
  const _ChipItem({required this.value, required this.label, this.subtitle, this.badge});
}

class _ChipSelector<T> extends StatelessWidget {
  final List<_ChipItem<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  // When true, all chips share equal width (Row + Expanded) and equal height
  // (CrossAxisAlignment.stretch). Badge placeholder is always reserved so
  // chips with and without badges align vertically.
  final bool equalWidth;

  const _ChipSelector({
    required this.options,
    required this.selected,
    required this.onSelected,
    this.equalWidth = false,
  });

  Widget _buildChip(BuildContext context, _ChipItem<T> opt) {
    final isSelected = opt.value == selected;
    const purple = Color(0xFF6C5CE7);
    const green = Color(0xFF00B894);

    // Whether any option in this selector has a badge – used to decide whether
    // to reserve space for the badge row so that chips are the same height.
    final anyHasBadge = options.any((o) => o.badge != null);

    return GestureDetector(
      onTap: () => onSelected(opt.value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? purple.withValues(alpha: 0.18)
              : AppColors.graphiteElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? purple
                : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: isSelected
              ? [
            BoxShadow(
              color: purple.withValues(alpha: 0.2),
              blurRadius: 12,
              spreadRadius: -2,
            ),
          ]
              : null,
        ),
        child: Column(
          mainAxisSize: equalWidth ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Badge row: always reserve height when any chip in the group has
            // a badge, so all chips are the same height.
            if (anyHasBadge) ...[
              opt.badge != null
                  ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: green.withValues(alpha: 0.4)),
                ),
                child: Text(
                  opt.badge!,
                  style: const TextStyle(
                    color: green,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              )
                  : const SizedBox(height: 17), // same height as badge container
              const SizedBox(height: 5),
            ],
            Text(
              opt.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? purple : AppColors.textNeutralMain,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (opt.subtitle != null) ...[
              const SizedBox(height: 3),
              Text(
                opt.subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isSelected
                      ? purple.withValues(alpha: 0.8)
                      : AppColors.textNeutralSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (equalWidth) {
      final chips = <Widget>[];
      for (var i = 0; i < options.length; i++) {
        if (i > 0) chips.add(const SizedBox(width: 8));
        chips.add(Expanded(child: _buildChip(context, options[i])));
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: chips,
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) => _buildChip(context, opt)).toList(),
    );
  }
}

// ── Price Preview ─────────────────────────────────────────────────────────────

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
    final hasEnoughBalance = totalKopeks > 0 && balanceKopeks >= totalKopeks;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF6C5CE7).withValues(alpha: 0.10),
            const Color(0xFF311459).withValues(alpha: 0.15),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF6C5CE7).withValues(alpha: 0.25),
        ),
      ),
      child: loading
          ? const Center(
        child: SizedBox(
          height: 24,
          width: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF6C5CE7),
          ),
        ),
      )
          : Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'К оплате',
                  style: TextStyle(
                    color: AppColors.textNeutralSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: Text(
                    '${totalRub.toStringAsFixed(2)} ₽',
                    key: ValueKey(totalKopeks),
                    style: const TextStyle(
                      color: AppColors.textNeutralMain,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (totalKopeks > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: hasEnoughBalance
                    ? AppColors.success.withValues(alpha: 0.15)
                    : AppColors.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                hasEnoughBalance ? 'С баланса' : 'Пополнить баланс',
                style: TextStyle(
                  color: hasEnoughBalance ? AppColors.success : AppColors.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Buy Button ───────────────────────────────────────────────────────────────

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
    final label = loading
        ? ''
        : needsPayment
        ? 'Оплатить ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : (totalKopeks != null && totalKopeks! > 0)
        ? 'Купить за ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : 'Купить подписку';

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: needsPayment
              ? const Color(0xFF00B894)
              : const Color(0xFF6C5CE7),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF6C5CE7).withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
        child: loading
            ? const SizedBox(
          height: 22,
          width: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        )
            : Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              needsPayment ? Icons.payment_rounded : Icons.lock_open_rounded,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Upgrade Diff UI ───────────────────────────────────────────────────────────

class _UpgradeDiffCard extends StatefulWidget {
  final MeSubscription sub;
  final SubscriptionOptions options;
  final Future<void> Function(String periodId, {int? trafficAdd, int? devicesAdd}) onUpgrade;
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
    final currentTraffic = widget.sub.trafficLimitGb;
    final currentDevices = widget.sub.deviceLimit;
    final currentExpiry = widget.sub.formattedExpiry;

    final selectedPeriod = _selectedPeriodId != null
        ? widget.options.periods.firstWhere(
          (p) => p.id == _selectedPeriodId,
      orElse: () => widget.options.periods.first,
    )
        : null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Продлить на',
            style: TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          _ChipSelector<String>(
            options: widget.options.periods
                .map((p) => _ChipItem<String>(value: p.id, label: p.label))
                .toList(),
            selected: _selectedPeriodId,
            onSelected: (id) => setState(() => _selectedPeriodId = id),
          ),
          const SizedBox(height: 20),
          const Text(
            'Изменения',
            style: TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          _DiffRow(
            label: 'Трафик',
            current: currentTraffic == 0 ? '∞ ГБ' : '$currentTraffic ГБ',
            upgraded: currentTraffic == 0 ? '∞ ГБ' : '$currentTraffic ГБ',
            changed: false,
          ),
          _DiffRow(
            label: 'Устройства',
            current: '$currentDevices',
            upgraded: '$currentDevices',
            changed: false,
          ),
          _DiffRow(
            label: 'Срок',
            current: currentExpiry,
            upgraded: selectedPeriod != null ? '+ ${selectedPeriod.label}' : '—',
            changed: true,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: (widget.loading || _selectedPeriodId == null)
                  ? null
                  : () => widget.onUpgrade(_selectedPeriodId!),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: widget.loading
                  ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
                  : const Text(
                'Продлить подписку',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  final String label;
  final String current;
  final String upgraded;
  final bool changed;

  const _DiffRow({
    required this.label,
    required this.current,
    required this.upgraded,
    required this.changed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textNeutralSecondary, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              current,
              style: const TextStyle(color: AppColors.textNeutralMain, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 4,
            child: changed
                ? Row(
              children: [
                const Icon(Icons.arrow_forward, size: 12, color: AppColors.textNeutralMuted),
                const SizedBox(width: 4),
                Text(
                  upgraded,
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
                : Text(
              upgraded,
              style: const TextStyle(color: AppColors.textNeutralMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        children: [
          const Icon(Icons.wifi_off_rounded, color: AppColors.textNeutralSecondary, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Не удалось загрузить тарифы',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onRetry,
            child: const Text(
              'Повторить',
              style: TextStyle(color: Color(0xFF6C5CE7)),
            ),
          ),
        ],
      ),
    );
  }
}
