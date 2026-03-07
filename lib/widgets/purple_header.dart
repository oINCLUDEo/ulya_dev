import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class PurpleHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showBeta;
  final Widget? trailing;

  const PurpleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showBeta = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Левая часть: заголовок + подзаголовок + BETA
        Container(
          // Тут добавляем свечение
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: -8,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Основной заголовок
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppColors.textMain,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // BETA плашка
                  if (showBeta)
                    Container(
                      padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: AppColors.gradientAccent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: const Text(
                        'BETA',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                ],
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    subtitle!,
                    key: ValueKey(subtitle),
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Правая часть: кастомный виджет
        if (trailing != null) trailing!,
      ],
    );
  }
}