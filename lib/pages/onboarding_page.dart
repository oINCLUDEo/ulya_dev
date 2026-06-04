import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show DS, MainShell;
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/me_service.dart';
import '../services/remnawave_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/notification_banner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Persistence helpers (also used by main.dart and settings_page.dart)
// ─────────────────────────────────────────────────────────────────────────────

const _kOnboardingShownKey = 'onboarding_shown_v1';

Future<bool> shouldShowOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return !(prefs.getBool(_kOnboardingShownKey) ?? false);
}

Future<void> markOnboardingShown() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingShownKey, true);
}

/// Call from Settings to let the tester see the onboarding again.
Future<void> resetOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kOnboardingShownKey);
}

// ─────────────────────────────────────────────────────────────────────────────
// Slide data
// ─────────────────────────────────────────────────────────────────────────────

class _SlideData {
  const _SlideData({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });
  final IconData icon;
  final String title;
  final String body;
  final Color color;
}

const _kSlides = <_SlideData>[
  _SlideData(
    icon: Icons.shield_rounded,
    title: 'Безопасное соединение',
    body: 'Надёжное шифрование защищает ваши данные в любых сетях — дома и в путешествиях.',
    color: DS.violet,
  ),
  _SlideData(
    icon: Icons.bolt_rounded,
    title: 'Высокая скорость',
    body: 'Серверы по всему миру обеспечивают стабильное и быстрое соединение.',
    color: DS.cyan,
  ),
  _SlideData(
    icon: Icons.tune_rounded,
    title: 'Просто управлять',
    body: 'Одно касание — и вы под защитой. Подключайтесь и отключайтесь мгновенно.',
    color: DS.emerald,
  ),
];

// feature slides + 1 auth slide
const _kTotalPages = 4;

// ─────────────────────────────────────────────────────────────────────────────
// Auth step state machine
// ─────────────────────────────────────────────────────────────────────────────

enum _AuthStep {
  idle,          // show Telegram + Email buttons
  emailForm,     // email/password form
  openingTg,     // opening Telegram app
  waiting,       // polling Telegram bot
  emailBusy,     // logging in or registering via email
  emailVerify,   // registered, waiting for email verification
  trialOffer,    // auth succeeded, offer free trial
  claimingTrial, // claiming trial
  done,          // all done, navigating
  error,         // auth error
}

enum _EmailMode { login, register }

