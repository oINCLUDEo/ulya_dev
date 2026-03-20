import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/me_response.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/telegram_login_button.dart';
import 'auth_bottom_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────

class _DS {
  static const violet     = Color(0xFF7C6FF7);
  static const violetDim  = Color(0xFF4A44AA);
  static const emerald    = Color(0xFF34D399);
  static const amber      = Color(0xFFFBBF24);
  static const rose       = Color(0xFFF87171);
  static const sky        = Color(0xFF38BDF8);

  static const surface0 = Color(0xFF0F0F14);
  static const surface1 = Color(0xFF17171F);
  static const surface2 = Color(0xFF1E1E2A);
  static const surface3 = Color(0xFF26263A);

  static const textPrimary   = Color(0xFFEEEEF8);
  static const textSecondary = Color(0xFF8888AA);
  static const textMuted     = Color(0xFF55556A);

  static const border       = Color(0xFF2A2A3D);

  static const radius   = 20.0;
  static const radiusSm = 12.0;
  static const radiusXs = 8.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// PremiumPage
// ─────────────────────────────────────────────────────────────────────────────

class PremiumPage extends StatefulWidget {
  const PremiumPage({super.key});

  @override
  State<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends State<PremiumPage> with WidgetsBindingObserver {
  SubscriptionOptions? _options;
  CalcResult?          _calc;
  bool _loadingOptions = false;
  bool _loadingCalc    = false;
  bool _purchasing     = false;

  Timer? _pollTimer;
  int  _pollAttempt        = 0;
  bool _pollingForPayment  = false;
  bool _pendingPaymentPoll = false;
  static const int      _maxPollAttempts = 30;
  static const Duration _pollInterval    = Duration(seconds: 4);

  String? _selectedPeriodId;
  int?    _selectedTraffic;
  int?    _selectedDevices;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    globalRefreshNotifier.addListener(_onGlobalRefresh);
    _loadOptions();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    globalRefreshNotifier.removeListener(_onGlobalRefresh);
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
    setState(() { _pollingForPayment = true; _pollAttempt = 0; });
    _pollTimer = Timer.periodic(_pollInterval, _onPollTick);
  }

  Future<void> _onPollTick(Timer timer) async {
    _pollAttempt++;
    await MeService.refresh();
    if (!mounted) { timer.cancel(); return; }
    final sub       = meNotifier.value?.subscription;
    final confirmed = sub != null && sub.isActive && !sub.isTrial;
    if (confirmed || _pollAttempt >= _maxPollAttempts) {
      timer.cancel(); _pollTimer = null;
      if (!mounted) return;
      setState(() => _pollingForPayment = false);
      if (confirmed) {
        await _loadOptions();
        if (mounted) _snack('Подписка активирована!', error: false);
      } else {
        if (mounted) _snack('Платёж ещё не подтверждён. Проверьте статус позже.', error: false);
      }
    }
  }

  void _onAuthChanged() { if (mounted) _loadOptions(); }
  void _onMeChanged()   { if (mounted) setState(() {}); }
  void _onGlobalRefresh() { if (mounted) _loadOptions(); }

  Future<void> _loadOptions() async {
    if (!authStateNotifier.value.isLoggedIn) {
      if (mounted) setState(() => _options = null);
      return;
    }
    if (mounted) setState(() => _loadingOptions = true);
    try {
      final opts = await SubscriptionApiService.getOptions();
      if (mounted) {
        if (opts != null) {
          debugPrint('[OPTIONS] periods=${opts.periods.length}');
          debugPrint('[OPTIONS] trafficTopupEnabled=${opts.trafficTopupEnabled}');
          debugPrint('[OPTIONS] trafficTopupPackages=${opts.trafficTopupPackages.length}');
          debugPrint('[OPTIONS] availableTopupGb=${opts.availableTopupGb}');
          debugPrint('[OPTIONS] raw check: will show topup tab=${opts.trafficTopupPackages.isNotEmpty}');
        }
        setState(() {
          _options = opts;
          if (opts != null && opts.periods.isNotEmpty) {
            _selectedPeriodId ??= opts.periods.first.id;
            if (_selectedTraffic == null) {
              final t = opts.periods.first.traffic;
              if (t != null) {
                _selectedTraffic = t.defaultValue ?? t.currentValue ??
                    (t.options.isNotEmpty ? t.options.first.value : null);
              }
            }
            if (_selectedDevices == null) {
              final d = opts.periods.first.devices;
              _selectedDevices = d?.defaultValue ?? d?.currentValue ?? d?.minimum ?? 1;
            }
          }
        });
        await _recalcPrice();
      }
    } catch (e) { debugPrint('PremiumPage._loadOptions: $e'); }
    if (mounted) setState(() => _loadingOptions = false);
  }

  Future<void> _recalcPrice() async {
    final periodId = _selectedPeriodId;
    if (periodId == null) return;
    if (mounted) setState(() => _loadingCalc = true);
    try {
      final r = await SubscriptionApiService.calcPrice(
          periodId: periodId, trafficValue: _selectedTraffic, devices: _selectedDevices);
      if (mounted) setState(() => _calc = r);
    } catch (e) { debugPrint('PremiumPage._recalcPrice: $e'); }
    if (mounted) setState(() => _loadingCalc = false);
  }

  void _onPeriodSelected(String id) {
    if (_selectedPeriodId == id) return;
    final opts = _options; if (opts == null) return;
    setState(() {
      _selectedPeriodId = id;
      final period = opts.periods.firstWhere((p) => p.id == id, orElse: () => opts.periods.first);
      final t = period.traffic;
      if (t != null && t.options.isNotEmpty) {
        final def = t.options.where((o) => o.isDefault).firstOrNull ?? t.options.first;
        _selectedTraffic = def.value;
      }
      final d = period.devices;
      if (d != null) _selectedDevices = d.defaultValue ?? d.minimum;
    });
    _recalcPrice();
  }

  void _onTrafficSelected(int v) { if (_selectedTraffic == v) return; setState(() => _selectedTraffic = v); _recalcPrice(); }
  void _onDevicesSelected(int v) { if (_selectedDevices == v) return; setState(() => _selectedDevices = v); _recalcPrice(); }

