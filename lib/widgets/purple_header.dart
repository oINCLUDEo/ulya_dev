import 'package:flutter/material.dart';
import '../main.dart' show DS;

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
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: DS.violet.withValues(alpha: 0.35),
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
                  Text(
                    title,
                    style: const TextStyle(
                      color: DS.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (showBeta)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [DS.violet, DS.violetDim],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(DS.radiusXs),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: const Text(
                        'BETA',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
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
                    style: const TextStyle(
                      color: DS.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}
