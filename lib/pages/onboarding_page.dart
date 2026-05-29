import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show DS, MainShell;
import '../services/auth_service.dart';
import '../services/me_service.dart';
import '../services/subscription_api_service.dart';
import '../widgets/notification_banner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Persistence helpers (used by main.dart)
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
// Auth step
// ─────────────────────────────────────────────────────────────────────────────

enum _AuthStep {
  idle,
  openingTg,
  openingGoogle,
  waiting,
  trialOffer,
  claimingTrial,
  done,
  error,
}

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

  // Auth state
  _AuthStep _authStep = _AuthStep.idle;
  String? _authError;
  StreamSubscription<AuthResult>? _pollSub;

  // Trial state
  String? _trialMessage;
  bool _trialClaimed = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    _pollSub?.cancel();
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

  // ── Auth ────────────────────────────────────────────────────────────────────

  Future<void> _onTelegramTap() async {
    if (_authStep != _AuthStep.idle && _authStep != _AuthStep.error) return;
    setState(() {
      _authStep = _AuthStep.openingTg;
      _authError = null;
    });

    final token = await AuthService.startLogin(onError: (msg) {
      if (mounted) setState(() { _authStep = _AuthStep.error; _authError = msg; });
    });

    if (token == null || !mounted) return;
    setState(() => _authStep = _AuthStep.waiting);
    _startPolling(token);
  }

  Future<void> _onGoogleTap() async {
    if (_authStep != _AuthStep.idle && _authStep != _AuthStep.error) return;
    setState(() {
      _authStep = _AuthStep.openingGoogle;
      _authError = null;
    });

    final token = await AuthService.startGoogleLogin(onError: (msg) {
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

  Future<void> _onAuthSuccess() async {
    if (!mounted) return;
    // Give meNotifier a moment to refresh if needed
    await MeService.refresh();
    if (!mounted) return;

    final me = meNotifier.value;
    final hasSub = me?.subscription?.planName?.isNotEmpty ?? false;

    if (!hasSub) {
      // Offer free trial
      setState(() => _authStep = _AuthStep.trialOffer);
    } else {
      setState(() => _authStep = _AuthStep.done);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      _finishOnboarding();
    }
  }

  Future<void> _claimTrial() async {
    setState(() => _authStep = _AuthStep.claimingTrial);
    final result = await SubscriptionApiService.activateTrial();
    if (!mounted) return;

    if (result != null && result.status == 'success') {
      setState(() {
        _trialClaimed = true;
        _trialMessage = result.message ?? 'Пробная подписка активирована!';
        _authStep = _AuthStep.done;
      });
      MeService.refresh();
    } else {
      setState(() {
        _trialMessage = result?.message ?? 'Не удалось активировать пробный период.';
        _authStep = _AuthStep.done;
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 1400));
    _finishOnboarding();
  }

  void _skipTrial() => _finishOnboarding();

  void _cancelPolling() {
    _pollSub?.cancel();
    setState(() { _authStep = _AuthStep.idle; _authError = null; });
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isAuthSlide = _currentPage == _kTotalPages - 1;

    return Scaffold(
      backgroundColor: DS.surface0,
      body: Stack(
        children: [
          PageView(
            controller: _pageCtrl,
            // Disable swipe on auth slide to prevent accidental back-swipe
            physics: isAuthSlide
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: [
              ..._kSlides.map((s) => _FeatureSlide(slide: s)),
              _AuthSlide(
                step: _authStep,
                errorMessage: _authError,
                trialMessage: _trialMessage,
                trialClaimed: _trialClaimed,
                onTelegramTap: _onTelegramTap,
                onGoogleTap: _onGoogleTap,
                onCancelPolling: _cancelPolling,
                onClaimTrial: _claimTrial,
                onSkipTrial: _skipTrial,
              ),
            ],
          ),
          // Dots + Next button overlay (hidden on auth slide)
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
            // Glowing icon circle
            Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: slide.color.withValues(alpha: 0.1),
                border: Border.all(
                  color: slide.color.withValues(alpha: 0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: slide.color.withValues(alpha: 0.22),
                    blurRadius: 48,
                    spreadRadius: 0,
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
    required this.errorMessage,
    required this.trialMessage,
    required this.trialClaimed,
    required this.onTelegramTap,
    required this.onGoogleTap,
    required this.onCancelPolling,
    required this.onClaimTrial,
    required this.onSkipTrial,
  });

  final _AuthStep step;
  final String? errorMessage;
  final String? trialMessage;
  final bool trialClaimed;
  final VoidCallback onTelegramTap;
  final VoidCallback onGoogleTap;
  final VoidCallback onCancelPolling;
  final VoidCallback onClaimTrial;
  final VoidCallback onSkipTrial;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 160),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (step) {
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

  Widget _buildAuthButtons() {
    final isWaiting = step == _AuthStep.waiting ||
        step == _AuthStep.openingTg ||
        step == _AuthStep.openingGoogle;
    final isError = step == _AuthStep.error;

    return Column(
      key: const ValueKey('auth'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Icon
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DS.violet.withValues(alpha: 0.1),
            border: Border.all(color: DS.violet.withValues(alpha: 0.25), width: 1.5),
            boxShadow: [
              BoxShadow(color: DS.violet.withValues(alpha: 0.15), blurRadius: 40),
            ],
          ),
          child: const Icon(Icons.person_rounded, size: 48, color: DS.violet),
        ),
        const SizedBox(height: 32),
        const Text(
          'Войдите, чтобы начать',
          style: TextStyle(
            color: DS.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Text(
            key: ValueKey(step),
            isError
                ? (errorMessage ?? 'Произошла ошибка. Попробуйте снова.')
                : isWaiting
                    ? _waitingText()
                    : 'Войдите через Telegram или Google для доступа к подписке.',
            style: TextStyle(
              color: isError
                  ? DS.rose.withValues(alpha: 0.9)
                  : DS.textSecondary,
              fontSize: 15,
              height: 1.55,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 36),
        if (isWaiting)
          _buildWaitingIndicator()
        else ...[
          _AuthButton(
            icon: Icons.telegram,
            label: 'Войти через Telegram',
            color: DS.telegramBlue,
            onTap: onTelegramTap,
          ),
          const SizedBox(height: 12),
          _AuthButton(
            icon: Icons.g_mobiledata_rounded,
            label: 'Войти через Google',
            color: DS.violet,
            onTap: onGoogleTap,
          ),
        ],
        if (isWaiting) ...[
          const SizedBox(height: 16),
          TextButton(
            onPressed: onCancelPolling,
            child: const Text(
              'Отмена',
              style: TextStyle(color: DS.textMuted, fontSize: 13),
            ),
          ),
        ],
      ],
    );
  }

  String _waitingText() {
    switch (step) {
      case _AuthStep.openingTg:    return 'Открываем Telegram…';
      case _AuthStep.openingGoogle: return 'Открываем браузер…';
      case _AuthStep.waiting:
        return 'Ожидаем подтверждения…\nНажмите «Старт» в боте или завершите вход в браузере.';
      default: return '';
    }
  }

  Widget _buildWaitingIndicator() {
    final color = step == _AuthStep.openingGoogle ? DS.violet : DS.telegramBlue;
    final label = step == _AuthStep.openingTg
        ? 'Открываем Telegram…'
        : step == _AuthStep.openingGoogle
            ? 'Открываем браузер…'
            : 'Ожидаем подтверждения…';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        const SizedBox(width: 14),
        Text(label, style: const TextStyle(color: DS.textSecondary, fontSize: 14)),
      ],
    );
  }

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
            boxShadow: [
              BoxShadow(color: DS.gold.withValues(alpha: 0.18), blurRadius: 40),
            ],
          ),
          child: const Icon(Icons.card_giftcard_rounded, size: 48, color: DS.gold),
        ),
        const SizedBox(height: 32),
        const Text(
          'Пробная подписка',
          style: TextStyle(
            color: DS.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Вы успешно вошли! Активируйте бесплатный пробный период прямо сейчас.',
          style: TextStyle(
            color: DS.textSecondary,
            fontSize: 15,
            height: 1.55,
          ),
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
          child: const Text(
            'Пропустить',
            style: TextStyle(color: DS.textMuted, fontSize: 14),
          ),
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
        Text(
          'Активируем подписку…',
          style: TextStyle(color: DS.textSecondary, fontSize: 16),
        ),
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
            border: Border.all(
              color: DS.emerald.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(color: DS.emerald.withValues(alpha: 0.15), blurRadius: 40),
            ],
          ),
          child: const Icon(Icons.check_rounded, size: 52, color: DS.emerald),
        ),
        const SizedBox(height: 28),
        Text(
          trialClaimed ? 'Подписка активирована!' : 'Добро пожаловать!',
          style: const TextStyle(
            color: DS.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        if (trialMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            trialMessage!,
            style: const TextStyle(color: DS.textSecondary, fontSize: 14, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth button
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
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

    return IgnorePointer(
      ignoring: false,
      child: Container(
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
            // Next button (hidden on auth slide)
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
                      borderRadius: BorderRadius.circular(DS.radius),
                    ),
                  ),
                  child: const Text(
                    'Далее',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