  Future<void> _onBuyPressed() async {
    final periodId = _selectedPeriodId; if (periodId == null) return;
    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.buySubscription(
          periodId: periodId, trafficValue: _selectedTraffic, devices: _selectedDevices);
      if (!mounted) return;
      if (r == null)                          { _snack('Ошибка соединения с сервером', error: true); }
      else if (r.isSuccess)                   { _snack('Подписка активирована!', error: false); await MeService.refresh(); await _loadOptions(); }
      else if (r.requiresPayment && r.paymentUrl != null) { await _openPaymentUrl(r.paymentUrl!); }
      else                                    { _snack(r.message ?? 'Ошибка при покупке', error: true); }
    } catch (e) { if (mounted) _snack('Ошибка: $e', error: true); }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _onUpgradePressed(String? periodId, {int? trafficAdd, int? devicesAdd}) async {
    setState(() => _purchasing = true);
    try {
      final r = await SubscriptionApiService.upgradeSubscription(
          periodId: periodId, trafficAdd: trafficAdd, devicesAdd: devicesAdd);
      if (!mounted) return;
      if (r == null)                          { _snack('Ошибка соединения с сервером', error: true); }
      else if (r.isSuccess)                   { _snack('Подписка улучшена!', error: false); await MeService.refresh(); globalRefreshNotifier.notifyListeners(); await _loadOptions(); }
      else if (r.requiresPayment && r.paymentUrl != null) { await _openPaymentUrl(r.paymentUrl!); }
      else                                    { _snack(r.message ?? 'Ошибка при улучшении', error: true); }
    } catch (e) { if (mounted) _snack('Ошибка: $e', error: true); }
    if (mounted) setState(() => _purchasing = false);
  }

  Future<void> _openPaymentUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) { _snack('Страница оплаты открыта. После оплаты вернитесь в приложение.', error: false); _pendingPaymentPoll = true; }
      } else { if (mounted) _snack('Не удалось открыть страницу оплаты', error: true); }
    } catch (_) { if (mounted) _snack('Ошибка при открытии оплаты', error: true); }
  }

  void _snack(String msg, {required bool error}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
      backgroundColor: error ? _DS.rose : _DS.emerald,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_DS.radiusSm)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final auth             = authStateNotifier.value;
    final sub              = meNotifier.value?.subscription;
    final hasActivePaidSub = sub != null && sub.isActive && !sub.isTrial;

    return Scaffold(
      backgroundColor: _DS.surface0,
      body: RefreshIndicator(
        color: _DS.violet, backgroundColor: _DS.surface2,
        onRefresh: _loadOptions,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _Header(hasActiveSub: hasActivePaidSub)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
              sliver: SliverList(delegate: SliverChildListDelegate([

                if (!auth.isLoggedIn) ...[
                  _BenefitsGrid(),
                  const SizedBox(height: 16),
                  _NotLoggedInCard(onLoginTap: () => showAuthBottomSheet(context)),

                ] else if (_pollingForPayment) ...[
                  const SizedBox(height: 40),
                  const _PaymentPollingCard(),

                ] else if (_loadingOptions && _options == null) ...[
                  const SizedBox(height: 120),
                  const Center(child: CircularProgressIndicator(color: _DS.violet, strokeWidth: 2.5)),

                ] else if (_options != null) ...[
                  _BalanceCard(balanceRub: _options!.balanceRub, currency: _options!.currency),
                  const SizedBox(height: 20),

                  if (hasActivePaidSub) ...[
                    _UpgradeSection(
                      sub: sub,
                      options: _options!,
                      onUpgrade: _onUpgradePressed,
                      loading: _purchasing,
                    ),
                  ] else ...[
                    if (sub == null || sub.isTrial) ...[
                      _BenefitsGrid(),
                      const SizedBox(height: 20),
                    ],
                    _SectionLabel(sub?.isTrial == true ? 'Переход на платную подписку' : 'Настройте тариф'),
                    const SizedBox(height: 12),
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
                        calc: _calc, loading: _loadingCalc,
                        balanceKopeks: _options!.balanceKopeks),
                    const SizedBox(height: 14),
                    _BuyButton(
                        loading: _purchasing || _loadingCalc,
                        onPressed: _onBuyPressed,
                        totalKopeks: _calc?.totalKopeks,
                        hasEnoughBalance: _options!.balanceKopeks >= (_calc?.totalKopeks ?? 0)),
                    const SizedBox(height: 10),
                    const _PaymentDisclaimer(),
                  ],

                ] else ...[
                  const SizedBox(height: 60),
                  _ErrorCard(onRetry: _loadOptions),
                ],

              ])),
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

class _Header extends StatelessWidget {
  final bool hasActiveSub;
  const _Header({required this.hasActiveSub});

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top + 20, 20, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Премиум', style: TextStyle(
              color: _DS.textPrimary, fontSize: 32,
              fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1)),
          const SizedBox(height: 6),
          Text(hasActiveSub ? 'Управление подпиской' : 'Выберите тариф',
              style: const TextStyle(color: _DS.textSecondary, fontSize: 15)),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [_DS.violet, _DS.violetDim],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(
                  color: _DS.violet.withValues(alpha: 0.3),
                  blurRadius: 12, offset: const Offset(0, 4))]),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 14),
            SizedBox(width: 5),
            Text('PRO', style: TextStyle(color: Colors.white, fontSize: 12,
                fontWeight: FontWeight.w800, letterSpacing: 1)),
          ]),
        ),
      ]),
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
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: const TextStyle(color: _DS.textMuted, fontSize: 11,
          fontWeight: FontWeight.w700, letterSpacing: 1.2));
}

// ─────────────────────────────────────────────────────────────────────────────
// Benefits 2x2 grid
// ─────────────────────────────────────────────────────────────────────────────

class _BenefitsGrid extends StatelessWidget {
  static const _items = [
    (_DS.violet,  Icons.bolt_rounded,    'Высокая скорость',    'Без ограничений пропускной способности'),
    (_DS.emerald, Icons.shield_rounded,  'Шифрование',          'Военный уровень защиты трафика'),
    (_DS.sky,     Icons.devices_rounded, 'Мультиустройство',    'Несколько гаджетов одновременно'),
    (_DS.amber,   Icons.public_rounded,  'Без блокировок',      'Полный доступ к любым ресурсам'),
  ];

  @override
  Widget build(BuildContext context) => Column(children: [
    IntrinsicHeight( // ← Заставляет все дочерние элементы в Row быть одинаковой высоты
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch, // ← Растягиваем по высоте
        children: [
          Expanded(child: _FeatureCard(
            color: _items[0].$1,
            icon: _items[0].$2,
            title: _items[0].$3,
            subtitle: _items[0].$4,
          )),
          const SizedBox(width: 10),
          Expanded(child: _FeatureCard(
            color: _items[1].$1,
            icon: _items[1].$2,
            title: _items[1].$3,
            subtitle: _items[1].$4,
          )),
        ],
      ),
    ),
    const SizedBox(height: 10),
    IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _FeatureCard(
            color: _items[2].$1,
            icon: _items[2].$2,
            title: _items[2].$3,
            subtitle: _items[2].$4,
          )),
          const SizedBox(width: 10),
          Expanded(child: _FeatureCard(
            color: _items[3].$1,
            icon: _items[3].$2,
            title: _items[3].$3,
            subtitle: _items[3].$4,
          )),
        ],
      ),
    ),
  ]);
}

