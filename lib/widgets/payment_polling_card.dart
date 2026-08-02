import 'package:flutter/material.dart';

import '../main.dart' show DS;

/// Shared "checking payment" card shown while a page polls for payment
/// confirmation. Neutral violet accent on purpose — this is an in-progress
/// state, not a success, so it must not read as a green/teal "done" badge.
///
/// [onCancel] lets the user bail out of the wait instead of being stuck
/// looking at a spinner for up to the full poll window.
class PaymentPollingCard extends StatelessWidget {
  final VoidCallback onCancel;
  final String title;
  final String subtitle;

  const PaymentPollingCard({
    super.key,
    required this.onCancel,
    this.title = 'Обрабатываем платёж…',
    this.subtitle = 'Ожидаем подтверждение.\nОбычно это занимает меньше минуты.',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: DS.violet.withValues(alpha: 0.28)),
      ),
      child: Column(children: [
        const SizedBox(
          width: 52, height: 52,
          child: CircularProgressIndicator(strokeWidth: 3, color: DS.violet),
        ),
        const SizedBox(height: 24),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: DS.textSecondary, fontSize: 14, height: 1.6)),
        const SizedBox(height: 20),
        TextButton(
          onPressed: onCancel,
          child: const Text('Отменить',
              style: TextStyle(color: DS.textSecondary, fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}
