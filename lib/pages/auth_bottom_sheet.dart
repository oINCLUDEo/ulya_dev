import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../main.dart' show DS;

/// Shows a modal bottom sheet for Telegram authentication.
/// Returns `true` on success, `false`/`null` if dismissed.
Future<bool> showAuthBottomSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    isDismissible: true,
    builder: (ctx) => const _AuthSheet(),
  );
  return result ?? false;
}

// ─────────────────────────────────────────────────────────────────────────────

enum _Step { idle, opening, waiting, success, error }

class _AuthSheet extends StatefulWidget {
  const _AuthSheet();

  @override
  State<_AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends State<_AuthSheet>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.idle;
  String? _errorMessage;
  StreamSubscription<AuthResult>? _pollSub;

  late final AnimationController _successCtrl;
  late final Animation<double> _scaleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _successCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 550));
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _successCtrl, curve: Curves.elasticOut));
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _successCtrl,
            curve: const Interval(0.0, 0.45, curve: Curves.easeIn)));
  }

  @override
  void dispose() {
    _pollSub?.cancel();
    _successCtrl.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────
  Future<void> _onLoginTap() async {
    if (_step != _Step.idle && _step != _Step.error) return;
    setState(() { _step = _Step.opening; _errorMessage = null; });

    final token = await AuthService.startLogin(onError: (msg) {
      if (mounted) setState(() { _step = _Step.error; _errorMessage = msg; });
    });

    if (token == null || !mounted) return;
    setState(() => _step = _Step.waiting);
    _startPolling(token);
  }

  void _startPolling(String token) {
    _pollSub?.cancel();
    _pollSub = AuthService.pollStatus(token).listen(
          (result) {
        if (!mounted) { _pollSub?.cancel(); return; }
        if (result.success) {
          _pollSub?.cancel();
          _showSuccess();
        } else if (result.error != null) {
          _pollSub?.cancel();
          setState(() { _step = _Step.error; _errorMessage = result.error; });
        }
      },
      onError: (_) {
        if (mounted) {
          setState(() {
            _step = _Step.error;
            _errorMessage = 'Ошибка соединения. Попробуйте снова.';
          });
        }
      },
    );
  }

  Future<void> _showSuccess() async {
    if (!mounted) return;
    setState(() => _step = _Step.success);
    await _successCtrl.forward();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) Navigator.pop(context, true);
  }

  void _cancel() {
    _pollSub?.cancel();
    setState(() { _step = _Step.idle; _errorMessage = null; });
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: _step == _Step.success ? _buildSuccess() : _buildMain(),
      ),
    );
  }

  Widget _buildSuccess() {
    return SizedBox(
      height: 260,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: ScaleTransition(
            scale: _scaleAnim,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 76, height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: DS.emerald.withValues(alpha: 0.12),
                    border: Border.all(color: DS.emerald.withValues(alpha: 0.3), width: 1.5),
                  ),
                  child: const Icon(Icons.check_rounded, color: DS.emerald, size: 38)),
              const SizedBox(height: 20),
              const Text('Авторизация успешна!', style: TextStyle(
                  color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Добро пожаловать',
                  style: TextStyle(color: DS.textSecondary, fontSize: 14)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildMain() {
    final waiting = _step == _Step.waiting;
    final isError = _step == _Step.error;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle
        const SizedBox(height: 12),
        Container(width: 40, height: 4,
            decoration: BoxDecoration(color: DS.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 28),

        // Icon
        Container(
          width: 68, height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (waiting ? DS.telegramBlue : DS.violet).withValues(alpha: 0.1),
            border: Border.all(
                color: (waiting ? DS.telegramBlue : DS.violet).withValues(alpha: 0.25)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Icon(
              key: ValueKey(waiting),
              waiting ? Icons.telegram : Icons.lock_outline_rounded,
              size: 32,
              color: waiting ? DS.telegramBlue : DS.violet,
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Title
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Text(
            key: ValueKey(waiting),
            waiting ? 'Ожидаем подтверждения…' : 'Нужна авторизация',
            style: const TextStyle(
                color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
        ),

        const SizedBox(height: 10),

        // Body text
        Text(
          _bodyText(),
          style: TextStyle(
              color: isError ? DS.rose.withValues(alpha: 0.9) : DS.textSecondary,
              fontSize: 14, height: 1.5),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 28),

        // Action
        _buildAction(),

        if (waiting) ...[
          const SizedBox(height: 12),
          TextButton(
              onPressed: _cancel,
              child: const Text('Отмена',
                  style: TextStyle(color: DS.textMuted, fontSize: 13))),
        ],
      ]),
    );
  }

  String _bodyText() {
    switch (_step) {
      case _Step.idle:
        return 'Для подключения к VPN-серверам необходима активная подписка. '
            'Войдите через Telegram одним касанием.';
      case _Step.opening:  return 'Открываем Telegram…';
      case _Step.waiting:
        return 'Telegram открыт. Нажмите «Старт» в боте — '
            'авторизация завершится автоматически.';
      case _Step.success:  return '';
      case _Step.error:    return _errorMessage ?? 'Произошла ошибка. Попробуйте снова.';
    }
  }

  Widget _buildAction() {
    switch (_step) {
      case _Step.idle:
      case _Step.error:
        return _TelegramButton(
          label: _step == _Step.error ? 'Попробовать снова' : 'Войти через Telegram',
          onTap: _onLoginTap,
        );
      case _Step.opening:
      case _Step.waiting:
        return _LoadingRow(
            label: _step == _Step.opening ? 'Открываем Telegram…' : 'Ожидаем подтверждения…');
      case _Step.success:
        return const SizedBox.shrink();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

class _TelegramButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TelegramButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: DS.telegramBlue,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          boxShadow: [BoxShadow(
              color: DS.telegramBlue.withValues(alpha: 0.35),
              blurRadius: 18, offset: const Offset(0, 5))],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.telegram, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
      ),
    ),
  );
}

class _LoadingRow extends StatelessWidget {
  final String label;
  const _LoadingRow({required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const SizedBox(width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: DS.violet)),
      const SizedBox(width: 12),
      Text(label, style: const TextStyle(color: DS.textSecondary, fontSize: 14)),
    ],
  );
}