class _FeatureCard extends StatelessWidget {
  final Color color; final IconData icon;
  final String title; final String subtitle;
  const _FeatureCard({required this.color, required this.icon,
    required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(_DS.radiusSm),
        border: Border.all(color: _DS.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 36, height: 36,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, color: color, size: 18)),
      const SizedBox(height: 10),
      Text(title, style: const TextStyle(
          color: _DS.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 3),
      Text(subtitle, style: const TextStyle(
          color: _DS.textSecondary, fontSize: 11, height: 1.4)),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Not logged in
// ─────────────────────────────────────────────────────────────────────────────

class _NotLoggedInCard extends StatelessWidget {
  final VoidCallback onLoginTap;
  const _NotLoggedInCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) => _Card(child: Column(children: [
    Container(width: 64, height: 64,
        decoration: BoxDecoration(
            color: _DS.violet.withValues(alpha: 0.12), shape: BoxShape.circle),
        child: const Icon(Icons.lock_outline_rounded, color: _DS.violet, size: 30)),
    const SizedBox(height: 16),
    const Text('Войдите, чтобы увидеть тарифы', textAlign: TextAlign.center,
        style: TextStyle(color: _DS.textPrimary, fontSize: 18,
            fontWeight: FontWeight.w700, height: 1.3)),
    const SizedBox(height: 6),
    const Text('Тарифы и цены доступны после авторизации', textAlign: TextAlign.center,
        style: TextStyle(color: _DS.textSecondary, fontSize: 13)),
    const SizedBox(height: 20),
    TelegramLoginButton(onTap: onLoginTap),
  ]));
}

// ─────────────────────────────────────────────────────────────────────────────
// Balance card
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  final double balanceRub; final String currency;
  const _BalanceCard({required this.balanceRub, required this.currency});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(_DS.radiusSm),
        border: Border.all(color: _DS.border)),
    child: Row(children: [
      Container(width: 42, height: 42,
          decoration: BoxDecoration(
              color: _DS.emerald.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11)),
          child: const Icon(Icons.account_balance_wallet_rounded, color: _DS.emerald, size: 20)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('БАЛАНС СЧЁТА', style: TextStyle(color: _DS.textMuted, fontSize: 10,
            letterSpacing: 0.8, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('${balanceRub.toStringAsFixed(2)} $currency',
            style: const TextStyle(color: _DS.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
      ])),
      Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
              color: _DS.emerald.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _DS.emerald.withValues(alpha: 0.3))),
          child: const Text('Активен', style: TextStyle(
              color: _DS.emerald, fontSize: 11, fontWeight: FontWeight.w600))),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Subscription builder
// ─────────────────────────────────────────────────────────────────────────────

class _SubscriptionBuilderCard extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final int?    selectedTraffic;
  final int?    selectedDevices;
  final ValueChanged<String> onPeriodSelected;
  final ValueChanged<int>    onTrafficSelected;
  final ValueChanged<int>    onDevicesSelected;

  const _SubscriptionBuilderCard({
    required this.options, required this.selectedPeriodId,
    required this.selectedTraffic, required this.selectedDevices,
    required this.onPeriodSelected, required this.onTrafficSelected,
    required this.onDevicesSelected,
  });

  @override
  Widget build(BuildContext context) {
    final period     = options.periods.firstWhere(
            (p) => p.id == selectedPeriodId, orElse: () => options.periods.first);
    final hasTraffic = period.traffic?.selectable == true &&
        (period.traffic?.options.isNotEmpty ?? false);
    final hasDevices = period.devices != null &&
        (period.devices!.options.length > 1);

    return _Card(padding: EdgeInsets.zero, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [

      // Period
      Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 16), child:
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _RowLabel(icon: Icons.calendar_month_rounded, label: 'Срок подписки'),
        const SizedBox(height: 12),
        _PeriodList(
            options: options, selectedPeriodId: selectedPeriodId,
            onSelected: onPeriodSelected),
      ])),

      // Traffic
      if (hasTraffic) ...[
        const Divider(height: 1, color: _DS.border),
        Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 16), child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _RowLabel(icon: Icons.data_usage_rounded, label: 'Трафик'),
          const SizedBox(height: 4),
          const Text('Объём данных в месяц',
              style: TextStyle(color: _DS.textMuted, fontSize: 11)),
          const SizedBox(height: 12),
          _OptionChips<int>(
              options: period.traffic!.options.map((t) => _OItem<int>(
                value: t.value,
                label: t.value == 0 ? '∞ ГБ' : '${t.value} ГБ',
                hot: t.isDefault,
              )).toList(),
              selected: selectedTraffic,
              onSelected: onTrafficSelected,
              accent: _DS.sky),
        ])),
      ],

      // Devices
      if (hasDevices) ...[
        const Divider(height: 1, color: _DS.border),
        Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 16), child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _RowLabel(icon: Icons.devices_rounded, label: 'Количество устройств'),
          const SizedBox(height: 4),
          const Text('Одновременных подключений',
              style: TextStyle(color: _DS.textMuted, fontSize: 11)),
          const SizedBox(height: 12),
          _OptionChips<int>(
              options: period.devices!.options.map((d) => _OItem<int>(
                value: d, label: '$d устр.',
                hot: d == (period.devices!.defaultValue ?? period.devices!.minimum),
              )).toList(),
              selected: selectedDevices,
              onSelected: onDevicesSelected,
              accent: _DS.violet),
        ])),
      ],
    ]));
  }
}

