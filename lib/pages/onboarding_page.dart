import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show rootBundle;
import 'package:phosphor_flutter/phosphor_flutter.dart';
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
    required this.title,
    required this.body,
    required this.color,
  });
  final String title;
  final String body;
  final Color color;
}

const _kSlides = <_SlideData>[
  _SlideData(
    title: 'Ваш интернет — только ваш',
    body: 'Шифруем трафик, чтобы никто не видел, что вы открываете. Даже в публичном Wi-Fi в кафе или метро.',
    color: DS.violet,
  ),
  _SlideData(
    title: 'Открывается всё',
    body: 'Любимые сайты и сервисы снова работают — быстро и без тормозов, где бы вы ни были.',
    color: DS.cyan,
  ),
  _SlideData(
    title: 'Одна кнопка — и готово',
    body: 'Никаких сложных настроек. Нажали «Подключить» — и вы защищены за пару секунд.',
    color: DS.emerald,
  ),
];

// feature slides + 1 auth slide
const _kTotalPages = 4;

// Simplified continent outlines as [lon, lat] vertices (degrees), used by the
// onboarding globe. Rough silhouettes — enough to read as Earth, cheap to draw.
const _kContinents = <List<List<double>>>[
  // North America
  [[-158, 71], [-130, 70], [-95, 72], [-82, 62], [-64, 60], [-56, 50],
   [-66, 44], [-70, 41], [-81, 31], [-97, 26], [-107, 23], [-110, 30],
   [-117, 33], [-125, 40], [-124, 48], [-135, 58], [-150, 60], [-165, 64]],
  // South America
  [[-80, 8], [-72, 10], [-60, 5], [-50, 0], [-44, -3], [-35, -8], [-38, -15],
   [-48, -25], [-58, -35], [-66, -45], [-70, -52], [-74, -50], [-72, -38],
   [-70, -25], [-76, -15], [-81, -5]],
  // Africa
  [[-16, 15], [-5, 20], [10, 32], [24, 32], [33, 30], [43, 12], [51, 12],
   [42, 0], [40, -10], [33, -26], [25, -34], [18, -34], [12, -18], [8, 4],
   [-8, 5]],
  // Europe
  [[-9, 44], [-2, 49], [2, 51], [8, 54], [12, 55], [20, 55], [28, 58],
   [30, 52], [38, 48], [28, 41], [20, 40], [12, 44], [3, 43]],
  // Asia
  [[33, 48], [45, 55], [60, 60], [80, 68], [100, 72], [130, 73], [160, 68],
   [170, 66], [160, 60], [140, 52], [135, 45], [122, 40], [120, 30],
   [108, 22], [97, 16], [90, 22], [78, 8], [72, 20], [60, 25], [50, 40],
   [40, 45]],
  // Australia
  [[114, -22], [122, -18], [130, -12], [137, -12], [142, -13], [146, -18],
   [150, -25], [148, -38], [140, -38], [130, -32], [120, -34], [114, -30]],
];

// ─────────────────────────────────────────────────────────────────────────────
// Auth step state machine
// ─────────────────────────────────────────────────────────────────────────────

enum _AuthStep {
  idle,          // show Telegram + Email buttons
  emailForm,     // email/password form
  openingTg,     // opening external app/browser (Telegram or Google)
  waiting,       // polling Telegram bot OR finishing Google OAuth
  emailBusy,     // logging in or registering via email
  emailVerify,   // registered, waiting for email verification
  trialOffer,    // auth succeeded, offer free trial
  claimingTrial, // claiming trial
  done,          // all done, navigating
  error,         // auth error
}

