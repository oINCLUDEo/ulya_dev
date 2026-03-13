import 'package:flutter/material.dart';

/// A reusable "Login with Telegram" button used consistently across the app.
///
/// Style: full-width, Telegram blue (#229ED9), `Icons.telegram` icon,
/// 14 px vertical padding, 14 px border-radius.
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
      child: FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.telegram, size: 20),
        label: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF229ED9),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
