import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../main.dart' show DS;
import '../services/app_logger.dart';
import '../services/referral_service.dart';
import '../utils/referral_card.dart';

/// Full-page referral hub: invite hero with code, progress strip, friends
/// list (paginated), earnings history.
///
/// Pulls its data from /cabinet/referral (info + list + earnings + terms).
/// Falls back to a friendly "not available yet" state if the user has no
/// auth header the backend will accept.
class ReferralPage extends StatefulWidget {
  const ReferralPage({super.key});

  @override
  State<ReferralPage> createState() => _ReferralPageState();
}

class _ReferralPageState extends State<ReferralPage> {
  ReferralInfo? _info;
  ReferralListPage? _friends;
  ReferralEarningsPage? _earnings;
  ReferralTerms? _terms;
  bool _loading = true;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final results = await Future.wait([
      ReferralService.getInfo(),
      ReferralService.getList(page: 1, perPage: 20),
      ReferralService.getEarnings(page: 1, perPage: 20),
      ReferralService.getTerms(),
    ]);
    if (!mounted) return;
    setState(() {
      _info = results[0] as ReferralInfo?;
      _friends = results[1] as ReferralListPage?;
      _earnings = results[2] as ReferralEarningsPage?;
      _terms = results[3] as ReferralTerms?;
      _loading = false;
    });
  }

  Future<void> _copyCode() async {
    final info = _info;
    if (info == null) return;
    await Clipboard.setData(ClipboardData(text: info.referralCode));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _share() async {
    final info = _info;
    if (info == null) return;
    HapticFeedback.selectionClick();
    // Branded invite card with QR — falls back to plain text on any failure.
    try {
      final png = await renderReferralCardPng(info);
      if (png != null) {
        await SharePlus.instance.share(ShareParams(
          files: [
            XFile.fromData(png, mimeType: 'image/png', name: 'ulya_invite.png'),
          ],
          text: info.shareText,
        ));
        return;
      }
    } catch (e) {
      appLogger.error('ReferralPage', 'card render failed: $e');
    }
    await SharePlus.instance.share(ShareParams(text: info.shareText));
  }

  String _fmtRubles(double v) {
    if (v == v.roundToDouble()) return '${v.toInt()} ₽';
    return '${v.toStringAsFixed(2)} ₽';
  }

  String _fmtDate(DateTime d) {
    const months = [
      'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DS.surface0,
      appBar: AppBar(
        backgroundColor: DS.surface0,
        elevation: 0,
        leading: IconButton(
          icon: Icon(PhosphorIconsBold.caretLeft, color: DS.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Рефералы',
            style: TextStyle(
                color: DS.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18)),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: DS.violet))
          : _info == null
              ? _buildUnavailable()
              : RefreshIndicator(
                  color: DS.violet,
                  backgroundColor: DS.surface2,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _buildHero(),
                      const SizedBox(height: 12),
                      _buildProgressCard(),
                      const SizedBox(height: 12),
                      _buildFriendsCard(),
                      const SizedBox(height: 12),
                      _buildEarningsCard(),
                      const SizedBox(height: 12),
                      _buildHowItWorksCard(),
                    ],
                  ),
                ),
    );
  }

  // ── Empty / unavailable state ──────────────────────────────────────────
  Widget _buildUnavailable() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(PhosphorIconsDuotone.gift, size: 64, color: DS.textMuted),
          const SizedBox(height: 16),
          const Text(
            'Реферальная программа пока недоступна',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: DS.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Войдите в аккаунт, чтобы получить персональный код и приглашать друзей.',
            textAlign: TextAlign.center,
            style: TextStyle(color: DS.textSecondary, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ── Hero card ──────────────────────────────────────────────────────────
  Widget _buildHero() {
    final info = _info!;
    final commission = info.commissionPercent;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF241D46), Color(0xFF181430)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.65],
        ),
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.violet.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: DS.violet.withValues(alpha: 0.18),
            blurRadius: 28,
            spreadRadius: -8,
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [DS.violet, DS.cyan],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: DS.violet.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(PhosphorIconsFill.gift, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Пригласите друзей',
                      style: TextStyle(
                          color: DS.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          height: 1.15)),
                  const SizedBox(height: 4),
                  Text(
                    commission > 0
                        ? 'Получайте $commission% с каждого их платежа'
                        : 'Поделитесь кодом и получайте бонусы',
                    style: const TextStyle(
                      color: DS.textSecondary,
                      fontSize: 12.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 18),

          // Code chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: DS.surface1.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(DS.radiusSm),
              border: Border.all(color: DS.border),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('ВАШ КОД',
                        style: TextStyle(
                          color: DS.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        )),
                    const SizedBox(height: 4),
                    Text(
                      info.referralCode.isEmpty ? '—' : info.referralCode,
                      style: const TextStyle(
                        color: DS.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _copyCode,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: _copied ? DS.emerald : DS.violet,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        _copied
                            ? PhosphorIconsBold.check
                            : PhosphorIconsBold.copy,
                        color: Colors.white,
                        size: 14),
                    const SizedBox(width: 6),
                    Text(_copied ? 'Готово' : 'Копировать',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ]),
          ),

          const SizedBox(height: 12),

          // Share button
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _share,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: DS.telegramBlue,
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  boxShadow: [
                    BoxShadow(
                      color: DS.telegramBlue.withValues(alpha: 0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(PhosphorIconsDuotone.paperPlaneTilt,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 10),
                  const Text('Поделиться в Telegram',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stats / progress card ─────────────────────────────────────────────
  Widget _buildProgressCard() {
    final info = _info!;
    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ВАША СТАТИСТИКА',
              style: TextStyle(
                color: DS.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: _StatTile(
                    icon: PhosphorIconsDuotone.users,
                    color: DS.cyan,
                    value: '${info.totalReferrals}',
                    label: 'Приглашено')),
            const SizedBox(width: 10),
            Expanded(
                child: _StatTile(
                    icon: PhosphorIconsDuotone.userCheck,
                    color: DS.emerald,
                    value: '${info.activeReferrals}',
                    label: 'Активны')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _StatTile(
                    icon: PhosphorIconsDuotone.coins,
                    color: DS.gold,
                    value: _fmtRubles(info.totalEarningsRubles),
                    label: 'Всего заработано')),
            const SizedBox(width: 10),
            Expanded(
                child: _StatTile(
                    icon: PhosphorIconsDuotone.wallet,
                    color: DS.violet,
                    value: _fmtRubles(info.availableBalanceRubles),
                    label: 'Доступно')),
          ]),
        ],
      ),
    );
  }

  // ── Friends list ──────────────────────────────────────────────────────
  Widget _buildFriendsCard() {
    final friends = _friends?.items ?? const [];
    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Row(children: [
              const Expanded(
                child: Text('ПРИГЛАШЁННЫЕ',
                    style: TextStyle(
                      color: DS.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    )),
              ),
              Text('${_friends?.total ?? 0}',
                  style: const TextStyle(
                      color: DS.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          if (friends.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: Row(children: [
                Icon(PhosphorIconsDuotone.userPlus,
                    size: 18, color: DS.textMuted),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Пока никто не присоединился. Поделитесь кодом — '
                    'друг получит скидку, вы получите бонус.',
                    style: TextStyle(
                        color: DS.textSecondary, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ]),
            )
          else
            ...friends.map((f) => _FriendTile(
                  friend: f,
                  dateLabel: f.createdAt != null ? _fmtDate(f.createdAt!) : '—',
                )),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // ── Earnings ──────────────────────────────────────────────────────────
  Widget _buildEarningsCard() {
    final earnings = _earnings?.items ?? const [];
    if (earnings.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
            child: Row(children: [
              const Expanded(
                child: Text('ИСТОРИЯ НАЧИСЛЕНИЙ',
                    style: TextStyle(
                      color: DS.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    )),
              ),
              Text('+${_fmtRubles(_earnings!.totalAmountRubles)}',
                  style: const TextStyle(
                      color: DS.gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          for (final e in earnings.take(10)) _EarningTile(
                earning: e,
                dateLabel: e.createdAt != null ? _fmtDate(e.createdAt!) : '—',
                amountLabel: _fmtRubles(e.amountRubles),
              ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // ── How it works ──────────────────────────────────────────────────────
  Widget _buildHowItWorksCard() {
    final terms = _terms;
    final commission = terms?.commissionPercent ?? _info?.commissionPercent ?? 0;
    final firstBonus = terms?.firstTopupBonusRubles ?? 0;
    return Container(
      decoration: BoxDecoration(
        color: DS.surface1,
        borderRadius: BorderRadius.circular(DS.radius),
        border: Border.all(color: DS.border),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('КАК ЭТО РАБОТАЕТ',
              style: TextStyle(
                color: DS.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const SizedBox(height: 12),
          _Step(
            icon: PhosphorIconsDuotone.paperPlaneTilt,
            color: DS.telegramBlue,
            title: 'Отправьте код',
            subtitle: 'Поделитесь с другом в один тап.',
          ),
          const SizedBox(height: 10),
          _Step(
            icon: PhosphorIconsDuotone.userPlus,
            color: DS.cyan,
            title: 'Друг регистрируется',
            subtitle: firstBonus > 0
                ? 'Он получит бонус ${_fmtRubles(firstBonus)} на первое пополнение.'
                : 'Он регистрируется по вашему коду.',
          ),
          const SizedBox(height: 10),
          _Step(
            icon: PhosphorIconsDuotone.coins,
            color: DS.gold,
            title: commission > 0
                ? 'Вы получаете $commission% с его платежей'
                : 'Вы получаете бонус',
            subtitle: 'Бонусы зачисляются автоматически на ваш баланс.',
          ),
        ],
      ),
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;
  const _StatTile({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: DS.surface2,
          borderRadius: BorderRadius.circular(DS.radiusSm),
          border: Border.all(color: DS.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                      color: DS.textMuted,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                  color: DS.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );
}

class _FriendTile extends StatelessWidget {
  final ReferralFriend friend;
  final String dateLabel;
  const _FriendTile({required this.friend, required this.dateLabel});

  @override
  Widget build(BuildContext context) {
    final isActive = friend.hasSubscription;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: DS.violet.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: DS.violet.withValues(alpha: 0.3)),
          ),
          alignment: Alignment.center,
          child: Text(friend.initials,
              style: const TextStyle(
                color: DS.violet,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              )),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friend.displayName,
                  style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                dateLabel,
                style: const TextStyle(color: DS.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (isActive ? DS.emerald : DS.textMuted)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: (isActive ? DS.emerald : DS.textMuted)
                    .withValues(alpha: 0.35)),
          ),
          child: Text(
            isActive ? 'Активен' : 'Зарегистрирован',
            style: TextStyle(
              color: isActive ? DS.emerald : DS.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }
}

class _EarningTile extends StatelessWidget {
  final ReferralEarning earning;
  final String dateLabel;
  final String amountLabel;
  const _EarningTile({
    required this.earning,
    required this.dateLabel,
    required this.amountLabel,
  });

  @override
  Widget build(BuildContext context) {
    final source = earning.referralFirstName?.isNotEmpty == true
        ? earning.referralFirstName!
        : (earning.referralUsername?.isNotEmpty == true
            ? '@${earning.referralUsername}'
            : 'Бонус');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(children: [
        Container(
          width: 30, height: 30,
          decoration: BoxDecoration(
            color: DS.gold.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(PhosphorIconsFill.coin, color: DS.gold, size: 14),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(source,
                  style: const TextStyle(
                    color: DS.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(dateLabel,
                  style: const TextStyle(color: DS.textMuted, fontSize: 11)),
            ],
          ),
        ),
        Text('+$amountLabel',
            style: const TextStyle(
              color: DS.gold,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            )),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  const _Step({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                      color: DS.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    )),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: const TextStyle(
                      color: DS.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    )),
              ],
            ),
          ),
        ],
      );
}
