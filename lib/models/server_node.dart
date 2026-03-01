class ServerNode {
  final String uuid;
  final String name;
  final String address;
  final String countryCode;
  final bool isConnected;
  final bool isDisabled;
  final int? usersOnline;
  /// The raw VPN config link (vless://, vmess://, trojan://, etc.).
  /// Populated when node comes from a subscription URL.
  final String? link;
  /// Protocol identifier: 'vless', 'vmess', 'trojan', 'ss', etc.
  final String? protocol;

  const ServerNode({
    required this.uuid,
    required this.name,
    required this.address,
    required this.countryCode,
    required this.isConnected,
    required this.isDisabled,
    this.usersOnline,
    this.link,
    this.protocol,
  });

  factory ServerNode.fromJson(Map<String, dynamic> json) {
    return ServerNode(
      uuid: json['uuid'] as String? ?? '',
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? '',
      countryCode: json['countryCode'] as String? ?? '',
      isConnected: json['isConnected'] as bool? ?? false,
      isDisabled: json['isDisabled'] as bool? ?? false,
      usersOnline: json['usersOnline'] as int?,
    );
  }

  bool get isAvailable => isConnected && !isDisabled;
}

