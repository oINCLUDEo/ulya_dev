/// Model for the GET /mobile/v1/me response.
class MeResponse {
  const MeResponse({
    this.telegramId,
    this.firstName,
    this.lastName,
    this.username,
    required this.hasSubscription,
    this.subscription,
  });

  final int? telegramId;
  final String? firstName;
  final String? lastName;
  final String? username;
  final bool hasSubscription;
  final MeSubscription? subscription;

  String get displayName {
    if (firstName != null && firstName!.isNotEmpty) {
      final parts = [firstName, if (lastName != null) lastName];
      return parts.whereType<String>().join(' ');
    }
    if (username != null && username!.isNotEmpty) return '@$username';
    return 'Пользователь';
  }

  factory MeResponse.fromJson(Map<String, dynamic> json) {
    final subJson = json['subscription'] as Map<String, dynamic>?;
    return MeResponse(
      telegramId: (json['telegram_id'] as num?)?.toInt(),
      firstName: json['first_name'] as String?,
      lastName: json['last_name'] as String?,
      username: json['username'] as String?,
      hasSubscription: json['has_subscription'] as bool? ?? false,
      subscription: subJson != null ? MeSubscription.fromJson(subJson) : null,
    );
  }
}

class MeSubscription {
  const MeSubscription({
    required this.status,
    required this.isTrial,
    this.expireAt,
    required this.trafficLimitGb,
    required this.trafficUsedGb,
    this.subscriptionUrl,
    required this.deviceLimit,
  });

  final String status;
  final bool isTrial;

  /// Unix timestamp (seconds) when subscription expires, or null if unlimited.
  final int? expireAt;

  /// Total traffic quota in GB. 0 means unlimited.
  final int trafficLimitGb;

  /// Traffic consumed in GB.
  final double trafficUsedGb;

  final String? subscriptionUrl;
  final int deviceLimit;

  bool get isActive => status == 'active';

  bool get isExpired => status == 'expired';

  /// Fraction [0,1] of traffic used. 0 when limit is unlimited.
  double get trafficFraction =>
      trafficLimitGb > 0
          ? (trafficUsedGb / trafficLimitGb).clamp(0.0, 1.0)
          : 0.0;

  DateTime? get expireDate =>
      expireAt != null
          ? DateTime.fromMillisecondsSinceEpoch(expireAt! * 1000)
          : null;

  String get formattedExpiry {
    final d = expireDate;
    if (d == null) return 'Бессрочно';
    return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  }

  factory MeSubscription.fromJson(Map<String, dynamic> json) {
    return MeSubscription(
      status: json['status'] as String? ?? 'unknown',
      isTrial: json['is_trial'] as bool? ?? false,
      expireAt: (json['expire_at'] as num?)?.toInt(),
      trafficLimitGb: (json['traffic_limit_gb'] as num?)?.toInt() ?? 0,
      trafficUsedGb: (json['traffic_used_gb'] as num?)?.toDouble() ?? 0.0,
      subscriptionUrl: json['subscription_url'] as String?,
      deviceLimit: (json['device_limit'] as num?)?.toInt() ?? 1,
    );
  }
}