class _RowLabel extends StatelessWidget {
  final IconData icon; final String label;
  const _RowLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 14, color: _DS.textSecondary),
    const SizedBox(width: 6),
    Text(label, style: const TextStyle(
        color: _DS.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Period list (radio rows)
// ─────────────────────────────────────────────────────────────────────────────

class _PeriodList extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final ValueChanged<String> onSelected;
  const _PeriodList({required this.options, required this.selectedPeriodId, required this.onSelected});

  String? _bestId() {
    PeriodOption? best;
    for (final p in options.periods) {
      if (p.discountPercent > 0 &&
          (best == null || p.discountPercent > best.discountPercent)) best = p;
    }
    return best?.id;
  }

  @override
  Widget build(BuildContext context) {
    final bestId = _bestId();
    return Column(children: [
      for (int i = 0; i < options.periods.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        _PeriodRow(
            period: options.periods[i],
            isSelected: options.periods[i].id == selectedPeriodId,
            isBest: options.periods[i].id == bestId,
            onTap: () => onSelected(options.periods[i].id)),
      ],
    ]);
  }
}

class _PeriodRow extends StatelessWidget {
  final PeriodOption period;
  final bool isSelected; final bool isBest;
  final VoidCallback onTap;
  const _PeriodRow({required this.period, required this.isSelected,
    required this.isBest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final priceRub = period.basePriceKopeks / 100;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: isSelected ? _DS.violet.withValues(alpha: 0.12) : _DS.surface2,
            borderRadius: BorderRadius.circular(_DS.radiusSm),
            border: Border.all(
                color: isSelected ? _DS.violet : _DS.border,
                width: isSelected ? 1.5 : 1),
            boxShadow: isSelected
                ? [BoxShadow(color: _DS.violet.withValues(alpha: 0.18),
                blurRadius: 16, spreadRadius: -4)]
                : null),
        child: Row(children: [
          // Radio dot
          AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 20, height: 20,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: isSelected ? _DS.violet : _DS.border,
                      width: isSelected ? 5.5 : 2),
                  color: isSelected ? _DS.surface0 : Colors.transparent)),
          const SizedBox(width: 14),
          // Label + discount
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(period.label, style: TextStyle(
                  color: isSelected ? _DS.textPrimary : _DS.textSecondary,
                  fontSize: 15, fontWeight: FontWeight.w600)),
              if (isBest) ...[
                const SizedBox(width: 8),
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: _DS.emerald.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _DS.emerald.withValues(alpha: 0.35))),
                    child: const Text('Выгодно', style: TextStyle(
                        color: _DS.emerald, fontSize: 9,
                        fontWeight: FontWeight.w700, letterSpacing: 0.3))),
              ],
            ]),
            if (period.discountPercent > 0) ...[
              const SizedBox(height: 2),
              Text('Скидка ${period.discountPercent}%',
                  style: const TextStyle(color: _DS.amber, fontSize: 11, fontWeight: FontWeight.w500)),
            ],
          ])),
          // Price
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${priceRub.toStringAsFixed(0)} ₽', style: TextStyle(
                color: isSelected ? _DS.violet : _DS.textPrimary,
                fontSize: 17, fontWeight: FontWeight.w800)),
            if (period.discountPercent > 0) ...[
              const SizedBox(height: 1),
              Text(
                  '${(priceRub / (1 - period.discountPercent / 100)).toStringAsFixed(0)} ₽',
                  style: const TextStyle(color: _DS.textMuted, fontSize: 11,
                      decoration: TextDecoration.lineThrough)),
            ],
          ]),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Option chips (traffic / devices)
// ─────────────────────────────────────────────────────────────────────────────

class _OItem<T> {
  final T value; final String label; final String? sub; final bool hot;
  const _OItem({required this.value, required this.label, this.sub, this.hot = false});
}

class _OptionChips<T> extends StatelessWidget {
  final List<_OItem<T>> options;
  final T?    selected;
  final ValueChanged<T> onSelected;
  final Color accent;
  const _OptionChips({required this.options, required this.selected,
    required this.onSelected, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 12,
      children: options.map((opt) {
        final isSel = opt.value == selected;
        return GestureDetector(
          onTap: () => onSelected(opt.value),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: isSel ? accent.withValues(alpha: 0.15) : _DS.surface2,
                  borderRadius: BorderRadius.circular(_DS.radiusXs),
                  border: Border.all(
                    color: isSel ? accent : _DS.border,
                    width: isSel ? 1.5 : 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    opt.label,
                    style: TextStyle(
                      color: isSel ? accent : _DS.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (opt.hot)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 5, height: 5,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                ),
            ],
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
  final CalcResult? calc; final bool loading; final int balanceKopeks;
  const _PricePreviewCard({required this.calc, required this.loading, required this.balanceKopeks});

  @override
  Widget build(BuildContext context) {
    final total      = calc?.totalKopeks ?? 0;
    final totalRub   = calc?.totalRub    ?? 0.0;
    final fromBal    = total > 0 && balanceKopeks >= total;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [_DS.violet.withValues(alpha: 0.1), _DS.surface1],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(_DS.radius),
          border: Border.all(color: _DS.violet.withValues(alpha: 0.28))),
      child: loading
          ? const Center(child: SizedBox(height: 32, width: 32,
          child: CircularProgressIndicator(strokeWidth: 2, color: _DS.violet)))
          : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('К ОПЛАТЕ', style: TextStyle(color: _DS.textMuted, fontSize: 10,
              fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
              child: Text(key: ValueKey(total),
                  '${totalRub.toStringAsFixed(2)} ₽',
                  style: const TextStyle(color: _DS.textPrimary, fontSize: 38,
                      fontWeight: FontWeight.w800, letterSpacing: -1.5, height: 1))),
        ])),
        if (total > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _PayPill(
                label: fromBal ? 'С баланса' : 'Онлайн-оплата',
                color: fromBal ? _DS.emerald : _DS.amber,
                icon: fromBal ? Icons.check_circle_outline : Icons.credit_card_rounded),
            if (fromBal) ...[
              const SizedBox(height: 5),
              Text('Баланс: ${(balanceKopeks / 100).toStringAsFixed(2)} ₽',
                  style: const TextStyle(color: _DS.textMuted, fontSize: 10)),
            ],
          ]),
      ]),
    );
  }
}

class _PayPill extends StatelessWidget {
  final String label; final Color color; final IconData icon;
  const _PayPill({required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.3))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 13),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Buy button
// ─────────────────────────────────────────────────────────────────────────────

class _BuyButton extends StatelessWidget {
  final bool loading; final VoidCallback? onPressed;
  final int? totalKopeks; final bool hasEnoughBalance;
  const _BuyButton({required this.loading, this.onPressed,
    this.totalKopeks, this.hasEnoughBalance = true});