/// Which login provider is currently in flight. Used by the waiting/opening
/// UI labels so we say "Открываем Telegram…" vs "Открываем Google…".
enum _AuthProvider { telegram, google }

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
  _AuthProvider _authProvider = _AuthProvider.telegram;
  String? _authError;
  StreamSubscription<AuthResult>? _pollSub;

  // ── Email form state ────────────────────────────────────────────────────────
  _EmailMode _emailMode = _EmailMode.login;
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _passwordVisible = false;

  // ── Referral code ───────────────────────────────────────────────────────────
  // Onboarding runs its own auth UI rather than the shared auth sheet, so the
  // field has to exist here too — and this is the flow that matters most, since
  // someone arriving with a friend's code is by definition a first-time user.
  bool _showReferralField = false;
  final _referralCtrl = TextEditingController();
  String? get _referralCode {
    final v = _referralCtrl.text.trim();
    return v.isEmpty ? null : v;
  }

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
    _referralCtrl.dispose();
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
    setState(() {
      _authStep = _AuthStep.openingTg;
      _authProvider = _AuthProvider.telegram;
      _authError = null;
    });

    // Primary: full Telegram OAuth via oauth.telegram.org (same as the cabinet).
    final res = await AuthService.signInWithTelegram(referralCode: _referralCode);
    if (!mounted) return;
    if (res == null) {
      _onAuthSuccess();
      return;
    }
    if (res == AuthService.telegramCancelled) {
      setState(() => _authStep = _AuthStep.idle);
      return;
    }
    // oauth.telegram.org unreachable/blocked or backend rejected → fall back
    // to the bot deep-link, which keeps working behind Telegram-OAuth blocks.
    await _startDeepLinkTelegram();
  }

  /// Resilience fallback: the original bot deep-link login. Used when the
  /// oauth.telegram.org OIDC path fails (commonly because the domain is
  /// blocked — exactly the situation a VPN user is in).
  Future<void> _startDeepLinkTelegram() async {
    if (!mounted) return;
    setState(() {
      _authStep = _AuthStep.openingTg;
      _authProvider = _AuthProvider.telegram;
      _authError = null;
    });

    final token = await AuthService.startLogin(onError: (msg) {
      if (mounted) setState(() { _authStep = _AuthStep.error; _authError = msg; });
    });

    if (token == null || !mounted) return;
    setState(() => _authStep = _AuthStep.waiting);
    _startPolling(token);
  }

  /// Google: full Cabinet OAuth flow. Synchronous from the UI's point of
  /// view — the in-app browser blocks until the redirect arrives and the
  /// call returns. On success the user is already authed; on cancel/error
  /// we surface the message.
  Future<void> _onGoogleTap() async {
    if (_authStep != _AuthStep.idle && _authStep != _AuthStep.error) return;
    setState(() {
      _authStep = _AuthStep.openingTg;
      _authProvider = _AuthProvider.google;
      _authError = null;
    });

    final err = await AuthService.signInWithGoogle(referralCode: _referralCode);
    if (!mounted) return;
    if (err != null) {
      setState(() { _authStep = _AuthStep.error; _authError = err; });
      return;
    }
    _onAuthSuccess();
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
        referralCode: _referralCode,
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
      result = await SubscriptionApiService.activateCabinetTrial();
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
      // Telegram user → use Mobile API (Bearer JWT)
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
          // Animated background — soft brand-colour blobs that morph and drift.
          // Sits behind every slide; ignores pointer events.
          const Positioned.fill(
            child: IgnorePointer(child: _MorphingBlobs()),
          ),
          PageView(
            controller: _pageCtrl,
            // Prevent swipe on auth slide to avoid accidental back gesture
            physics: isAuthSlide
                ? const NeverScrollableScrollPhysics()
                : const ClampingScrollPhysics(),
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: [
              ..._kSlides.asMap().entries.map((e) =>
                  _FeatureSlide(slide: e.value, index: e.key, controller: _pageCtrl)),
              _AuthSlide(
                step: _authStep,
                provider: _authProvider,
                emailMode: _emailMode,
                errorMessage: _authError,
                trialMessage: _trialMessage,
                trialClaimed: _trialClaimed,
                emailCtrl: _emailCtrl,
                passwordCtrl: _passwordCtrl,
                nameCtrl: _nameCtrl,
                referralCtrl: _referralCtrl,
                showReferralField: _showReferralField,
                onShowReferralField: () => setState(() => _showReferralField = true),
                onClearReferralField: () => setState(() {
                  _referralCtrl.clear();
                  _showReferralField = false;
                }),
                passwordVisible: _passwordVisible,
                onPasswordToggle: () => setState(() => _passwordVisible = !_passwordVisible),
                onTelegramTap: _onTelegramTap,
                onGoogleTap: _onGoogleTap,
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
  const _FeatureSlide({
    required this.slide,
    required this.index,
    required this.controller,
  });
  final _SlideData slide;
  final int index;
  final PageController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 54,
          // Parallax: the illustration drifts, fades and shrinks slightly as the
          // slide scrolls off, giving the swipe real depth.
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              final page = (controller.hasClients &&
                      controller.position.haveDimensions)
                  ? (controller.page ?? index.toDouble())
                  : index.toDouble();
              final delta = (page - index).clamp(-1.0, 1.0);
              final dist = delta.abs();
              return Transform.translate(
                offset: Offset(delta * -48, 0),
                child: Opacity(
                  opacity: (1 - dist * 0.9).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 1 - dist * 0.14,
                    child: child,
                  ),
                ),
              );
            },
            child: index == 1
                ? _GlobeIllustration(color: slide.color)
                : _SlideIllustration(index: index, color: slide.color),
          ),
        ),
        Expanded(
          flex: 46,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 12, 40, 150),
              // Text rises and fades in just behind the illustration: it slides
              // a touch slower (parallax depth) and lifts up as it settles.
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, child) {
                  final page = (controller.hasClients &&
                          controller.position.haveDimensions)
                      ? (controller.page ?? index.toDouble())
                      : index.toDouble();
                  final delta = (page - index).clamp(-1.0, 1.0);
                  final dist = delta.abs();
                  return Opacity(
                    opacity: (1 - dist * 1.3).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(delta * -24, dist * 28),
                      child: child,
                    ),
                  );
                },
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Text(
                      slide.title,
                      style: const TextStyle(
                        color: DS.textPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        letterSpacing: -0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),
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
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Slide illustration — animated Canvas drawing, one per feature slide
// ─────────────────────────────────────────────────────────────────────────────

class _SlideIllustration extends StatefulWidget {
  const _SlideIllustration({required this.index, required this.color});
  final int index;
  final Color color;

  @override
  State<_SlideIllustration> createState() => _SlideIllustrationState();
}

class _SlideIllustrationState extends State<_SlideIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => CustomPaint(
        painter: _SlidePainter(
          index: widget.index,
          color: widget.color,
          t: _ctrl.value,
        ),
        size: Size.infinite,
      ),
    );
  }
}

// ── Slide 1: line-art wireframe globe (real coastlines) ─────────────────────
// Real Natural Earth coastlines projected orthographically and drawn as thin
// lines in the brand colour, with a graticule and violet server pins — a clean,
// stylised globe (not a heavy photo texture).

