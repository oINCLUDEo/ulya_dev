/// Subscription quota and expiry information parsed from the
/// `Subscription-Userinfo` HTTP response header.
class SubscriptionInfo {
  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final DateTime? expireDate;

  const SubscriptionInfo({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.totalBytes,
    this.expireDate,
  });

  /// Bytes consumed (upload + download).
  int get usedBytes => uploadBytes + downloadBytes;

  /// Fraction [0.0, 1.0] of the quota used. Returns 0 when [totalBytes] is 0.
  double get usedFraction =>
      totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 ГБ';
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(1)} ГБ';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} МБ';
  }

  String get formattedUsed => _formatBytes(usedBytes);
  String get formattedTotal =>
      totalBytes > 0 ? _formatBytes(totalBytes) : '∞';

  Map<String, dynamic> toJson() => {
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expireEpoch': expireDate?.millisecondsSinceEpoch,
  };

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    final expireMs = json['expireEpoch'] as int?;
    return SubscriptionInfo(
      uploadBytes: json['uploadBytes'] as int? ?? 0,
      downloadBytes: json['downloadBytes'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int? ?? 0,
      expireDate: expireMs != null && expireMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(expireMs)
          : null,
    );
  }
}