  @override
  Widget build(BuildContext context) {
    final needsPayment = !hasEnoughBalance && (totalKopeks ?? 0) > 0;
    final color = needsPayment ? _DS.emerald : _DS.violet;
    final label = loading ? ''
        : needsPayment
        ? 'Оплатить ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : (totalKopeks != null && totalKopeks! > 0)
        ? 'Оформить за ${(totalKopeks! / 100).toStringAsFixed(2)} ₽'
        : 'Оформить подписку';

    return Container(
      height: 58, width: double.infinity,
      decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [color, Color.lerp(color, Colors.black, 0.22)!],
              begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(_DS.radius),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35),
              blurRadius: 20, offset: const Offset(0, 6))]),
      child: Material(color: Colors.transparent, child: InkWell(
        onTap: (loading || onPressed == null) ? null : onPressed,
        borderRadius: BorderRadius.circular(_DS.radius),
        child: Center(child: loading
            ? const SizedBox(height: 22, width: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(needsPayment ? Icons.payment_rounded : Icons.lock_open_rounded,
              color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 16,
              fontWeight: FontWeight.w700, letterSpacing: 0.2)),
        ])),
      )),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Upgrade section (existing paid subscribers)
// ─────────────────────────────────────────────────────────────────────────────

class _UpgradeSection extends StatefulWidget {
  final MeSubscription sub;
  final SubscriptionOptions options;
  final Future<void> Function(String?, {int? trafficAdd, int? devicesAdd}) onUpgrade;
  final bool loading;
  const _UpgradeSection({required this.sub, required this.options,
    required this.onUpgrade, required this.loading});

  @override
  State<_UpgradeSection> createState() => _UpgradeSectionState();
}

class _UpgradeSectionState extends State<_UpgradeSection>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  int _tab = 0;

  String? _renewPeriodId;
  int?    _selectedTrafficValue; // selected topup package gb (= traffic_add increment)
  int?    _addDevices;

  // Цены для каждого варианта: ключ=инкремент, значение=kopeks
  Map<int, int?> _devicesPrices = {}; // null = загружается, int = загружено

  /// Traffic top-up packages from backend (traffic_topup_packages).
  /// gb = increment to send as traffic_add, priceKopeks = fixed price.
  List<TrafficTopupPackage> get _topupPackages {
    final pkgs = widget.options.trafficTopupPackages;
    debugPrint('[TOPUP] trafficTopupEnabled=${widget.options.trafficTopupEnabled}');
    debugPrint('[TOPUP] trafficTopupPackages count=${pkgs.length}');
    for (final p in pkgs) {
      debugPrint('[TOPUP]   package: gb=${p.gb} price=${p.priceKopeks}');
    }
    debugPrint('[TOPUP] availableTopupGb=${widget.options.availableTopupGb}');
    return pkgs;
  }

  /// Price for the currently selected topup package.
  int? get _trafficPriceKopeks {
    if (_selectedTrafficValue == null) return null;
    try {
      return _topupPackages
          .firstWhere((p) => p.gb == _selectedTrafficValue)
          .priceKopeks;
    } catch (_) {
      return null;
    }
  }

  /// Device add options: convert absolute backend values to increments.
  List<int> get _devicesOpts {
    final current = widget.sub.deviceLimit;
    final first = widget.options.periods.firstOrNull;
    final cfg = first?.devices;
    if (cfg == null) return const [];

    final maxCfg = cfg.maximum ??
        (cfg.options.isNotEmpty ? cfg.options.reduce((a, b) => a > b ? a : b) : null);
    if (maxCfg != null && current >= maxCfg) return const [];

    final targetOptions = cfg.options
        .where((v) => v > current && (maxCfg == null || v <= maxCfg))
        .toList();
    final additions = targetOptions
        .map((v) => v - current)
        .where((v) => v > 0)
        .toSet()
        .toList()
      ..sort();

    if (additions.isNotEmpty) return additions;
    if (maxCfg == null || current < maxCfg) return [1];
    return const [];
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this)
      ..addListener(() { if (mounted) setState(() => _tab = _tabCtrl.index); });
    if (widget.options.periods.isNotEmpty) _renewPeriodId = widget.options.periods.first.id;
    // Default: first available topup package
    _selectedTrafficValue = _topupPackages.firstOrNull?.gb;
    _addDevices = _devicesOpts.firstOrNull;
    // Pre-mark all options as loading, then fetch prices
    _devicesPrices = { for (final d in _devicesOpts) d: null };
    for (final d in _devicesOpts) {
      _calcDevicesPrice(d);
    }
  }

  Future<void> _calcDevicesPrice(int? devicesAdd) async {
    if (devicesAdd == null) return;
    // Mark as loading
    if (mounted) setState(() {
      _devicesPrices = Map.from(_devicesPrices)..[devicesAdd] = null;
    });
    final result = await SubscriptionApiService.calcUpgradePrice(devicesAdd: devicesAdd);
    if (!mounted) return;
    // Store result — copy map to force Flutter to detect the change
    setState(() {
      _devicesPrices = Map.from(_devicesPrices)
        ..[devicesAdd] = result?.amountKopeks ?? 0;
    });
  }

  @override
  void dispose() { _tabCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Status strip
      _StatusStrip(sub: widget.sub),
      const SizedBox(height: 20),

      _SectionLabel('Улучшить подписку'),
      const SizedBox(height: 12),

      // Tab bar
      _UpgradeTabBar(controller: _tabCtrl),
      const SizedBox(height: 14),

      // Tab content
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
        child: KeyedSubtree(
          key: ValueKey(_tab),
          child: [
            _RenewTab(
                options: widget.options, selectedPeriodId: _renewPeriodId,
                onPeriodSelected: (id) => setState(() => _renewPeriodId = id),
                loading: widget.loading,
                onConfirm: () => widget.onUpgrade(_renewPeriodId!)),
            _AddTrafficTab(
                packages: _topupPackages,
                selectedGb: _selectedTrafficValue,
                onSelected: (gb) => setState(() => _selectedTrafficValue = gb),
                loading: widget.loading,
                amountKopeks: _trafficPriceKopeks,
                onConfirm: _selectedTrafficValue == null
                    ? null
                // gb IS the increment — send directly as traffic_add
                    : () => widget.onUpgrade(null,
                    trafficAdd: _selectedTrafficValue)),
            _AddDevicesTab(
                currentDevices: widget.sub.deviceLimit,
                selectedAdd: _addDevices,
                options: _devicesOpts,
                allPrices: _devicesPrices,
                onSelected: (v) => setState(() => _addDevices = v),
                loading: widget.loading,
                onConfirm: (_addDevices == null ||
                    _devicesPrices[_addDevices] == null)
                    ? null
                    : () => widget.onUpgrade(null, devicesAdd: _addDevices)),
          ][_tab],
        ),
      ),
    ]);
  }
}

// ── Status strip ─────────────────────────────────────────────────────────────

class _StatusStrip extends StatelessWidget {
  final MeSubscription sub;
  const _StatusStrip({required this.sub});