// Parsed coastline cache: list of polylines, each a list of [lon, lat].
List<List<List<double>>>? _coastlineCache;
Future<List<List<List<double>>>> _loadCoastline() async {
  if (_coastlineCache != null) return _coastlineCache!;
  final raw = await rootBundle.loadString('assets/geo/coastline.geojson');
  final data = jsonDecode(raw) as Map<String, dynamic>;
  final out = <List<List<double>>>[];
  List<double> pt(dynamic p) =>
      [(p[0] as num).toDouble(), (p[1] as num).toDouble()];
  for (final f in (data['features'] as List)) {
    final geom = f['geometry'];
    if (geom == null) continue;
    final coords = geom['coordinates'];
    switch (geom['type']) {
      case 'LineString':
        out.add([for (final p in coords) pt(p)]);
      case 'MultiLineString':
        for (final line in coords) {
          out.add([for (final p in line) pt(p)]);
        }
    }
  }
  _coastlineCache = out;
  return out;
}

class _GlobeIllustration extends StatefulWidget {
  const _GlobeIllustration({required this.color});
  final Color color;

  @override
  State<_GlobeIllustration> createState() => _GlobeIllustrationState();
}

class _GlobeIllustrationState extends State<_GlobeIllustration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  List<List<List<double>>>? _coast;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 26))
      ..repeat();
    _loadCoastline().then((c) {
      if (mounted) setState(() => _coast = c);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => CustomPaint(
        painter: _LineGlobePainter(t: _ctrl.value, color: widget.color, coast: _coast),
        size: Size.infinite,
      ),
    );
  }
}

class _LineGlobePainter extends CustomPainter {
  _LineGlobePainter({required this.t, required this.color, required this.coast});
  final double t;
  final Color color;
  final List<List<List<double>>>? coast;

  /// Route/pin accent. Violet against the slide's cyan globe: both are brand
  /// colours, and the pairing separates "our network" from "the world" without
  /// introducing a third hue. (Was gold, which in DS means an active premium
  /// membership — nothing to do with servers, and it clashed with the cyan.)
  static const _link = DS.violet;

  static const _pins = <List<double>>[
    [55.75, 37.61],   // 0 Москва
    [52.52, 13.40],   // 1 Берлин
    [40.71, -74.0],   // 2 Нью-Йорк
    [1.35, 103.82],   // 3 Сингапур
    [35.68, 139.69],  // 4 Токио
  ];
  // Server-to-server routes (indices into _pins).
  static const _links = <List<int>>[
    [1, 2], [0, 1], [3, 4], [0, 3], [2, 4],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.5;
    final gr = math.min(size.width, size.height) * 0.36;

    // Soft glow + faint disc.
    canvas.drawCircle(Offset(cx, cy), gr * 1.55, Paint()
      ..shader = ui.Gradient.radial(Offset(cx, cy), gr * 1.55,
          [color.withValues(alpha: 0.22), color.withValues(alpha: 0)]));
    canvas.drawCircle(Offset(cx, cy), gr, Paint()
      ..color = color.withValues(alpha: 0.05));

    final lon0 = t * 360.0;          // continuous spin
    const tilt = 18.0;               // viewing tilt
    final tr = tilt * math.pi / 180;
    final cosT = math.cos(tr), sinT = math.sin(tr);

    (double, double, bool) proj(double lonDeg, double latDeg) {
      final lon = (lonDeg - lon0) * math.pi / 180;
      final lat = latDeg * math.pi / 180;
      final cl = math.cos(lat), sl = math.sin(lat), clon = math.cos(lon);
      final cosc = sinT * sl + cosT * cl * clon;
      final x = cl * math.sin(lon);
      final y = cosT * sl - sinT * cl * clon;
      return (cx + x * gr, cy - y * gr, cosc >= 0);
    }

    void drawLines(List<List<List<double>>> lines, Paint paint) {
      for (final line in lines) {
        final path = Path();
        var pen = false;
        for (final p in line) {
          final (sx, sy, front) = proj(p[0], p[1]);
          if (front) {
            if (!pen) { path.moveTo(sx, sy); pen = true; } else { path.lineTo(sx, sy); }
          } else {
            pen = false;
          }
        }
        canvas.drawPath(path, paint);
      }
    }

    // Graticule (meridians + parallels), faint.
    final grat = <List<List<double>>>[];
    for (var lo = -150; lo <= 180; lo += 30) {
      grat.add([for (double la = -80; la <= 80; la += 5) [lo.toDouble(), la]]);
    }
    for (var la = -60; la <= 60; la += 30) {
      grat.add([for (double lo = -180; lo <= 180; lo += 5) [lo.toDouble(), la.toDouble()]]);
    }
    drawLines(grat, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = color.withValues(alpha: 0.16));

    // Coastlines.
    if (coast != null) {
      drawLines(coast!, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.92));
    }

