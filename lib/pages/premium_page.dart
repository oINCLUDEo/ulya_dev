import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class PremiumPage extends StatelessWidget {
  const PremiumPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.graphiteBackground,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: AppColors.graphiteBackground,
            elevation: 0,
            floating: true,
            snap: true,
            title: const Text(
              'Premium',
              style: TextStyle(
                color: AppColors.textNeutralMain,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 8),
                _HeroCard(),
                const SizedBox(height: 16),
                const _SectionTitle('Преимущества'),
                const SizedBox(height: 8),
                _BenefitCard(
                  icon: Icons.speed,
                  iconColor: const Color(0xFF00D9FF),
                  title: 'Высокая скорость',
                  description:
                      'Выделенные серверы без ограничений по скорости — '
                      'для стриминга, игр и работы.',
                ),
                const SizedBox(height: 8),
                _BenefitCard(
                  icon: Icons.devices,
                  iconColor: AppColors.primary,
                  title: 'Несколько устройств',
                  description:
                      'Подключайте до 5 устройств одновременно: '
                      'телефон, планшет, ноутбук.',
                ),
                const SizedBox(height: 8),
                _BenefitCard(
                  icon: Icons.public,
                  iconColor: AppColors.success,
                  title: 'Серверы по всему миру',
                  description:
                      'Более 20 стран. Выбирайте сервер с минимальной '
                      'задержкой для вашего региона.',
                ),
                const SizedBox(height: 8),
                _BenefitCard(
                  icon: Icons.lock_outline,
                  iconColor: Colors.amber,
                  title: 'Конфиденциальность',
                  description:
                      'Политика без логов. Ваша активность не '
                      'записывается и не передаётся третьим лицам.',
                ),
                const SizedBox(height: 8),
                _BenefitCard(
                  icon: Icons.support_agent,
                  iconColor: AppColors.warning,
                  title: 'Приоритетная поддержка',
                  description:
                      'Ответ в течение часа через Telegram. '
                      'Помощь с настройкой на любом устройстве.',
                ),
                const SizedBox(height: 16),
                const _SectionTitle('Тарифы'),
                const SizedBox(height: 8),
                _PlanCard(
                  title: '1 месяц',
                  badge: null,
                  price: '—',
                  period: '/ мес',
                  highlight: false,
                ),
                const SizedBox(height: 8),
                _PlanCard(
                  title: '3 месяца',
                  badge: 'Выгодно',
                  price: '—',
                  period: '/ мес',
                  highlight: true,
                ),
                const SizedBox(height: 8),
                _PlanCard(
                  title: '12 месяцев',
                  badge: 'Максимальная экономия',
                  price: '—',
                  period: '/ мес',
                  highlight: false,
                ),
                const SizedBox(height: 24),
                _ComingSoonBanner(),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Components ────────────────────────────────────────────────────────────────

class _HeroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFF311459), Color(0xFF43255F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.workspace_premium,
              color: Colors.amber,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Ulya VPN Premium',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Безлимитный VPN без ограничений скорости. '
            'Надёжная защита и полный доступ к интернету.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 14,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

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

class _BenefitCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;

  const _BenefitCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textNeutralMain,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                    color: AppColors.textNeutralSecondary,
                    fontSize: 13,
                    height: 1.4,
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

class _PlanCard extends StatelessWidget {
  final String title;
  final String? badge;
  final String price;
  final String period;
  final bool highlight;

  const _PlanCard({
    required this.title,
    this.badge,
    required this.price,
    required this.period,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.primary.withValues(alpha: 0.12)
            : AppColors.graphiteSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight
              ? AppColors.primary.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.06),
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: highlight
                            ? AppColors.primary
                            : AppColors.textNeutralMain,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: price,
                  style: const TextStyle(
                    color: AppColors.textNeutralMain,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
                TextSpan(
                  text: price == '—' ? '' : period,
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

class _ComingSoonBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.construction, color: Colors.amber[400], size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Скоро',
                  style: TextStyle(
                    color: Colors.amber[400],
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Оплата подписки будет доступна прямо в этом приложении. '
                  'Следите за обновлениями!',
                  style: TextStyle(
                    color: Colors.amber[300],
                    fontSize: 13,
                    height: 1.4,
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
