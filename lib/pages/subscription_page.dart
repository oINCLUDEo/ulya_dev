import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/me_response.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../theme/app_colors.dart';
import 'auth_bottom_sheet.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage>
    with WidgetsBindingObserver {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    authStateNotifier.addListener(_onAuthChanged);
    meNotifier.addListener(_onMeChanged);
    _refresh();
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

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    await MeService.refresh();
    if (mounted) setState(() => _loading = false);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final auth = authStateNotifier.value;
    final me = meNotifier.value;

    return Scaffold(
      backgroundColor: AppColors.graphiteBackground,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _refresh,
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
                      child: CircularProgressIndicator(color: AppColors.primary),
                    ),
                  ] else ...[
                    _UserCard(me: me, auth: auth),
                    const SizedBox(height: 12),
                    _SubscriptionStatusCard(me: me),
                    const SizedBox(height: 12),
                    if (me?.subscription != null) ...[
                      _TrafficCard(sub: me!.subscription!),
                      const SizedBox(height: 12),
                      _SubscriptionDetailsCard(sub: me.subscription!),
                      const SizedBox(height: 12),
                      if (me.subscription!.subscriptionUrl != null)
                        _SubscriptionUrlCard(url: me.subscription!.subscriptionUrl!),
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

  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      backgroundColor: AppColors.graphiteBackground,
      elevation: 0,
      floating: true,
      snap: true,
      title: const Text(
        'Подписка',
        style: TextStyle(
          color: AppColors.textNeutralMain,
          fontWeight: FontWeight.bold,
          fontSize: 20,
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh, color: AppColors.textNeutralSecondary),
          onPressed: _refresh,
        ),
      ],
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
            child: const Text('Выйти', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await AuthService.logout();
      MeService.clear();
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
          Icon(Icons.chevron_right, color: AppColors.textNeutralMuted, size: 20),
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
          CircleAvatar(
            radius: 26,
            backgroundColor: AppColors.primary.withValues(alpha: 0.25),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.bold,
                fontSize: 22,
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
                if (username != null && username.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '@$username',
                    style: const TextStyle(
                      color: AppColors.textNeutralSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.telegram, color: Color(0xFF229ED9), size: 22),
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
      statusIcon = Icons.check_circle_outline;
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

  const _TrafficCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    final unlimited = sub.trafficLimitGb == 0;
    final fraction = sub.trafficFraction;
    final usedLabel = '${sub.trafficUsedGb.toStringAsFixed(1)} ГБ';
    final limitLabel = unlimited ? '∞' : '${sub.trafficLimitGb} ГБ';

    Color barColor;
    if (unlimited) {
      barColor = AppColors.primary;
    } else if (fraction > 0.9) {
      barColor = AppColors.danger;
    } else if (fraction > 0.7) {
      barColor = AppColors.warning;
    } else {
      barColor = AppColors.success;
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Трафик',
                style: TextStyle(
                  color: AppColors.textNeutralMain,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              Text(
                unlimited ? 'Безлимит' : '$usedLabel / $limitLabel',
                style: const TextStyle(
                  color: AppColors.textNeutralSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          if (!unlimited) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                backgroundColor: AppColors.graphiteElevated,
                color: barColor,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(fraction * 100).toStringAsFixed(0)}% использовано',
              style: const TextStyle(
                color: AppColors.textNeutralMuted,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionDetailsCard extends StatelessWidget {
  final MeSubscription sub;

  const _SubscriptionDetailsCard({required this.sub});

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Детали подписки',
            style: TextStyle(
              color: AppColors.textNeutralMain,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          _DetailRow(label: 'Тип', value: sub.isTrial ? 'Пробный период' : 'Платная'),
          _DetailRow(label: 'Устройства', value: '${sub.deviceLimit}'),
          _DetailRow(label: 'Истекает', value: sub.formattedExpiry),
          _DetailRow(
            label: 'Трафик',
            value: sub.trafficLimitGb == 0
                ? 'Безлимит'
                : '${sub.trafficLimitGb} ГБ',
          ),
        ],
      ),
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