    // Rim.
    canvas.drawCircle(Offset(cx, cy), gr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.55));

    // Routes between servers. Each arc is drawn twice — a wide, very dim pass
    // for glow and a thin bright one on top — and shaded with a gradient that
    // fades out at both ends, so links dissolve into the globe instead of
    // stopping dead at the pins.
    for (var li = 0; li < _links.length; li++) {
      final a = _pins[_links[li][0]];
      final b = _pins[_links[li][1]];

      // Collect the visible run of points so the gradient can span the arc's
      // real on-screen extent rather than the (possibly hidden) endpoints.
      final pts = <Offset>[];
      final path = Path();
      var pen = false;
      for (var s = 0; s <= 48; s++) {
        final g = _gcInterp(a, b, s / 48);
        final (sx, sy, front) = proj(g[0], g[1]); // g = [lon, lat]
        if (front) {
          pts.add(Offset(sx, sy));
          if (!pen) { path.moveTo(sx, sy); pen = true; } else { path.lineTo(sx, sy); }
        } else {
          pen = false;
        }
      }
      if (pts.length < 2) continue;

      final shader = ui.Gradient.linear(
        pts.first, pts.last,
        [
          _link.withValues(alpha: 0.0),
          _link.withValues(alpha: 0.95),
          _link.withValues(alpha: 0.0),
        ],
        [0.0, 0.5, 1.0],
      );

      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..shader = shader
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..color = _link.withValues(alpha: 0.25));

      canvas.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round
        ..shader = shader);

      // Travelling packet with a short comet trail behind it.
      final f = (t * 5 + li * 0.27) % 1.0;
      for (var k = 0; k < 6; k++) {
        final tf = f - k * 0.018;
        if (tf < 0) continue;
        final gp = _gcInterp(a, b, tf);
        final (px, py, pf) = proj(gp[0], gp[1]);
        if (!pf) continue;
        final fade = (1 - k / 6) * (1 - k / 6);
        canvas.drawCircle(Offset(px, py), 2.4 * fade + 0.6,
            Paint()..color = _link.withValues(alpha: 0.55 * fade));
      }
      final gp = _gcInterp(a, b, f);
      final (px, py, pf) = proj(gp[0], gp[1]);
      if (pf) {
        canvas.drawCircle(Offset(px, py), 6, Paint()
          ..color = _link.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
        canvas.drawCircle(Offset(px, py), 2.2, Paint()..color = Colors.white);
      }
    }

    // Server pins — a slow radar ping plus a solid core, in the same accent as
    // the routes so the network reads as one system.
    for (var pi = 0; pi < _pins.length; pi++) {
      final (sx, sy, front) = proj(_pins[pi][1], _pins[pi][0]); // (lon, lat)
      if (!front) continue;
      final phase = (t * 3 + pi * 0.2) % 1.0;
      canvas.drawCircle(Offset(sx, sy), 3.5 + phase * 15, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _link.withValues(alpha: (1 - phase) * 0.45));
      canvas.drawCircle(Offset(sx, sy), 7, Paint()
        ..color = _link.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawCircle(Offset(sx, sy), 3.2, Paint()..color = Colors.white);
    }
  }

  /// Great-circle interpolation between two [lat, lon] points; returns the
  /// sample at fraction [f] as [lon, lat] (ready for the projector).
  static List<double> _gcInterp(List<double> a, List<double> b, double f) {
    final latA = a[0] * math.pi / 180, lonA = a[1] * math.pi / 180;
    final latB = b[0] * math.pi / 180, lonB = b[1] * math.pi / 180;
    final ax = math.cos(latA) * math.cos(lonA),
        ay = math.cos(latA) * math.sin(lonA),
        az = math.sin(latA);
    final bx = math.cos(latB) * math.cos(lonB),
        by = math.cos(latB) * math.sin(lonB),
        bz = math.sin(latB);
    final dot = (ax * bx + ay * by + az * bz).clamp(-1.0, 1.0);
    final om = math.acos(dot);
    if (om < 1e-6) return [a[1], a[0]];
    final s = math.sin(om);
    final k1 = math.sin((1 - f) * om) / s, k2 = math.sin(f * om) / s;
    final x = k1 * ax + k2 * bx, y = k1 * ay + k2 * by, z = k1 * az + k2 * bz;
    final lat = math.asin(z.clamp(-1.0, 1.0)), lon = math.atan2(y, x);
    return [lon * 180 / math.pi, lat * 180 / math.pi];
  }

  @override
  bool shouldRepaint(_LineGlobePainter old) =>
      old.t != t || old.coast != coast || old.color != color;
}

class _SlidePainter extends CustomPainter {
  const _SlidePainter({
    required this.index,
    required this.color,
    required this.t,
  });
  final int index;
  final Color color;
  final double t;

  /// Kept in step with _LineGlobePainter._link — see the note there.
  static const _link = DS.violet;

