import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

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
enum _Provider { telegram, google }

class _AuthSheet extends StatefulWidget {
  const _AuthSheet();

  @override
  State<_AuthSheet> createState() => _AuthSheetState();
}

class _AuthSheetState extends State<_AuthSheet>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.idle;
  _Provider _provider = _Provider.telegram;
  String? _errorMessage;
  StreamSubscription<AuthResult>? _pollSub;

  // ── Email mode ─────────────────────────────────────────────────────────────
  bool _emailMode = false;
  bool _registerMode = false;
  bool _emailBusy = false;
  bool _obscurePass = true;
  String? _emailNotice;
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();

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
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────
  Future<void> _onLoginTap() async {
    if (_step != _Step.idle && _step != _Step.error) return;
    setState(() {
      _step = _Step.opening;
      _provider = _Provider.telegram;
      _errorMessage = null;
    });

    // Primary: full Telegram OAuth via oauth.telegram.org (same as the cabinet).
    final res = await AuthService.signInWithTelegram();
    if (!mounted) return;
    if (res == null) {
      _showSuccess();
      return;
    }
    if (res == AuthService.telegramCancelled) {
      setState(() => _step = _Step.idle);
      return;
    }
    // Blocked/unreachable oauth.telegram.org → fall back to the bot deep-link.
    await _startDeepLinkTelegram();
  }

  /// Resilience fallback: original bot deep-link login, used when the
  /// oauth.telegram.org OIDC path fails (e.g. the domain is blocked).
  Future<void> _startDeepLinkTelegram() async {
    if (!mounted) return;
    setState(() {
      _step = _Step.opening;
      _provider = _Provider.telegram;
      _errorMessage = null;
    });

    final token = await AuthService.startLogin(onError: (msg) {
      if (mounted) setState(() { _step = _Step.error; _errorMessage = msg; });
    });

    if (token == null || !mounted) return;
    setState(() => _step = _Step.waiting);
    _startPolling(token);
  }

  Future<void> _onGoogleTap() async {
    if (_step != _Step.idle && _step != _Step.error) return;
    setState(() {
      _step = _Step.opening;
      _provider = _Provider.google;
      _errorMessage = null;
    });

    // Cabinet OAuth is synchronous from our point of view: the in-app
    // browser blocks until the redirect arrives, then the call returns.
    // No long-poll loop needed.
    final error = await AuthService.signInWithGoogle();
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _step = _Step.error;
        _errorMessage = error;
      });
      return;
    }
    _showSuccess();
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

  // ── Email actions ──────────────────────────────────────────────────────────

  void _openEmailMode() {
    setState(() {
      _emailMode = true;
      _registerMode = false;
      _errorMessage = null;
      _emailNotice = null;
    });
  }

  void _closeEmailMode() {
    if (_emailBusy) return;
    setState(() {
      _emailMode = false;
      _errorMessage = null;
      _emailNotice = null;
    });
  }

  Future<void> _submitEmail() async {
    if (_emailBusy) return;
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text;
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Введите корректный email.');
      return;
    }
    if (pass.length < 6) {
      setState(() => _errorMessage = 'Пароль должен быть не короче 6 символов.');
      return;
    }
    setState(() {
      _emailBusy = true;
      _errorMessage = null;
      _emailNotice = null;
    });

    if (_registerMode) {
      final r = await AuthService.registerWithEmail(email: email, password: pass);
      if (!mounted) return;
      if (!r.success) {
        setState(() { _emailBusy = false; _errorMessage = r.error; });
        return;
      }
      if (r.requiresVerification) {
        setState(() {
          _emailBusy = false;
          _registerMode = false;
          _emailNotice =
              'Письмо с подтверждением отправлено на $email. Подтвердите адрес и войдите.';
        });
        return;
      }
      // Verification not required — fall through to login with the same creds.
    }

    final err = await AuthService.loginWithEmail(email: email, password: pass);
    if (!mounted) return;
    if (err == null) {
      _showSuccess();
      return;
    }
    setState(() {
      _emailBusy = false;
      _errorMessage = err == 'email_unverified'
          ? 'Email не подтверждён — проверьте почту и перейдите по ссылке из письма.'
          : err;
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DS.surface2,
        borderRadius: BorderRadius.vertical(top: Radius.circular(DS.radius)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: _step == _Step.success
            ? _buildSuccess()
            : _emailMode
                ? _buildEmailForm()
                : _buildMain(),
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
                  color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w600)),
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
              waiting ? PhosphorIconsDuotone.paperPlaneTilt : PhosphorIconsDuotone.lock,
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
                color: DS.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
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

  String _providerName() =>
      _provider == _Provider.google ? 'Google' : 'Telegram';

  String _bodyText() {
    switch (_step) {
      case _Step.idle:
        return 'Для подключения к VPN-серверам необходима активная подписка. '
            'Войдите одним касанием.';
      case _Step.opening:
        return 'Открываем ${_providerName()}…';
      case _Step.waiting:
        return _provider == _Provider.google
            ? 'Завершите вход в браузере — '
                'авторизация продолжится автоматически.'
            : 'Telegram открыт. Нажмите «Старт» в боте — '
                'авторизация завершится автоматически.';
      case _Step.success:  return '';
      case _Step.error:    return _errorMessage ?? 'Произошла ошибка. Попробуйте снова.';
    }
  }

  // ── Email form ─────────────────────────────────────────────────────────────

  Widget _buildEmailForm() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Container(width: 40, height: 4,
            decoration: BoxDecoration(color: DS.border, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 20),
        Row(children: [
          IconButton(
            onPressed: _closeEmailMode,
            icon: const Icon(PhosphorIconsBold.caretLeft,
                size: 18, color: DS.textSecondary),
          ),
          Expanded(
            child: Text(
              _registerMode ? 'Регистрация' : 'Вход по email',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: DS.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          // Symmetry filler matching the back button's footprint.
          const SizedBox(width: 48),
        ]),
        const SizedBox(height: 16),
        TextField(
          controller: _emailCtrl,
          enabled: !_emailBusy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          style: const TextStyle(color: DS.textPrimary, fontSize: 15),
          decoration: const InputDecoration(
            hintText: 'email@example.com',
            prefixIcon: Icon(PhosphorIconsRegular.envelopeSimple,
                size: 18, color: DS.textMuted),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passCtrl,
          enabled: !_emailBusy,
          obscureText: _obscurePass,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitEmail(),
          style: const TextStyle(color: DS.textPrimary, fontSize: 15),
          decoration: InputDecoration(
            hintText: 'Пароль',
            prefixIcon: const Icon(PhosphorIconsRegular.lockSimple,
                size: 18, color: DS.textMuted),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
              icon: Icon(
                _obscurePass
                    ? PhosphorIconsRegular.eye
                    : PhosphorIconsRegular.eyeSlash,
                size: 18, color: DS.textMuted,
              ),
            ),
          ),
        ),
        if (_emailNotice != null) ...[
          const SizedBox(height: 12),
          Text(_emailNotice!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: DS.emerald, fontSize: 13, height: 1.4)),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(_errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: DS.rose.withValues(alpha: 0.9), fontSize: 13, height: 1.4)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _emailBusy ? null : _submitEmail,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DS.radius)),
            ),
            child: _emailBusy
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_registerMode ? 'Создать аккаунт' : 'Войти',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _emailBusy
              ? null
              : () => setState(() {
                    _registerMode = !_registerMode;
                    _errorMessage = null;
                    _emailNotice = null;
                  }),
          child: Text(
            _registerMode
                ? 'Уже есть аккаунт? Войти'
                : 'Нет аккаунта? Зарегистрироваться',
            style: const TextStyle(color: DS.textSecondary, fontSize: 13),
          ),
        ),
      ]),
    );
  }

  Widget _buildAction() {
    switch (_step) {
      case _Step.idle:
      case _Step.error:
        return Column(children: [
          _TelegramButton(
            label: _step == _Step.error ? 'Попробовать снова' : 'Войти через Telegram',
            onTap: _onLoginTap,
          ),
          const SizedBox(height: 10),
          _GoogleButton(onTap: _onGoogleTap),
          const SizedBox(height: 10),
          _EmailButton(onTap: _openEmailMode),
        ]);
      case _Step.opening:
      case _Step.waiting:
        return _LoadingRow(
            label: _step == _Step.opening
                ? 'Открываем ${_providerName()}…'
                : 'Ожидаем подтверждения…');
      case _Step.success:
        return const SizedBox.shrink();
    }
  }
}

