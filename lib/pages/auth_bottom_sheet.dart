import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';

/// Shows a modal bottom sheet that explains why auth is needed and triggers
/// the Telegram deep-link login flow.
///
/// Completes with `true` when the user successfully logged in,
/// `false` / null when dismissed without logging in.
Future<bool> showAuthBottomSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    isDismissible: true,
    builder: (ctx) => const _AuthBottomSheet(),
  );
  return result ?? false;
}

// ── Bottom sheet ─────────────────────────────────────────────────────────────

class _AuthBottomSheet extends StatefulWidget {
  const _AuthBottomSheet();

  @override
  State<_AuthBottomSheet> createState() => _AuthBottomSheetState();
}

enum _AuthStep {
  idle,     // initial — "Login" button visible
  opening,  // waiting for deep-link launch
  waiting,  // Telegram opened, polling…
  success,  // authenticated — show success animation
  error,    // something failed
}

class _AuthBottomSheetState extends State<_AuthBottomSheet>
    with SingleTickerProviderStateMixin {
  _AuthStep _step = _AuthStep.idle;
  String? _errorMessage;
  String? _token;
  StreamSubscription<AuthResult>? _pollSub;

  // ── Success animation ──────────────────────────────────────────────────────
  late final AnimationController _successCtrl;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _successCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _successCtrl,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );
  }

  @override
  void dispose() {
    _pollSub?.cancel();
    _successCtrl.dispose();
    super.dispose();
  }

  // ── Login button handler ──────────────────────────────────────────────────

  Future<void> _onLoginTap() async {
    if (_step != _AuthStep.idle && _step != _AuthStep.error) return;

    setState(() {
      _step = _AuthStep.opening;
      _errorMessage = null;
    });

    final token = await AuthService.startLogin(
      onError: (msg) {
        if (mounted) {
          setState(() {
            _step = _AuthStep.error;
            _errorMessage = msg;
          });
        }
      },
    );

    if (token == null || !mounted) return;

    _token = token;
    setState(() => _step = _AuthStep.waiting);
    _startPolling(token);
  }

  void _startPolling(String token) {
    _pollSub?.cancel();
    _pollSub = AuthService.pollStatus(token).listen(
          (result) {
        if (!mounted) {
          _pollSub?.cancel();
          return;
        }
        if (result.success) {
          _pollSub?.cancel();
          _showSuccessAndClose();
        } else if (result.error != null) {
          _pollSub?.cancel();
          setState(() {
            _step = _AuthStep.error;
            _errorMessage = result.error;
          });
        }
        // AuthResult.pending — keep polling, no UI change needed
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _step = _AuthStep.error;
            _errorMessage = 'Ошибка соединения. Попробуйте снова.';
          });
        }
      },
    );
  }

  /// Play success animation then close the sheet with true.
  Future<void> _showSuccessAndClose() async {
    if (!mounted) return;
    setState(() => _step = _AuthStep.success);
    await _successCtrl.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Full-screen success overlay
    if (_step == _AuthStep.success) {
      return Container(
        decoration: const BoxDecoration(
          color: Color(0xFF171A21),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 260,
            child: Center(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: ScaleTransition(
                  scale: _scaleAnim,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2ED573).withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_circle,
                          color: Color(0xFF2ED573),
                          size: 44,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Авторизация успешна!',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Добро пожаловать',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF171A21),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),

            // ── Icon ──────────────────────────────────────────────────────
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _step == _AuthStep.waiting
                    ? Icons.telegram
                    : Icons.lock_person_outlined,
                size: 36,
                color: _step == _AuthStep.waiting
                    ? const Color(0xFF229ED9)
                    : const Color(0xFF6C5CE7),
              ),
            ),

            const SizedBox(height: 20),

            // ── Title ────────────────────────────────────────────────────
            Text(
              _step == _AuthStep.waiting
                  ? 'Ожидаем подтверждения…'
                  : 'Нужна авторизация',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 10),

            // ── Body text ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _buildBodyText(),
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 28),

            // ── Action area ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildActionArea(),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── Body text ─────────────────────────────────────────────────────────────

  String _buildBodyText() {
    switch (_step) {
      case _AuthStep.idle:
        return 'Для подключения к VPN-серверам необходима активная подписка. '
            'Войдите через Telegram одним касанием.';
      case _AuthStep.opening:
        return 'Открываем Telegram…';
      case _AuthStep.waiting:
        return 'Telegram открыт. Нажмите «Старт» в боте — '
            'авторизация завершится автоматически.';
      case _AuthStep.success:
        return '';
      case _AuthStep.error:
        return _errorMessage ?? 'Произошла ошибка. Попробуйте снова.';
    }
  }

  // ── Action area ───────────────────────────────────────────────────────────

  Widget _buildActionArea() {
    switch (_step) {
      case _AuthStep.idle:
        return _LoginButton(onTap: _onLoginTap);
      case _AuthStep.opening:
        return const _LoadingRow(label: 'Открываем Telegram…');
      case _AuthStep.waiting:
        return Column(
          children: [
            const _LoadingRow(label: 'Ожидаем подтверждения…'),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                _pollSub?.cancel();
                setState(() {
                  _step = _AuthStep.idle;
                  _errorMessage = null;
                  _token = null;
                });
              },
              child: const Text(
                'Отмена',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        );
      case _AuthStep.success:
        return const SizedBox.shrink();
      case _AuthStep.error:
        return _LoginButton(onTap: _onLoginTap, label: 'Попробовать снова');
    }
  }

}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _LoginButton extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const _LoginButton({
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
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF229ED9), // Telegram blue
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

class _LoadingRow extends StatelessWidget {
  final String label;

  const _LoadingRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF6C5CE7),
          ),
        ),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    );
  }
}