  @override
  Widget build(BuildContext context) {
    final remnaInfo = RemnawaveService.lastSubscriptionInfo;
    final traffic = (remnaInfo != null && remnaInfo.totalBytes > 0)
        ? remnaInfo.formattedTotal
        : (sub.trafficLimitGb == 0 ? '∞ ГБ' : '${sub.trafficLimitGb} ГБ');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: _DS.surface1,
          borderRadius: BorderRadius.circular(_DS.radiusSm),
          border: Border.all(color: _DS.emerald.withValues(alpha: 0.25))),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.verified_rounded, color: _DS.emerald, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text('Активна до ${sub.formattedExpiry}',
              style: const TextStyle(color: _DS.emerald, fontSize: 14, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _StatChip(icon: Icons.data_usage_rounded,
              label: 'Трафик', value: traffic, color: _DS.sky)),
          const SizedBox(width: 8),
          Expanded(child: _StatChip(icon: Icons.devices_rounded,
              label: 'Устройства', value: '${sub.deviceLimit} устр.', color: _DS.violet)),
        ]),
      ]),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon; final String label; final String value; final Color color;
  const _StatChip({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2))),
    child: Row(children: [
      Icon(icon, color: color, size: 15),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: _DS.textMuted, fontSize: 10,
            fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        Text(value, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
      ])),
    ]),
  );
}

// ── Tab bar ───────────────────────────────────────────────────────────────────

class _UpgradeTabBar extends StatelessWidget {
  final TabController controller;
  const _UpgradeTabBar({required this.controller});

  @override
  Widget build(BuildContext context) => Container(
    height: 46,
    decoration: BoxDecoration(
        color: _DS.surface2, borderRadius: BorderRadius.circular(_DS.radiusSm),
        border: Border.all(color: _DS.border)),
    child: TabBar(
      controller: controller,
      indicator: BoxDecoration(
          color: _DS.violet.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: _DS.violet.withValues(alpha: 0.4))),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      labelPadding: EdgeInsets.zero,
      labelColor: _DS.violet,
      unselectedLabelColor: _DS.textSecondary,
      tabs: const [
        Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.refresh_rounded, size: 14), SizedBox(width: 5),
          Text('Продлить', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))])),
        Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.data_usage_rounded, size: 14), SizedBox(width: 5),
          Text('Трафик', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))])),
        Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.devices_rounded, size: 14), SizedBox(width: 5),
          Text('Устройства', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))])),
      ],
    ),
  );
}

// ── Renew tab ─────────────────────────────────────────────────────────────────

class _RenewTab extends StatelessWidget {
  final SubscriptionOptions options;
  final String? selectedPeriodId;
  final ValueChanged<String> onPeriodSelected;
  final bool loading;
  final VoidCallback onConfirm;
  const _RenewTab({required this.options, required this.selectedPeriodId,
    required this.onPeriodSelected, required this.loading, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final sel = selectedPeriodId != null
        ? options.periods.firstWhere((p) => p.id == selectedPeriodId,
        orElse: () => options.periods.first)
        : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // ── Single card: header + period rows + button ───────────────────
      _Card(padding: EdgeInsets.zero, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // Header with selected price
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(children: [
              Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [_DS.violet, _DS.violetDim],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [BoxShadow(
                          color: _DS.violet.withValues(alpha: 0.30),
                          blurRadius: 8, offset: const Offset(0, 3))]),
                  child: const Icon(Icons.refresh_rounded,
                      color: Colors.white, size: 18)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Продление подписки',
                  style: TextStyle(color: _DS.textPrimary, fontSize: 15,
                      fontWeight: FontWeight.w700))),
              // Live price pill — updates as user picks period
              if (sel != null)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    key: ValueKey(sel.id),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: _DS.violet.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: _DS.violet.withValues(alpha: 0.35))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                            '${(sel.basePriceKopeks / 100).toStringAsFixed(0)} ₽',
                            style: const TextStyle(
                                color: _DS.violet, fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        if (sel.discountPercent > 0)
                          Text(
                              '${((sel.basePriceKopeks / 100) / (1 - sel.discountPercent / 100)).toStringAsFixed(0)} ₽',
                              style: const TextStyle(
                                  color: _DS.textMuted, fontSize: 10,
                                  decoration: TextDecoration.lineThrough)),
                      ],
                    ),
                  ),
                ),
            ]),
          ),

          const Divider(height: 1, color: _DS.border),

          // Period rows — inline, no wrapping card
          ...options.periods.asMap().entries.map((e) {
            final i      = e.key;
            final period = e.value;
            final isSelected = period.id == selectedPeriodId;
            final isBest = options.periods
                .where((p) => p.discountPercent > 0)
                .fold<PeriodOption?>(null, (best, p) =>
            best == null || p.discountPercent > best.discountPercent
                ? p : best)
                ?.id == period.id;
            final priceRub = period.basePriceKopeks / 100;
            final isLast = i == options.periods.length - 1;

            return Column(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: () => onPeriodSelected(period.id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 13),
                  decoration: BoxDecoration(
                      color: isSelected
                          ? _DS.violet.withValues(alpha: 0.08)
                          : Colors.transparent),
                  child: Row(children: [
                    // Radio
                    AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 20, height: 20,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: isSelected ? _DS.violet : _DS.border,
                                width: isSelected ? 5.5 : 2),
                            color: isSelected
                                ? _DS.surface0 : Colors.transparent)),
                    const SizedBox(width: 12),
                    // Label
                    Expanded(child: Row(children: [
                      Text(period.label, style: TextStyle(
                          color: isSelected
                              ? _DS.textPrimary : _DS.textSecondary,
                          fontSize: 14, fontWeight: FontWeight.w600)),
                      if (isBest) ...[
                        const SizedBox(width: 8),
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: _DS.emerald.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: _DS.emerald.withValues(alpha: 0.3))),
                            child: const Text('Выгодно', style: TextStyle(
                                color: _DS.emerald, fontSize: 9,
                                fontWeight: FontWeight.w700))),
                      ],
                    ])),
                    // Price
                    Column(crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${priceRub.toStringAsFixed(0)} ₽',
                              style: TextStyle(
                                  color: isSelected
                                      ? _DS.violet : _DS.textPrimary,
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          if (period.discountPercent > 0)
                            Text(
                                '${(priceRub / (1 - period.discountPercent / 100)).toStringAsFixed(0)} ₽',
                                style: const TextStyle(
                                    color: _DS.textMuted, fontSize: 10,
                                    decoration: TextDecoration.lineThrough)),
                        ]),
                  ]),
                ),
              ),
              if (!isLast) const Divider(height: 1, color: _DS.border),
            ]);
          }),

          const Divider(height: 1, color: _DS.border),

          Padding(
            padding: const EdgeInsets.all(14),
            child: _BuyButton(
                loading: loading,
                onPressed: selectedPeriodId != null ? onConfirm : null,
                totalKopeks: sel?.basePriceKopeks,
                hasEnoughBalance: true),
          ),
        ],
      )),
    ]);
  }
}


