import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/me_response.dart';
import '../models/subscription_info.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../theme/app_colors.dart';
import '../widgets/purple_header.dart';
import 'auth_bottom_sheet.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage>
    with WidgetsBindingObserver {
  bool _loading = false;
  SubscriptionInfo? _trafficInfo;
  DateTime? _lastRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);

    _loadCachedMe();
    _refresh();
  }

  Future<void> _loadCachedMe() async {
    await MeService.loadFromCache();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    authStateNotifier.removeListener(_onAuthChanged);
    meNotifier.removeListener(_onMeChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _onAuthChanged() {
    if (!authStateNotifier.value.isLoggedIn) MeService.clear();
    _refresh();
  }

  void _onMeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh({bool force = false}) async {
    if (!mounted) return;

    // защита от частых обновлений
    if (!force &&
        _lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!) <
            const Duration(seconds: 8)) {
      return;
    }

    _lastRefresh = DateTime.now();

    setState(() => _loading = true);

    try {
      // обновляем /me (использует TTL cache)
      await MeService.refresh();

      final subUrl = await RemnawaveService.getSubscriptionUrl();

      if (subUrl.isNotEmpty) {
        await RemnawaveService.fetchNodes();

        if (mounted) {
          setState(() {
            _trafficInfo = RemnawaveService.lastSubscriptionInfo;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _trafficInfo = null;
          });
        }
      }
    } catch (e, st) {
      debugPrint('SubscriptionPage refresh error: $e\n$st');
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me = meNotifier.value;

    return Scaffold(
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () => _refresh(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildAppBar(),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 8),
                  if (!auth.isLoggedIn) ...[
                    _NotLoggedInCard(onLoginTap: _onLoginTap),
                    const SizedBox(height: 12),
                    _BuySubscriptionCard(),
                  ] else if (_loading && me == null) ...[
                    const SizedBox(height: 60),
                    const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                      ),
                    ),
                  ] else ...[
                    // Информация о пользователе - обновленная иконка!
                    _UserCard(me: me, auth: auth),
                    const SizedBox(height: 12),

                    // Статус подписки из MeService
                    _SubscriptionStatusCard(me: me),
                    const SizedBox(height: 12),

                    // Трафик - комбинируем данные
                    if (me?.subscription != null) ...[
                      _TrafficCard(
                        sub: me!.subscription!,
                        trafficInfo: _trafficInfo, // Добавляем данные о трафике
                      ),
                      const SizedBox(height: 12),

                      // Детали подписки из MeService
                      _SubscriptionDetailsCard(sub: me.subscription!),
                      const SizedBox(height: 12),

                      // URL подписки
                      if (me.subscription!.subscriptionUrl != null)
                        _SubscriptionUrlCard(
                          url: me.subscription!.subscriptionUrl!,
                        ),
                      const SizedBox(height: 12),
                    ],
                    _QuickActionsCard(onLogout: _onLogout),
                  ],
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverToBoxAdapter _buildAppBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 16, 16, 16),
        child: PurpleHeader(
          title: 'Подписка',
          subtitle: 'Управляйте подпиской',
          showBeta: false,
          trailing: Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceSoft.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refresh(force: true),
              tooltip: 'Обновить',
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onLoginTap() async {
    await showAuthBottomSheet(context);
  }

  Future<void> _onLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.graphiteSurface,
        title: const Text(
          'Выйти из аккаунта?',
          style: TextStyle(color: AppColors.textNeutralMain),
        ),
        content: const Text(
          'Данные подписки будут сброшены.',
          style: TextStyle(color: AppColors.textNeutralSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Выйти',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await AuthService.logout();
      debugPrint('SubPage: logout proccess compeleted');
    }
  }
}

// ── Cards ─────────────────────────────────────────────────────────────────────

class _NotLoggedInCard extends StatelessWidget {
  final VoidCallback onLoginTap;

  const _NotLoggedInCard({required this.onLoginTap});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_person_outlined,
              color: AppColors.primary,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Нужна авторизация',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Войдите через Telegram, чтобы увидеть данные подписки и управлять аккаунтом.',
            style: TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 14,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onLoginTap,
              icon: const Icon(Icons.telegram, size: 20),
              label: const Text(
                'Войти через Telegram',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF229ED9),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BuySubscriptionCard extends StatelessWidget {
  const _BuySubscriptionCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.star_outline, color: Colors.amber[400], size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Купить подписку',
                  style: TextStyle(
                    color: AppColors.textNeutralMain,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Скоро будет доступно прямо в приложении',
                  style: TextStyle(
                    color: AppColors.textNeutralMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: AppColors.textNeutralMuted,
            size: 20,
          ),
        ],
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final MeResponse? me;
  final AuthState auth;

  const _UserCard({required this.me, required this.auth});

  @override
  Widget build(BuildContext context) {
    final name = me?.displayName ?? auth.displayName;
    final username = me?.username ?? auth.username;

    return _Card(
      child: Row(
        children: [
          // Новая, более заметная иконка пользователя!
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4A4E69), Color(0xFF6C757D)], // Приглушенные серо-синие
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4A4E69).withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 24,
                  shadows: [
                    Shadow(
                      color: Colors.black26,
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: AppColors.textNeutralMain,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (username != null && username.isNotEmpty)
                  Text(
                    '@$username',
                    style: const TextStyle(
                      color: AppColors.textNeutralSecondary,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF229ED9).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.telegram,
              color: Color(0xFF229ED9),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionStatusCard extends StatelessWidget {
  final MeResponse? me;

  const _SubscriptionStatusCard({required this.me});

  @override
  Widget build(BuildContext context) {
    final sub = me?.subscription;

    Color statusColor;
    IconData statusIcon;
    String statusLabel;
    String statusDetail;

    if (sub == null) {
      statusColor = AppColors.textNeutralMuted;
      statusIcon = Icons.remove_circle_outline;
      statusLabel = 'Нет подписки';
      statusDetail = 'Подписка не найдена';
    } else if (sub.isActive) {
      statusColor = AppColors.success;
      statusIcon = Icons.verified_outlined;
      statusLabel = sub.isTrial ? 'Пробный период' : 'Активна';
      statusDetail = 'Действует до ${sub.formattedExpiry}';
    } else if (sub.isExpired) {
      statusColor = AppColors.danger;
      statusIcon = Icons.cancel_outlined;
      statusLabel = 'Истекла';
      statusDetail = 'Истекла ${sub.formattedExpiry}';
    } else {
      statusColor = AppColors.warning;
      statusIcon = Icons.warning_amber_outlined;
      statusLabel = sub.status;
      statusDetail = 'До ${sub.formattedExpiry}';
    }

    return _Card(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(statusIcon, color: statusColor, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusDetail,
                  style: const TextStyle(
                    color: AppColors.textNeutralSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final MeSubscription sub;
  final SubscriptionInfo? trafficInfo;

  const _TrafficCard({required this.sub, required this.trafficInfo});

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.trafficLimitGb == 0;

    final usedBytes = trafficInfo?.usedBytes ?? (sub.trafficUsedGb * 1024 * 1024 * 1024).round();
    final totalBytes = trafficInfo?.totalBytes ?? (sub.trafficLimitGb * 1024 * 1024 * 1024).round();

    final usedFraction = totalBytes > 0 ? usedBytes / totalBytes : 0.0;
    final usedLabel = trafficInfo?.formattedUsed ?? '${sub.trafficUsedGb.toStringAsFixed(1)} ГБ';
    final totalLabel = trafficInfo?.formattedTotal ?? (unlimited ? '∞' : '${sub.trafficLimitGb} ГБ');

    final remainingBytes = totalBytes - usedBytes;
    final remainingLabel = _formatRemainingBytes(remainingBytes);

    // Только один цветовой акцент - для прогресс-бара
    Color accentColor;
    if (unlimited) {
      accentColor = AppColors.primary;
    } else if (usedFraction >= 0.9) {
      accentColor = AppColors.danger;
    } else if (usedFraction >= 0.7) {
      accentColor = AppColors.warning;
    } else {
      accentColor = AppColors.accentSmoky;
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Минималистичный заголовок
          const Text(
            'Трафик',
            style: TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),

          const SizedBox(height: 12),

          // Основной показатель - крупно
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                usedLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '/ $totalLabel',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),

          if (!unlimited) ...[
            const SizedBox(height: 16),

            // Прогресс-бар (единственный цветной элемент)
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: usedFraction,
                minHeight: 6,
                backgroundColor: Colors.grey[850],
                valueColor: AlwaysStoppedAnimation<Color>(accentColor),
              ),
            ),

            const SizedBox(height: 12),

            // Два показателя в строку - без лишних иконок
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Осталось
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Осталось',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      remainingLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),

                // Процент
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Использовано',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(usedFraction * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 16),

            // Безлимит - лаконично
            Row(
              children: [
                Icon(
                  Icons.all_inclusive,
                  color: AppColors.accentSmoky,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Безлимитный трафик',
                  style: TextStyle(
                    color: AppColors.textNeutralMain,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _formatRemainingBytes(int bytes) {
    if (bytes <= 0) return '0 ГБ';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} ГБ';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} МБ';
  }
}

class _SubscriptionDetailsCard extends StatelessWidget {
  final MeSubscription sub;

  const _SubscriptionDetailsCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    // Определяем статус подписки
    final isActive = sub.isActive && !sub.isExpired;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Заголовок с иконкой (уникальная)
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.accentSmoky.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.info_outline, // Уникальная иконка
                  color: AppColors.accentSmoky,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Детали подписки',
                style: TextStyle(
                  color: AppColors.textNeutralMain,
                  fontWeight: FontWeight.w500,
                  fontSize: 15,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Список деталей с уникальными иконками
          _DetailItem(
            icon: sub.isTrial ? Icons.free_breakfast : Icons.workspace_premium_outlined,
            label: 'Тип',
            value: sub.isTrial ? 'Пробный' : 'Платный',
            color: AppColors.accentSmoky,
          ),

          const SizedBox(height: 14),

          _DetailItem(
            icon: Icons.devices_other_outlined,
            label: 'Устройства',
            value: '${sub.deviceLimit} ${_getDeviceWord(sub.deviceLimit)}',
            color: AppColors.accentSmoky,
          ),

          const SizedBox(height: 14),

          _DetailItem(
            icon: Icons.event_outlined,
            label: 'Действует до',
            value: sub.formattedExpiry,
            color: sub.isExpired ? AppColors.danger : AppColors.accentSmoky,
            valueColor: sub.isExpired ? AppColors.danger : null,
          ),

          if (sub.trafficLimitGb > 0) ...[
            const SizedBox(height: 14),
            _DetailItem(
              icon: Icons.compare_arrows_outlined, // Уникальная иконка для трафика
              label: 'Лимит',
              value: '${sub.trafficLimitGb} ГБ',
              color: AppColors.accentSmoky,
            ),
          ],

          const SizedBox(height: 16),

          // Статус подписки одной строкой (без дублирования иконок)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.success.withValues(alpha: 0.05)
                  : sub.isExpired
                  ? AppColors.danger.withValues(alpha: 0.05)
                  : Colors.grey.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  isActive
                      ? Icons.verified_outlined
                      : sub.isExpired
                      ? Icons.timer_off_outlined
                      : Icons.help_outline,
                  size: 14,
                  color: isActive
                      ? AppColors.success
                      : sub.isExpired
                      ? AppColors.danger
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isActive
                        ? 'Подписка активна'
                        : sub.isExpired
                        ? 'Срок действия истек'
                        : 'Статус неизвестен',
                    style: TextStyle(
                      color: isActive
                          ? AppColors.success
                          : sub.isExpired
                          ? AppColors.danger
                          : Colors.grey,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getDeviceWord(int count) {
    if (count % 10 == 1 && count % 100 != 11) return 'устройство';
    if (count % 10 >= 2 && count % 10 <= 4 &&
        (count % 100 < 10 || count % 100 >= 20)) return 'устройства';
    return 'устройств';
  }
}

// Вспомогательный виджет для строк деталей
class _DetailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final Color? valueColor;

  const _DetailItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          alignment: Alignment.centerLeft,
          child: Icon(
            icon,
            size: 16,
            color: color.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[500],
            fontSize: 13,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _SubscriptionUrlCard extends StatelessWidget {
  final String url;

  const _SubscriptionUrlCard({required this.url});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'URL подписки',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  url,
                  style: const TextStyle(
                    color: AppColors.textNeutralSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(
                  Icons.copy_outlined,
                  size: 20,
                  color: AppColors.primary,
                ),
                tooltip: 'Копировать',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('URL скопирован'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActionsCard extends StatelessWidget {
  final VoidCallback onLogout;

  const _QuickActionsCard({required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Действия',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          _ActionRow(
            icon: Icons.star_border,
            iconColor: Colors.amber,
            label: 'Купить / продлить',
            subtitle: 'Скоро в приложении',
            onTap: null,
          ),
          const Divider(color: AppColors.graphiteElevated, height: 20),
          _ActionRow(
            icon: Icons.logout,
            iconColor: AppColors.danger,
            label: 'Выйти из аккаунта',
            onTap: onLogout,
          ),
        ],
      ),
    );
  }
}

// ── Shared components ─────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: child,
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textNeutralSecondary,
              fontSize: 13,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textNeutralMain,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: onTap != null
                          ? AppColors.textNeutralMain
                          : AppColors.textNeutralMuted,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: AppColors.textNeutralMuted,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right,
                color: AppColors.textNeutralMuted,
                size: 18,
              ),
          ],
        ),
      ),
    );
  }
}