  void _radialGlow(Canvas canvas, Offset center, double radius, Color c, double alpha) {
    canvas.drawCircle(
      center, radius,
      Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          c.withValues(alpha: alpha),
          c.withValues(alpha: 0),
        ]),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (index) {
      case 0: _paintShield(canvas, size);
      case 1: _paintGlobe(canvas, size);
      case 2: _paintToggle(canvas, size);
    }
  }

  // ── Slide 0: glossy glass shield (privacy) ─────────────────────────────────
  void _paintShield(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.50;

    _radialGlow(canvas, Offset(cx, cy), size.width * 0.58, color, 0.34);

    // Soft protective pulse rings.
    for (var i = 0; i < 2; i++) {
      final phase = (t + i * 0.5) % 1.0;
      final r = size.width * 0.22 + phase * size.width * 0.22;
      canvas.drawCircle(
        Offset(cx, cy), r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: (1 - phase) * 0.40),
      );
    }

    // Drifting particles.
    final rnd = math.Random(11);
    for (var i = 0; i < 14; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final rad = size.width * (0.30 + rnd.nextDouble() * 0.22);
      final drift = math.sin(t * math.pi * 2 + i) * 4;
      canvas.drawCircle(
        Offset(cx + math.cos(a) * rad, cy + math.sin(a) * rad + drift),
        1.0 + rnd.nextDouble() * 1.8,
        Paint()..color = color.withValues(alpha: 0.10 + rnd.nextDouble() * 0.20),
      );
    }

    // Shield geometry.
    final shW = size.width * 0.42;
    final shH = shW * 1.22;
    final shX = cx - shW / 2;
    final shY = cy - shH * 0.52;
    final shield = Path()
      ..moveTo(cx, shY)
      ..lineTo(shX + shW, shY + shH * 0.15)
      ..lineTo(shX + shW, shY + shH * 0.56)
      ..quadraticBezierTo(shX + shW, shY + shH * 0.90, cx, shY + shH)
      ..quadraticBezierTo(shX, shY + shH * 0.90, shX, shY + shH * 0.56)
      ..lineTo(shX, shY + shH * 0.15)
      ..close();

    // Drop glow.
    canvas.drawPath(shield, Paint()
      ..color = color.withValues(alpha: 0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22));

    // Glass fill — vertical gradient (light top → deep bottom).
    canvas.drawPath(shield, Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, shY), Offset(cx, shY + shH),
        [
          Color.lerp(color, Colors.white, 0.34)!,
          color,
          Color.lerp(color, const Color(0xFF0A0A0F), 0.40)!,
        ],
        [0.0, 0.5, 1.0],
      ));

    // Glossy highlight on the upper half.
    canvas.save();
    canvas.clipPath(shield);
    canvas.drawRect(
      Rect.fromLTWH(shX, shY, shW, shH * 0.46),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, shY), Offset(cx, shY + shH * 0.46),
          [Colors.white.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0.0)],
        ),
    );
    canvas.restore();

    // Rim light.
    canvas.drawPath(shield, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = Colors.white.withValues(alpha: 0.55));

    // ── Padlock ────────────────────────────────────────────────────────────
    final lockW = shW * 0.42;
    final bodyH = lockW * 0.82;
    final lCx = cx;
    final bodyTop = cy - shH * 0.08;   // sits in the upper-middle of the shield
    final shackleR = lockW * 0.30;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(lCx, bodyTop - shackleR * 0.16), radius: shackleR),
      math.pi, math.pi, false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = shackleR * 0.40
        ..color = Colors.white.withValues(alpha: 0.95),
    );
    final bodyRect = Rect.fromLTWH(lCx - lockW / 2, bodyTop, lockW, bodyH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bodyRect, Radius.circular(lockW * 0.20)),
      Paint()
        ..shader = ui.Gradient.linear(
          bodyRect.topCenter, bodyRect.bottomCenter,
          [Colors.white, const Color(0xFFE6E6F0)],
        ),
    );
    final khR = lockW * 0.12;
    final khCy = bodyTop + bodyH * 0.40;
    canvas.drawCircle(Offset(lCx, khCy), khR, Paint()..color = color);
    canvas.drawRect(
      Rect.fromLTWH(lCx - khR * 0.45, khCy, khR * 0.9, bodyH * 0.30),
      Paint()..color = color,
    );
  }

  // ── Slide 1: connected globe (access) ──────────────────────────────────────
  void _paintGlobe(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.50;
    final gr = size.width * 0.30;

    _radialGlow(canvas, Offset(cx, cy), size.width * 0.56, color, 0.30);

    // Faint stars.
    final rnd = math.Random(42);
    for (var i = 0; i < 26; i++) {
      canvas.drawCircle(
        Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
        0.8 + rnd.nextDouble() * 1.3,
        Paint()..color = Colors.white.withValues(alpha: 0.04 + rnd.nextDouble() * 0.10),
      );
    }

    // Sphere — soft halo, radial gradient body (top-left highlight → dark rim).
    canvas.drawCircle(Offset(cx, cy), gr * 1.12, Paint()
      ..color = color.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24));
    canvas.drawCircle(Offset(cx, cy), gr, Paint()
      ..shader = ui.Gradient.radial(
        Offset(cx - gr * 0.35, cy - gr * 0.40), gr * 1.5,
        [
          Color.lerp(color, Colors.white, 0.30)!.withValues(alpha: 0.55),
          color.withValues(alpha: 0.30),
          color.withValues(alpha: 0.06),
        ],
        [0.0, 0.55, 1.0],
      ));
    canvas.drawCircle(Offset(cx, cy), gr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = color.withValues(alpha: 0.85));

    // ── Rotating Earth: real continent outlines projected orthographically ──
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: gr)));

    final lon0 = t * 360.0;            // one full spin per animation loop
    const lat0 = 16.0;                 // slight top-down viewing tilt
    final lat0r = lat0 * math.pi / 180;
    final cosLat0 = math.cos(lat0r), sinLat0 = math.sin(lat0r);

    // Orthographic projection → unit-sphere screen coords (right/up positive)
    // plus a front-hemisphere flag. Hidden points are clamped to the limb so
    // partially-visible continents fold against the edge instead of spiking.
    (double, double, bool) project(double lonDeg, double latDeg) {
      final lon = (lonDeg - lon0) * math.pi / 180;
      final lat = latDeg * math.pi / 180;
      final cosLat = math.cos(lat), sinLat = math.sin(lat), cosLon = math.cos(lon);
      final cosc = sinLat0 * sinLat + cosLat0 * cosLat * cosLon;
      var x = cosLat * math.sin(lon);
      var y = cosLat0 * sinLat - sinLat0 * cosLat * cosLon;
      final front = cosc >= 0;
      if (!front) {
        final r = math.sqrt(x * x + y * y);
        if (r > 1e-6) { x /= r; y /= r; }
      }
      return (x, y, front);
    }

    // Continents (filled land).
    final land = Color.lerp(color, const Color(0xFF24A36B), 0.62)!;
    final landPaint = Paint()..color = land.withValues(alpha: 0.92);
    for (final poly in _kContinents) {
      var anyFront = false;
      final path = Path();
      for (var i = 0; i < poly.length; i++) {
        final (x, y, front) = project(poly[i][0], poly[i][1]);
        if (front) anyFront = true;
        final sx = cx + x * gr, sy = cy - y * gr;
        if (i == 0) { path.moveTo(sx, sy); } else { path.lineTo(sx, sy); }
      }
      path.close();
      if (anyFront) canvas.drawPath(path, landPaint);
    }

    // Graticule: static latitude rings + rotating front-facing meridians.
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = color.withValues(alpha: 0.20);
    for (var i = -2; i <= 2; i++) {
      final latH = gr * 0.42 * i;
      final latR = math.sqrt(math.max(0.0, gr * gr - latH * latH));
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy + latH), width: latR * 2, height: latR * 0.34),
        gridPaint,
      );
    }
    for (var m = 0; m < 6; m++) {
      final mp = Path();
      var started = false;
      for (double lat = -85; lat <= 85; lat += 6) {
        final (x, y, front) = project(m * 30.0, lat);
        if (front) {
          final sx = cx + x * gr, sy = cy - y * gr;
          if (!started) { mp.moveTo(sx, sy); started = true; } else { mp.lineTo(sx, sy); }
        } else {
          started = false;
        }
      }
      canvas.drawPath(mp, gridPaint);
    }
    canvas.restore();

    // Connection pins + violet routes between them.
    final pins = [
      Offset(cx + gr * 0.55, cy - gr * 0.50),
      Offset(cx - gr * 0.60, cy + gr * 0.20),
      Offset(cx + gr * 0.20, cy + gr * 0.66),
    ];
    void route(Offset a, Offset b, double lift) {
      final c = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - lift);
      canvas.drawPath(
        Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(c.dx, c.dy, b.dx, b.dy),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = _link.withValues(alpha: 0.55),
      );
    }
    route(pins[0], pins[1], 50);
    route(pins[1], pins[2], 46);
    for (final p in pins) {
      canvas.drawCircle(p, 9, Paint()..color = _link.withValues(alpha: 0.22));
      canvas.drawCircle(p, 5, Paint()..color = Colors.white);
      canvas.drawCircle(p, 5, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = _link);
    }
  }

  // ── Slide 2: one-tap power button (simplicity) ─────────────────────────────
  /// Paints an icon-font glyph centred on [center]. Used so the illustration
  /// shows the *actual* icon the app uses rather than a hand-drawn lookalike.
  void _paintIcon(Canvas canvas, Offset center, IconData icon, double size,
      Color color) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  // ── Slide 2: the connect button, in its connected state ───────────────────
  // Deliberately a faithful replica of the real button on the home screen
  // (_ConnectButton / _PulseRingsPainter): same radial-gradient recipe, same
  // ring timing, same glyph. The slide promises "press it and you're
  // protected", so it shows the protected state — emerald + shield — which is
  // exactly what the user will see a moment later in the app itself.
  void _paintToggle(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.50;
    final br = size.width * 0.17;
    // The real button is 128px across with rings running out to r=104, i.e.
    // 1.625x the button radius. Everything below is expressed in those terms
    // so the proportions survive any illustration size.
    const ringOuter = 104.0 / 64.0;

    _radialGlow(canvas, Offset(cx, cy), size.width * 0.52, color, 0.30);

    // Pulse rings — three, phase-offset by 1/3, ease-out, exactly as the
    // home-screen button emits them.
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final ep = 1 - (1 - p) * (1 - p);
      canvas.drawCircle(
        Offset(cx, cy), br + (br * ringOuter - br) * ep,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = color.withValues(alpha: (1 - p) * 0.55),
      );
    }

    // Drop glow — the button's boxShadow (colour @ 32%, 28px blur).
    canvas.drawCircle(Offset(cx, cy), br, Paint()
      ..color = color.withValues(alpha: 0.32)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, br * 0.44));

    // Disc — same radial gradient as the widget: highlight up-left, body,
    // then darkened lower-right. No extra gloss or rim; the real button has
    // neither, and they were what made this read as a different control.
    canvas.drawCircle(Offset(cx, cy), br, Paint()
      ..shader = ui.Gradient.radial(
        Offset(cx - br * 0.35, cy - br * 0.45), br * 1.05,
        [
          Color.lerp(color, Colors.white, 0.24)!,
          color,
          Color.lerp(color, Colors.black, 0.20)!,
        ],
        [0.0, 0.55, 1.0],
      ));

    // Shield glyph at the widget's ratio (44px icon in a 128px button).
    _paintIcon(canvas, Offset(cx, cy), PhosphorIconsFill.shield,
        br * (44 / 64), Colors.white);
  }

  @override
  bool shouldRepaint(_SlidePainter old) =>
      old.index != index || old.t != t || old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Auth slide