// ── Add traffic tab ───────────────────────────────────────────────────────────

// ── Traffic plan switcher ─────────────────────────────────────────────────────
// Shows all traffic options as radio-row cards with the price for each.
// The current plan is highlighted but not selectable (already active).
// Price comes directly from TrafficOption.priceKopeks — no API call needed.

class _AddTrafficTab extends StatelessWidget {
  final List<TrafficTopupPackage> packages;
  final int? selectedGb;       // selected package gb value
  final ValueChanged<int> onSelected;
  final bool loading;
  final VoidCallback? onConfirm;
  final int? amountKopeks;

  const _AddTrafficTab({
    required this.packages,
    required this.selectedGb,
    required this.onSelected,
    required this.loading,
    required this.onConfirm,
    this.amountKopeks,
  });

  @override
  Widget build(BuildContext context) {
    if (packages.isEmpty) {
      return _Card(child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RowLabel(icon: Icons.data_usage_rounded, label: 'Докупить трафик'),
          SizedBox(height: 10),
          _InfoNote(text: 'Докупка трафика недоступна для вашей подписки.'),
        ],
      ));
    }

    return _Card(padding: EdgeInsets.zero, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Row(children: [
            Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                    color: _DS.sky.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.add_circle_outline_rounded,
                    color: _DS.sky, size: 18)),
            const SizedBox(width: 10),
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Докупить трафик', style: TextStyle(
                    color: _DS.textPrimary, fontSize: 14,
                    fontWeight: FontWeight.w700)),
                Text('Добавляется к текущему лимиту',
                    style: TextStyle(color: _DS.textMuted, fontSize: 11)),
              ],
            )),
          ]),
        ),
        const Divider(height: 1, color: _DS.border),

        // ── Package rows ───────────────────────────────────────────────
        ...packages.asMap().entries.map((e) {
          final i   = e.key;
          final pkg = e.value;
          final sel = pkg.gb == selectedGb;
          final isLast = i == packages.length - 1;
          final hasDiscount = pkg.discountPercent > 0;

          return Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onTap: () => onSelected(pkg.gb),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                    color: sel
                        ? _DS.sky.withValues(alpha: 0.08)
                        : Colors.transparent),
                child: Row(children: [
                  // Radio
                  AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: sel ? _DS.sky : _DS.border,
                              width: sel ? 5.5 : 2),
                          color: sel ? _DS.surface0 : Colors.transparent)),
                  const SizedBox(width: 12),

                  // GB label + discount badge
                  Expanded(child: Row(children: [
                    Text('+${pkg.gb} ГБ', style: TextStyle(
                        color: sel ? _DS.textPrimary : _DS.textSecondary,
                        fontSize: 15, fontWeight: FontWeight.w600)),
                    if (hasDiscount) ...[
                      const SizedBox(width: 8),
                      Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: _DS.amber.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: _DS.amber.withValues(alpha: 0.3))),
                          child: Text('−${pkg.discountPercent}%',
                              style: const TextStyle(
                                  color: _DS.amber, fontSize: 9,
                                  fontWeight: FontWeight.w700))),
                    ],
                  ])),

                  // Price chip
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        gradient: sel
                            ? const LinearGradient(
                            colors: [_DS.sky, Color(0xFF0EA5E9)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight)
                            : null,
                        color: sel ? null : _DS.surface2,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: sel
                                ? _DS.sky.withValues(alpha: 0.4)
                                : _DS.border)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                            pkg.priceLabel.isNotEmpty
                                ? pkg.priceLabel
                                : '${(pkg.priceKopeks / 100).toStringAsFixed(0)} ₽',
                            style: TextStyle(
                                color: sel ? Colors.white : _DS.textMuted,
                                fontSize: 11, fontWeight: FontWeight.w700)),
                        if (hasDiscount &&
                            pkg.originalPriceKopeks != null) ...[
                          Text(
                              '${(pkg.originalPriceKopeks! / 100).toStringAsFixed(0)} ₽',
                              style: TextStyle(
                                  color: sel
                                      ? Colors.white60
                                      : _DS.textMuted.withValues(alpha: 0.6),
                                  fontSize: 9,
                                  decoration: TextDecoration.lineThrough)),
                        ],
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            if (!isLast) const Divider(height: 1, color: _DS.border),
          ]);
        }),

        const Divider(height: 1, color: _DS.border),

        // ── Button ─────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.all(14),
          child: _BuyButton(
            loading: loading,
            onPressed: onConfirm,
            totalKopeks: amountKopeks,
            hasEnoughBalance: true,
          ),
        ),
      ],
    ));
  }
}


// ── Add devices tab ───────────────────────────────────────────────────────────

class _AddDevicesTab extends StatelessWidget {
  final int currentDevices;
  final int? selectedAdd;
  final List<int> options;
  final Map<int, int?> allPrices; // null = loading, int = kopeks
  final ValueChanged<int> onSelected;
  final bool loading;
  final VoidCallback? onConfirm;

