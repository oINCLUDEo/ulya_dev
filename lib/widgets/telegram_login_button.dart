import 'package:flutter/material.dart';

import '../main.dart' show DS;

/// Кнопка «Войти через Telegram». Используется на главном экране и в Premium.
class TelegramLoginButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const TelegramLoginButton({
    super.key,
    required this.onTap,
    this.label = 'Войти через Telegram',
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.telegram, size: 22),
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: DS.telegramBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DS.radius),
          ),
        ),
      ),
    );
  }
}