// ─────────────────────────────────────────────────────────────────────────────

class _AuthSlide extends StatelessWidget {
  const _AuthSlide({
    required this.step,
    required this.provider,
    required this.emailMode,
    required this.errorMessage,
    required this.trialMessage,
    required this.trialClaimed,
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.nameCtrl,
    required this.referralCtrl,
    required this.showReferralField,
    required this.onShowReferralField,
    required this.onClearReferralField,
    required this.passwordVisible,
    required this.onPasswordToggle,
    required this.onTelegramTap,
    required this.onGoogleTap,
    required this.onEmailButtonTap,
    required this.onEmailModeSwitch,
    required this.onEmailSubmit,
    required this.onCancelPolling,
    required this.onBackFromEmail,
    required this.onClaimTrial,
    required this.onSkipTrial,
  });

  final _AuthStep step;
  final _AuthProvider provider;
  final _EmailMode emailMode;
  final String? errorMessage;
  final String? trialMessage;
  final bool trialClaimed;
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final TextEditingController nameCtrl;
  final TextEditingController referralCtrl;
  final bool showReferralField;
  final VoidCallback onShowReferralField;
  final VoidCallback onClearReferralField;
  final bool passwordVisible;
  final VoidCallback onPasswordToggle;
  final VoidCallback onTelegramTap;
  final VoidCallback onGoogleTap;
  final VoidCallback onEmailButtonTap;
  final ValueChanged<_EmailMode> onEmailModeSwitch;
  final VoidCallback onEmailSubmit;
  final VoidCallback onCancelPolling;
  final VoidCallback onBackFromEmail;
  final VoidCallback onClaimTrial;
  final VoidCallback onSkipTrial;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ConstrainedBox(
            // Fill the viewport so the content can be vertically centred even
            // when it's short (avoids the heading hugging the top).
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              // Bottom inset leaves room for the page dots; centring is done
              // within the remaining space.
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _buildContent(context),
                ),
              ),
            ),
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
                        ? 'Открываем ${provider == _AuthProvider.google ? 'Google' : 'Telegram'}…'
                        : (provider == _AuthProvider.google
                            ? 'Завершите вход в браузере…'
                            : 'Ожидаем подтверждения…\nНажмите «Старт» в боте.'))
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
              ? 'Открываем ${provider == _AuthProvider.google ? 'Google' : 'Telegram'}…'
              : 'Ожидаем подтверждения…')
        else ...[
          _AuthButton(
            icon: PhosphorIconsDuotone.paperPlaneTilt,
            label: 'Войти через Telegram',
            color: DS.telegramBlue,
            onTap: onTelegramTap,
          ),
          const SizedBox(height: 12),
          _AuthButton(
            icon: PhosphorIconsDuotone.googleLogo,
            label: 'Войти через Google',
            color: const Color(0xFFEA4335),
            onTap: onGoogleTap,
          ),
          const SizedBox(height: 12),
          _AuthButton(
            icon: PhosphorIconsDuotone.envelopeSimple,
            label: 'Войти по Email',
            color: DS.violet,
            onTap: onEmailButtonTap,
          ),
          const SizedBox(height: 4),
          _buildReferralField(),
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

  // ── Referral code ───────────────────────────────────────────────────────────
  // Collapsed behind a link: most people arrive without a code, and an empty
  // field sitting under the login buttons would read as one more thing to fill
  // in before getting started. Applies to whichever method they then pick.
  Widget _buildReferralField() {
    if (!showReferralField) {
      return TextButton(
        onPressed: onShowReferralField,
        child: const Text('Есть код приглашения?',
            style: TextStyle(color: DS.textMuted, fontSize: 13)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: referralCtrl,
        autocorrect: false,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(color: DS.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          hintText: 'Код приглашения',
          prefixIcon: const Icon(PhosphorIconsRegular.gift,
              size: 18, color: DS.textMuted),
          suffixIcon: IconButton(
            onPressed: onClearReferralField,
            icon: const Icon(PhosphorIconsRegular.x,
                size: 16, color: DS.textMuted),
          ),
        ),
      ),
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

        // Referral code (register only). Someone who tapped straight through to
        // this form never passed the link on the previous screen, so it has to
        // be reachable here too — and this is the one flow where a code is
        // typed rather than carried over.
        if (isRegister) ...[
          const SizedBox(height: 12),
          _Field(
            controller: referralCtrl,
            label: 'Код приглашения (необязательно)',
            icon: Icons.card_giftcard_rounded,
            keyboardType: TextInputType.text,
          ),
        ],
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

// ─────────────────────────────────────────────────────────────────────────────
// _MorphingBlobs — slow, drifting background for the onboarding pager.
// Two large soft blobs in the brand violet + cyan, drifting along independent
// Lissajous paths and morphing their outline so they actually *change shape*
// (instead of just pulsing a perfect circle's radius).
//
// Implementation notes:
//   * Monotonic Ticker → continuous time `_t` (seconds). Speeds tuned for a
//     ~90-second cycle so the motion reads as "slow drift", not animation.
//   * The blob outline is a 64-vertex path whose polar radius is modulated
//     by two low-frequency sine harmonics — that's what gives the soft
//     "perekat" / liquid morph feel rather than a breathing circle.
//   * Each blob is filled with a radial gradient and a 40px MaskFilter blur
//     so the deformed edges blend into the dark wash beneath.
//   * Parent IgnorePointer ensures the layer never eats user touches.
// ─────────────────────────────────────────────────────────────────────────────
class _MorphingBlobs extends StatefulWidget {
  const _MorphingBlobs();

  @override
  State<_MorphingBlobs> createState() => _MorphingBlobsState();
}

class _MorphingBlobsState extends State<_MorphingBlobs>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  double _t = 0;
  Duration _last = Duration.zero;

  // Two blobs — that's it. One violet (warm-toned brand), one cyan (cool
  // accent). All angular speeds expressed in rad/s; values below correspond
  // to roughly 60–120 s for a full cycle of any individual term.
  static final List<_BlobSpec> _specs = [
    _BlobSpec(
      color: DS.violet,
      cx: 0.28, cy: 0.30,
      ax: 0.18, ay: 0.15,
      wx: 0.08, wy: 0.06,
      px: 0.0, py: 1.1,
      r0: 0.42, ar: 0.06, wr: 0.05, pr: 0.4,
      morphAmp1: 0.10, morphAmp2: 0.06,
      morphK1: 3, morphK2: 5,
      morphW1: 0.04, morphW2: 0.07,
      morphP1: 0.0, morphP2: 1.7,
    ),
    _BlobSpec(
      color: DS.cyan,
      cx: 0.74, cy: 0.72,
      ax: 0.16, ay: 0.14,
      wx: 0.07, wy: 0.09,
      px: 2.1, py: 0.3,
      r0: 0.38, ar: 0.05, wr: 0.06, pr: 2.4,
      morphAmp1: 0.09, morphAmp2: 0.07,
      morphK1: 4, morphK2: 6,
      morphW1: 0.05, morphW2: 0.08,
      morphP1: 1.2, morphP2: 3.4,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    setState(() => _t += dt);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BlobsPainter(t: _t, specs: _specs));
  }
}

class _BlobSpec {
  final Color color;
  final double cx, cy;     // base centre, fraction of canvas size
  final double ax, ay;     // drift amplitude, fraction
  final double wx, wy;     // drift angular speed (rad/s)
  final double px, py;     // drift phase offset (rad)
  final double r0, ar;     // mean radius + breathe amplitude, frac of shortest
  final double wr, pr;     // breathe speed/phase
  // ── Outline morph (the "lava-lamp" deformation) ─────────────────────────
  // r(θ,t) = r * (1 + amp1*sin(k1·θ + p1 + w1·t) + amp2*sin(k2·θ + p2 + w2·t))
  final double morphAmp1, morphAmp2;   // peak relative deformation
  final int    morphK1, morphK2;       // angular harmonic — how many "lobes"
  final double morphW1, morphW2;       // temporal speed of each harmonic
  final double morphP1, morphP2;       // temporal phase offset
  const _BlobSpec({
    required this.color,
    required this.cx, required this.cy,
    required this.ax, required this.ay,
    required this.wx, required this.wy,
    required this.px, required this.py,
    required this.r0, required this.ar,
    required this.wr, required this.pr,
    required this.morphAmp1, required this.morphAmp2,
    required this.morphK1, required this.morphK2,
    required this.morphW1, required this.morphW2,
    required this.morphP1, required this.morphP2,
  });
}

class _BlobsPainter extends CustomPainter {
  _BlobsPainter({required this.t, required this.specs});
  final double t;
  final List<_BlobSpec> specs;
  static const int _samples = 64; // vertices per blob outline

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    // Subtle base wash so the background isn't pure black between blobs.
    final wash = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, size.height),
        const [Color(0xFF0B0716), Color(0xFF06030C)],
      );
    canvas.drawRect(Offset.zero & size, wash);

    for (final s in specs) {
      final cx = size.width  * (s.cx + s.ax * math.sin(s.wx * t + s.px));
      final cy = size.height * (s.cy + s.ay * math.cos(s.wy * t + s.py));
      final baseR = shortest * (s.r0 + s.ar * math.sin(s.wr * t + s.pr));
      final center = Offset(cx, cy);

      // Build the deformed outline. We multiply the mean radius by a sum of
      // two slow sines parameterised in (angle, time) — the result is a soft
      // amoeboid shape that visibly *changes form* over time.
      final path = Path();
      for (int i = 0; i <= _samples; i++) {
        final theta = 2 * math.pi * i / _samples;
        final r = baseR *
            (1 +
                s.morphAmp1 * math.sin(s.morphK1 * theta + s.morphP1 + s.morphW1 * t) +
                s.morphAmp2 * math.sin(s.morphK2 * theta + s.morphP2 + s.morphW2 * t));
        final x = center.dx + r * math.cos(theta);
        final y = center.dy + r * math.sin(theta);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();

      // Radial fill — solid core fading to transparent at ~1.1× baseR so the
      // morph deformation lands inside the gradient stops and looks natural.
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          center,
          baseR * 1.15,
          [
            s.color.withValues(alpha: 0.36),
            s.color.withValues(alpha: 0.0),
          ],
          const [0.0, 1.0],
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BlobsPainter old) => old.t != t;
}