// Google sign-in CTA — neutral surface with the standard "G" coloured pip so
// it reads as a secondary login method next to the brand-coloured Telegram CTA.
class _GoogleButton extends StatelessWidget {
  final VoidCallback onTap;
  const _GoogleButton({required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: DS.surface1,
              borderRadius: BorderRadius.circular(DS.radius),
              border: Border.all(color: DS.border),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(PhosphorIconsDuotone.googleLogo,
                  color: const Color(0xFFEA4335), size: 20),
              const SizedBox(width: 10),
              const Text('Войти через Google',
                  style: TextStyle(
                      color: DS.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

// Email sign-in CTA — same neutral surface treatment as the Google button so
// the three options read as one coherent stack.
class _EmailButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EmailButton({required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: DS.surface1,
              borderRadius: BorderRadius.circular(DS.radius),
              border: Border.all(color: DS.border),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(PhosphorIconsDuotone.envelopeSimple,
                  color: DS.violet, size: 20),
              const SizedBox(width: 10),
              const Text('Войти по email',
                  style: TextStyle(
                      color: DS.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
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
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: DS.telegramBlue,
          borderRadius: BorderRadius.circular(DS.radius),
          boxShadow: [BoxShadow(
              color: DS.telegramBlue.withValues(alpha: 0.35),
              blurRadius: 18, offset: const Offset(0, 5))],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(PhosphorIconsDuotone.paperPlaneTilt, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
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
