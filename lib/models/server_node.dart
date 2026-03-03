class ServerNode {
  final String uuid;
  final String name;
  final String address;
  final String countryCode;
  final bool isConnected;
  final bool isDisabled;
  final int? usersOnline;
  final String? link;
  final String? protocol;
  final String? description;

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
    this.description,
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
      link: json['link'] as String?,
      protocol: json['protocol'] as String?,
      description: json['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'name': name,
    'address': address,
    'countryCode': countryCode,
    'isConnected': isConnected,
    'isDisabled': isDisabled,
    'usersOnline': usersOnline,
    'link': link,
    'protocol': protocol,
    'description': description,
  };

  bool get isAvailable => isConnected && !isDisabled;
}