// ─────────────────────────────────────────────────────────────────────────────
// OnboardingPage
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pageCtrl = PageController();
  int _currentPage = 0;

  // ── Auth state ──────────────────────────────────────────────────────────────
  _AuthStep _authStep = _AuthStep.idle;
  String? _authError;
  StreamSubscription<AuthResult>? _pollSub;

  // ── Email form state ────────────────────────────────────────────────────────
  _EmailMode _emailMode = _EmailMode.login;
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _passwordVisible = false;

  // ── Trial state ─────────────────────────────────────────────────────────────
  String? _trialMessage;
  bool _trialClaimed = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    _pollSub?.cancel();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── Navigation ──────────────────────────────────────────────────────────────

  void _nextPage() {
    if (_currentPage < _kTotalPages - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  Future<void> _finishOnboarding() async {
    await markOnboardingShown();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const InAppNotificationOverlay(child: MainShell()),
      ),
      (_) => false,
    );
  }

  // ── Telegram auth ───────────────────────────────────────────────────────────

  Future<void> _onTelegramTap() async {
    if (_authStep != _AuthStep.idle && _authStep != _AuthStep.error) return;
    setState(() { _authStep = _AuthStep.openingTg; _authError = null; });

    final token = await AuthService.startLogin(onError: (msg) {
      if (mounted) setState(() { _authStep = _AuthStep.error; _authError = msg; });
    });

    if (token == null || !mounted) return;
    setState(() => _authStep = _AuthStep.waiting);
    _startPolling(token);
  }

  void _startPolling(String token) {
    _pollSub?.cancel();
    _pollSub = AuthService.pollStatus(token).listen(
      (result) {
        if (!mounted) { _pollSub?.cancel(); return; }
        if (result.success) {
          _pollSub?.cancel();
          _onAuthSuccess();
        } else if (result.error != null) {
          _pollSub?.cancel();
          setState(() { _authStep = _AuthStep.error; _authError = result.error; });
        }
      },
      onError: (_) {
        if (mounted) {
          setState(() {
            _authStep = _AuthStep.error;
            _authError = 'Ошибка соединения. Попробуйте снова.';
          });
        }
      },
    );
  }

  void _cancelPolling() {
    _pollSub?.cancel();
    setState(() { _authStep = _AuthStep.idle; _authError = null; });
  }

  // ── Email auth ──────────────────────────────────────────────────────────────

  void _showEmailForm() {
    setState(() {
      _authStep = _AuthStep.emailForm;
      _authError = null;
      _emailMode = _EmailMode.login;
      _emailCtrl.clear();
      _passwordCtrl.clear();
      _nameCtrl.clear();
    });
  }

  Future<void> _onEmailSubmit() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _authError = 'Введите email и пароль.');
      return;
    }

    setState(() { _authStep = _AuthStep.emailBusy; _authError = null; });

    if (_emailMode == _EmailMode.register) {
      final result = await AuthService.registerWithEmail(
        email: email,
        password: password,
        firstName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text.trim(),
      );
      if (!mounted) return;

      if (!result.success) {
        setState(() { _authStep = _AuthStep.emailForm; _authError = result.error; });
        return;
      }

      if (result.requiresVerification) {
        // Show "check your email" screen
        setState(() => _authStep = _AuthStep.emailVerify);
      } else {
        // Auto-verified → login immediately
        final loginError = await AuthService.loginWithEmail(email: email, password: password);
        if (!mounted) return;
        if (loginError != null) {
          setState(() { _authStep = _AuthStep.emailForm; _authError = loginError; });
        } else {
          _onAuthSuccess();
        }
      }
    } else {
      // Login
      final error = await AuthService.loginWithEmail(email: email, password: password);
      if (!mounted) return;
      if (error == 'email_unverified') {
        setState(() {
          _authStep = _AuthStep.error;
          _authError = 'Email не подтверждён. Проверьте почту и перейдите по ссылке.';
        });
      } else if (error != null) {
        setState(() { _authStep = _AuthStep.emailForm; _authError = error; });
      } else {
        _onAuthSuccess();
      }
    }
  }

  // ── Shared post-auth logic ──────────────────────────────────────────────────

  Future<void> _onAuthSuccess() async {
    if (!mounted) return;

    final state = authStateNotifier.value;

    bool hasSub;
    if (state.isEmailAuth) {
      // For email users, subscription info comes from auth state
      // (fetched from /cabinet/subscription during login)
      hasSub = state.hasSubscription;
    } else {
      // For Telegram users, refresh /me and check live data
      await MeService.refresh();
      if (!mounted) return;
      final me = meNotifier.value;
      hasSub = me?.subscription?.planName?.isNotEmpty ?? false;
    }

    if (!hasSub) {
      setState(() => _authStep = _AuthStep.trialOffer);
    } else {
      setState(() => _authStep = _AuthStep.done);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      _finishOnboarding();
    }
  }

  // ── Trial ───────────────────────────────────────────────────────────────────

  Future<void> _claimTrial() async {
    setState(() => _authStep = _AuthStep.claimingTrial);

    final state = authStateNotifier.value;
    BuyResult? result;

    if (state.isEmailAuth && state.cabinetAccessToken != null) {
      // Email user → use Cabinet API (Bearer JWT)
      result = await SubscriptionApiService.activateCabinetTrial(
        state.cabinetAccessToken!,
      );
      // If trial succeeded, persist the new subscription URL from response
      if (result != null && result.isSuccess) {
        final subUrl = result.subscription?['subscription_url'] as String?;
        if (subUrl != null && subUrl.isNotEmpty) {
          final updated = state.copyWith(subscriptionUrl: subUrl);
          await saveAuthState(updated);
          authStateNotifier.value = updated;
          await RemnawaveService.saveSubscriptionUrl(subUrl);
        }
      }
    } else {
      // Telegram user → use Mobile API (X-Telegram-Id)
      result = await SubscriptionApiService.activateTrial();
      if (result != null && result.isSuccess) {
        MeService.refresh();
      }
    }

    if (!mounted) return;

    if (result != null && result.isSuccess) {
      setState(() {
        _trialClaimed = true;
        _trialMessage = result!.message ?? 'Пробная подписка активирована!';
        _authStep = _AuthStep.done;
      });
    } else {
      setState(() {
        _trialMessage = result?.message;
        _authStep = _AuthStep.done;
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    _finishOnboarding();
  }

  void _skipTrial() => _finishOnboarding();

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isAuthSlide = _currentPage == _kTotalPages - 1;

    return Scaffold(
      backgroundColor: DS.surface0,
      body: Stack(
        children: [
          PageView(
            controller: _pageCtrl,
            // Prevent swipe on auth slide to avoid accidental back gesture
            physics: isAuthSlide
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: [
              ..._kSlides.map((s) => _FeatureSlide(slide: s)),
              _AuthSlide(
                step: _authStep,
                emailMode: _emailMode,
                errorMessage: _authError,
                trialMessage: _trialMessage,
                trialClaimed: _trialClaimed,
                emailCtrl: _emailCtrl,
                passwordCtrl: _passwordCtrl,
                nameCtrl: _nameCtrl,
                passwordVisible: _passwordVisible,
                onPasswordToggle: () => setState(() => _passwordVisible = !_passwordVisible),
                onTelegramTap: _onTelegramTap,
                onEmailButtonTap: _showEmailForm,
                onEmailModeSwitch: (m) => setState(() { _emailMode = m; _authError = null; }),
                onEmailSubmit: _onEmailSubmit,
                onCancelPolling: _cancelPolling,
                onBackFromEmail: () => setState(() { _authStep = _AuthStep.idle; _authError = null; }),
                onClaimTrial: _claimTrial,
                onSkipTrial: _skipTrial,
              ),
            ],
          ),
          // Page dots + Next button (hidden on auth slide)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _BottomBar(
              currentPage: _currentPage,
              totalPages: _kTotalPages,
              onNext: isAuthSlide ? null : _nextPage,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature slide
// ─────────────────────────────────────────────────────────────────────────────

class _FeatureSlide extends StatelessWidget {
  const _FeatureSlide({required this.slide});
  final _SlideData slide;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 60, 32, 160),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: slide.color.withValues(alpha: 0.1),
                border: Border.all(color: slide.color.withValues(alpha: 0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: slide.color.withValues(alpha: 0.22),
                    blurRadius: 48,
                  ),
                ],
              ),
              child: Icon(slide.icon, size: 56, color: slide.color),
            ),
            const SizedBox(height: 48),
            Text(
              slide.title,
              style: const TextStyle(
                color: DS.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              slide.body,
              style: const TextStyle(
                color: DS.textSecondary,
                fontSize: 16,
                height: 1.65,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth slide
// ─────────────────────────────────────────────────────────────────────────────

class _AuthSlide extends StatelessWidget {
  const _AuthSlide({
    required this.step,
    required this.emailMode,
    required this.errorMessage,
    required this.trialMessage,
    required this.trialClaimed,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.nameCtrl,
    required this.passwordVisible,
    required this.onPasswordToggle,
    required this.onTelegramTap,
    required this.onEmailButtonTap,
    required this.onEmailModeSwitch,
    required this.onEmailSubmit,
    required this.onCancelPolling,
    required this.onBackFromEmail,
    required this.onClaimTrial,
    required this.onSkipTrial,
  });

  final _AuthStep step;
  final _EmailMode emailMode;
  final String? errorMessage;
  final String? trialMessage;
  final bool trialClaimed;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final TextEditingController nameCtrl;
  final bool passwordVisible;
  final VoidCallback onPasswordToggle;
  final VoidCallback onTelegramTap;
  final VoidCallback onEmailButtonTap;
  final ValueChanged<_EmailMode> onEmailModeSwitch;
  final VoidCallback onEmailSubmit;
  final VoidCallback onCancelPolling;
  final VoidCallback onBackFromEmail;
  final VoidCallback onClaimTrial;
  final VoidCallback onSkipTrial;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom + 160,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: _buildContent(context),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (step) {
      case _AuthStep.emailForm:
        return _buildEmailForm(context);
      case _AuthStep.emailVerify:
        return _buildEmailVerifyPending();
      case _AuthStep.trialOffer:
        return _buildTrialOffer();
      case _AuthStep.claimingTrial:
        return _buildClaimingTrial();
      case _AuthStep.done:
        return _buildDone();
      default:
        return _buildAuthButtons();
    }
  }

  // ── Main auth buttons (Telegram + Email) ────────────────────────────────────

  Widget _buildAuthButtons() {
    final isWaiting = step == _AuthStep.waiting || step == _AuthStep.openingTg;
    final isError = step == _AuthStep.error;

    return Column(
      key: const ValueKey('auth-buttons'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Icon
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DS.violet.withValues(alpha: 0.1),
            border: Border.all(color: DS.violet.withValues(alpha: 0.25), width: 1.5),
            boxShadow: [BoxShadow(color: DS.violet.withValues(alpha: 0.15), blurRadius: 40)],
          ),
          child: const Icon(Icons.person_rounded, size: 48, color: DS.violet),
        ),
        const SizedBox(height: 32),
        const Text(
          'Войдите, чтобы начать',
          style: TextStyle(color: DS.textPrimary, fontSize: 24, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            key: ValueKey(step),
            isError
                ? (errorMessage ?? 'Произошла ошибка. Попробуйте снова.')
                : isWaiting
                    ? (step == _AuthStep.openingTg
                        ? 'Открываем Telegram…'
                        : 'Ожидаем подтверждения…\nНажмите «Старт» в боте.')
                    : 'Выберите способ входа для доступа к подписке.',
            style: TextStyle(
              color: isError ? DS.rose.withValues(alpha: 0.9) : DS.textSecondary,
              fontSize: 15,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 36),
        if (isWaiting)
          _WaitingIndicator(label: step == _AuthStep.openingTg
              ? 'Открываем Telegram…'
              : 'Ожидаем подтверждения…')
        else ...[
          _AuthButton(
            icon: Icons.telegram,
            label: 'Войти через Telegram',
            color: DS.telegramBlue,
            onTap: onTelegramTap,
          ),
          const SizedBox(height: 12),
          _AuthButton(
            icon: Icons.email_rounded,
            label: 'Войти по Email',
            color: DS.violet,
            onTap: onEmailButtonTap,
          ),
        ],
        if (isWaiting) ...[
          const SizedBox(height: 16),
          TextButton(
            onPressed: onCancelPolling,
            child: const Text('Отмена', style: TextStyle(color: DS.textMuted, fontSize: 13)),
          ),
        ],
      ],
    );
  }

  // ── Email form ──────────────────────────────────────────────────────────────

  Widget _buildEmailForm(BuildContext context) {
    final isRegister = emailMode == _EmailMode.register;
    final isBusy = step == _AuthStep.emailBusy;

    return Column(
      key: const ValueKey('email-form'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back + title row
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: DS.textSecondary),
              padding: EdgeInsets.zero,
              onPressed: onBackFromEmail,
            ),
            const SizedBox(width: 8),
            Text(
              isRegister ? 'Регистрация' : 'Вход по Email',
              style: const TextStyle(
                color: DS.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Mode toggle
        _ModeToggle(
          mode: emailMode,
          onChanged: onEmailModeSwitch,
        ),
        const SizedBox(height: 20),

        // Name field (register only)
        if (isRegister) ...[
          _Field(
            controller: nameCtrl,
            label: 'Имя (необязательно)',
            icon: Icons.person_outline_rounded,
            keyboardType: TextInputType.name,
          ),
          const SizedBox(height: 12),
        ],

        // Email field
        _Field(
          controller: emailCtrl,
          label: 'Email',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),

        // Password field
        _PasswordField(
          controller: passwordCtrl,
          label: isRegister ? 'Пароль (мин. 8 символов)' : 'Пароль',
          visible: passwordVisible,
          onToggle: onPasswordToggle,
        ),
        const SizedBox(height: 8),

        // Error
        if (errorMessage != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: DS.rose.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(DS.radiusSm),
              border: Border.all(color: DS.rose.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded, color: DS.rose, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                errorMessage!,
                style: const TextStyle(color: DS.rose, fontSize: 13),
              )),
            ]),
          ),
          const SizedBox(height: 8),
        ],

        const SizedBox(height: 12),

        // Submit button
        SizedBox(
          width: double.infinity,
          child: isBusy
              ? const Center(child: _WaitingIndicator(label: 'Подождите…'))
              : FilledButton(
                  onPressed: onEmailSubmit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: DS.violet,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DS.radius)),
                  ),
                  child: Text(
                    isRegister ? 'Зарегистрироваться' : 'Войти',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
        ),
      ],
    );
  }

  // ── Email verify pending ────────────────────────────────────────────────────

  Widget _buildEmailVerifyPending() {
    return Column(
      key: const ValueKey('email-verify'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DS.telegramBlue.withValues(alpha: 0.1),
            border: Border.all(color: DS.telegramBlue.withValues(alpha: 0.3), width: 1.5),
            boxShadow: [BoxShadow(color: DS.telegramBlue.withValues(alpha: 0.15), blurRadius: 40)],
          ),
          child: const Icon(Icons.mark_email_read_rounded, size: 48, color: DS.telegramBlue),
        ),
        const SizedBox(height: 32),
        const Text(
          'Подтвердите email',
          style: TextStyle(color: DS.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Мы отправили письмо с ссылкой подтверждения.\nОткройте его и нажмите на ссылку,\nзатем вернитесь и войдите.',
          style: TextStyle(color: DS.textSecondary, fontSize: 15, height: 1.55),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 36),
        _AuthButton(
          icon: Icons.login_rounded,
          label: 'Уже подтвердил — Войти',
          color: DS.violet,
          onTap: () {}, // Will be handled by parent via onBackFromEmail then re-login
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: onBackFromEmail,
          child: const Text(
            '← Назад',
            style: TextStyle(color: DS.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }

  // ── Trial offer ─────────────────────────────────────────────────────────────

  Widget _buildTrialOffer() {
    return Column(
      key: const ValueKey('trial'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DS.gold.withValues(alpha: 0.1),
            border: Border.all(color: DS.gold.withValues(alpha: 0.3), width: 1.5),
            boxShadow: [BoxShadow(color: DS.gold.withValues(alpha: 0.18), blurRadius: 40)],
          ),
          child: const Icon(Icons.card_giftcard_rounded, size: 48, color: DS.gold),
        ),
        const SizedBox(height: 32),
        const Text(
          'Пробная подписка',
          style: TextStyle(color: DS.textPrimary, fontSize: 24, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Вы успешно вошли! Активируйте бесплатный пробный период прямо сейчас.',
          style: TextStyle(color: DS.textSecondary, fontSize: 15, height: 1.55),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 36),
        _AuthButton(
          icon: Icons.check_circle_outline_rounded,
          label: 'Получить бесплатно',
          color: DS.gold,
          onTap: onClaimTrial,
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: onSkipTrial,
          child: const Text('Пропустить', style: TextStyle(color: DS.textMuted, fontSize: 14)),
        ),
      ],
    );
  }

  Widget _buildClaimingTrial() {
    return Column(
      key: const ValueKey('claiming'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        SizedBox(
          width: 48, height: 48,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: DS.gold),
        ),
        SizedBox(height: 24),
        Text('Активируем подписку…',
            style: TextStyle(color: DS.textSecondary, fontSize: 16)),
      ],
    );
  }

  Widget _buildDone() {
    return Column(
      key: const ValueKey('done'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DS.emerald.withValues(alpha: 0.1),
            border: Border.all(color: DS.emerald.withValues(alpha: 0.3), width: 1.5),
            boxShadow: [BoxShadow(color: DS.emerald.withValues(alpha: 0.15), blurRadius: 40)],
          ),
          child: const Icon(Icons.check_rounded, size: 52, color: DS.emerald),
        ),
        const SizedBox(height: 28),
        Text(
          trialClaimed ? 'Подписка активирована!' : 'Добро пожаловать!',
          style: const TextStyle(
              color: DS.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        if (trialMessage != null) ...[
          const SizedBox(height: 12),
          Text(trialMessage!,
              style: const TextStyle(color: DS.textSecondary, fontSize: 14, height: 1.5),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

class _AuthButton extends StatelessWidget {
  const _AuthButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(DS.radius),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
      ),
    ),
  );
}

class _WaitingIndicator extends StatelessWidget {
  const _WaitingIndicator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const SizedBox(width: 22, height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: DS.violet)),
      const SizedBox(width: 14),
      Text(label, style: const TextStyle(color: DS.textSecondary, fontSize: 14)),
    ],
  );
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});
  final _EmailMode mode;
  final ValueChanged<_EmailMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: DS.surface2,
        borderRadius: BorderRadius.circular(DS.radiusSm),
        border: Border.all(color: DS.border),
      ),
      child: Row(children: [
        _toggleItem(
          label: 'Вход',
          selected: mode == _EmailMode.login,
          onTap: () => onChanged(_EmailMode.login),
        ),
        _toggleItem(
          label: 'Регистрация',
          selected: mode == _EmailMode.register,
          onTap: () => onChanged(_EmailMode.register),
        ),
      ]),
    );
  }

  Widget _toggleItem({required String label, required bool selected, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: selected ? DS.violet : Colors.transparent,
            borderRadius: BorderRadius.circular(DS.radiusSm - 2),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : DS.textMuted,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
  });
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    autocorrect: false,
    style: const TextStyle(color: DS.textPrimary, fontSize: 15),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: DS.textMuted, fontSize: 14),
      prefixIcon: Icon(icon, color: DS.textMuted, size: 20),
      filled: true,
      fillColor: DS.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.violet, width: 1.5),
      ),
    ),
  );
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.visible,
    required this.onToggle,
  });
  final TextEditingController controller;
  final String label;
  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    obscureText: !visible,
    style: const TextStyle(color: DS.textPrimary, fontSize: 15),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: DS.textMuted, fontSize: 14),
      prefixIcon: const Icon(Icons.lock_outline_rounded, color: DS.textMuted, size: 20),
      suffixIcon: IconButton(
        icon: Icon(
          visible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          color: DS.textMuted, size: 20,
        ),
        onPressed: onToggle,
      ),
      filled: true,
      fillColor: DS.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(DS.radiusSm),
        borderSide: const BorderSide(color: DS.violet, width: 1.5),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom bar — page dots + Next button
// ─────────────────────────────────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.currentPage,
    required this.totalPages,
    this.onNext,
  });
  final int currentPage;
  final int totalPages;
  // null = last page (auth slide), hide Next button
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final isLastPage = currentPage == totalPages - 1;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, 20 + safeBottom),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            DS.surface0,
            DS.surface0.withValues(alpha: 0.95),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Page indicator dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(totalPages, (i) {
              final active = i == currentPage;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: active ? 24.0 : 8.0,
                height: 8.0,
                decoration: BoxDecoration(
                  color: active ? DS.violet : DS.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
          if (!isLastPage) ...[
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onNext,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: DS.violet,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DS.radius)),
                ),
                child: const Text('Далее',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