  const _AddDevicesTab({
    required this.currentDevices, required this.selectedAdd,
    required this.options, required this.allPrices,
    required this.onSelected, required this.loading,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return _Card(child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RowLabel(icon: Icons.devices_rounded, label: 'Устройства'),
          SizedBox(height: 10),
          _InfoNote(text: 'Лимит устройств уже достигнут для вашего тарифа.'),
        ],
      ));
    }

    final selectedPrice = selectedAdd != null ? allPrices[selectedAdd] : null;

    return _Card(padding: EdgeInsets.zero, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Row(children: [
            Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                    color: _DS.violet.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.devices_rounded, color: _DS.violet, size: 17)),
            const SizedBox(width: 10),
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Добавить устройства', style: TextStyle(
                    color: _DS.textPrimary, fontSize: 14,
                    fontWeight: FontWeight.w700)),
                Text('Увеличение числа подключений',
                    style: TextStyle(color: _DS.textMuted, fontSize: 11)),
              ],
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                  color: _DS.violet.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _DS.violet.withValues(alpha: 0.3))),
              child: Text('$currentDevices устр. сейчас',
                  style: const TextStyle(color: _DS.violet, fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        const Divider(height: 1, color: _DS.border),

        // ── Option rows ──────────────────────────────────────────────
        ...options.asMap().entries.map((e) {
          final i          = e.key;
          final add        = e.value;
          final isSelected = add == selectedAdd;
          final target     = currentDevices + add;
          final isLast     = i == options.length - 1;

          // allPrices[add]: null = still loading, 0+ = loaded
          final priceEntry = allPrices[add];
          final String priceLabel;
          if (!allPrices.containsKey(add)) {
            priceLabel = '…';
          } else if (priceEntry == null) {
            priceLabel = '…';
          } else if (priceEntry == 0) {
            priceLabel = 'Бесплатно';
          } else {
            priceLabel = '${(priceEntry / 100).toStringAsFixed(0)} ₽';
          }

          final bool priceReady = priceEntry != null;

          return Column(mainAxisSize: MainAxisSize.min, children: [
            GestureDetector(
              onTap: () => onSelected(add),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                    color: isSelected
                        ? _DS.violet.withValues(alpha: 0.08)
                        : Colors.transparent),
                child: Row(children: [
                  // Radio
                  AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: isSelected ? _DS.violet : _DS.border,
                              width: isSelected ? 5.5 : 2),
                          color: isSelected ? _DS.surface0 : Colors.transparent)),
                  const SizedBox(width: 12),

                  // Label + arrow
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('+ $add ${_deviceWord(add)}', style: TextStyle(
                          color: isSelected ? _DS.textPrimary : _DS.textSecondary,
                          fontSize: 15, fontWeight: FontWeight.w600)),
                      Text('$currentDevices → $target устр.',
                          style: TextStyle(
                              color: isSelected
                                  ? _DS.violet.withValues(alpha: 0.8)
                                  : _DS.textMuted,
                              fontSize: 11)),
                    ],
                  )),

                  // Price chip — ALL options, gradient on selected
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        gradient: isSelected && priceReady && (priceEntry ?? 0) > 0
                            ? const LinearGradient(
                            colors: [_DS.violet, _DS.violetDim],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight)
                            : null,
                        color: isSelected && priceReady && (priceEntry ?? 1) == 0
                            ? _DS.emerald.withValues(alpha: 0.12)
                            : _DS.surface2,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: isSelected && priceReady
                                ? _DS.violet.withValues(alpha: 0.4)
                                : _DS.border)),
                    child: Text(priceLabel, style: TextStyle(
                        color: isSelected && priceReady
                            ? ((priceEntry ?? 0) > 0 ? Colors.white : _DS.emerald)
                            : _DS.textMuted,
                        fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
            ),
            if (!isLast) const Divider(height: 1, color: _DS.border),
          ]);
        }),

        const Divider(height: 1, color: _DS.border),

        Padding(
          padding: const EdgeInsets.all(14),
          child: _BuyButton(
            loading: loading,
            onPressed: onConfirm,
            totalKopeks: selectedPrice,
            hasEnoughBalance: true,
          ),
        ),
      ],
    ));
  }

  String _deviceWord(int n) {
    final m = n % 10, m100 = n % 100;
    if (m100 >= 11 && m100 <= 19) return 'устройств';
    if (m == 1) return 'устройство';
    if (m >= 2 && m <= 4) return 'устройства';
    return 'устройств';
  }
}


class _BeforeAfter extends StatelessWidget {
  final IconData icon; final String label;
  final String before; final String after; final Color color;
  const _BeforeAfter({required this.icon, required this.label,
    required this.before, required this.after, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(_DS.radiusXs),
        border: Border.all(color: color.withValues(alpha: 0.18))),
    child: Row(children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 9),
      Text(label, style: const TextStyle(color: _DS.textSecondary, fontSize: 13)),
      const Spacer(),
      Text(before, style: const TextStyle(color: _DS.textSecondary, fontSize: 13)),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.arrow_forward_rounded, size: 13, color: _DS.textMuted)),
      Text(after, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
    ]),
  );
}

class _InfoNote extends StatelessWidget {
  final String text;
  const _InfoNote({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
        color: _DS.surface2,
        borderRadius: BorderRadius.circular(_DS.radiusXs),
        border: Border.all(color: _DS.border)),
    child: Row(children: [
      const Icon(Icons.info_outline_rounded, color: _DS.textMuted, size: 15),
      const SizedBox(width: 10),
      Expanded(child: Text(text,
          style: const TextStyle(color: _DS.textSecondary, fontSize: 13))),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Payment polling
// ─────────────────────────────────────────────────────────────────────────────

class _PaymentPollingCard extends StatelessWidget {
  const _PaymentPollingCard();

  @override
  Widget build(BuildContext context) => _Card(accentColor: _DS.violet, child: Column(children: [
    const SizedBox(height: 8),
    const SizedBox(width: 48, height: 48,
        child: CircularProgressIndicator(strokeWidth: 3, color: _DS.violet)),
    const SizedBox(height: 20),
    const Text('Обрабатываем платёж…', textAlign: TextAlign.center,
        style: TextStyle(color: _DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    const Text('Ожидаем подтверждение от платёжного сервиса.\nЭто может занять до 2 минут.',
        textAlign: TextAlign.center,
        style: TextStyle(color: _DS.textSecondary, fontSize: 13, height: 1.6)),
    const SizedBox(height: 8),
  ]));
}

// ─────────────────────────────────────────────────────────────────────────────
// Error card
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) => _Card(child: Column(children: [
    Container(width: 56, height: 56,
        decoration: BoxDecoration(color: _DS.rose.withValues(alpha: 0.1), shape: BoxShape.circle),
        child: const Icon(Icons.wifi_off_rounded, color: _DS.rose, size: 28)),
    const SizedBox(height: 16),
    const Text('Не удалось загрузить тарифы', textAlign: TextAlign.center,
        style: TextStyle(color: _DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
    const SizedBox(height: 14),
    TextButton(onPressed: onRetry, child: const Text('Повторить',
        style: TextStyle(color: _DS.violet, fontWeight: FontWeight.w600))),
  ]));
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
      style: TextStyle(color: _DS.textMuted, fontSize: 11, height: 1.5));
}

// ─────────────────────────────────────────────────────────────────────────────
// Base card
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final Color? accentColor;
  final EdgeInsetsGeometry? padding;
  const _Card({required this.child, this.accentColor, this.padding});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
        color: _DS.surface1,
        borderRadius: BorderRadius.circular(_DS.radius),
        border: Border.all(
            color: accentColor != null ? accentColor!.withValues(alpha: 0.35) : _DS.border),
        boxShadow: accentColor != null
            ? [BoxShadow(color: accentColor!.withValues(alpha: 0.08),
            blurRadius: 24, spreadRadius: -4)]
            : null),
    child: child,
  );
}