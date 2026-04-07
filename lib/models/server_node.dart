import 'vless_server.dart';

class ServerNode {
  final String uuid;
  final String name;
  final String address;
  final int serverPort;        // TCP port — used for ping and route exclusion
  final String countryCode;
  final bool isConnected;
  final bool isDisabled;
  final int? usersOnline;
  final String? link;
  final String? protocol;
  final String? description;

  /// Fully-parsed VLESS parameters. Non-null only for `vless://` links.
  final VlessServer? vlessServer;

  const ServerNode({
    required this.uuid,
    required this.name,
    required this.address,
    this.serverPort = 443,
    required this.countryCode,
    required this.isConnected,
    required this.isDisabled,
    this.usersOnline,
    this.link,
    this.protocol,
    this.description,
    this.vlessServer,
  });

  factory ServerNode.fromJson(Map<String, dynamic> json) {
    final vsRaw = json['vlessServer'];
    return ServerNode(
      uuid:        json['uuid']        as String? ?? '',
      name:        json['name']        as String? ?? '',
      address:     json['address']     as String? ?? '',
      serverPort:  json['serverPort']  as int?    ?? 443,
      countryCode: json['countryCode'] as String? ?? '',
      isConnected: json['isConnected'] as bool?   ?? false,
      isDisabled:  json['isDisabled']  as bool?   ?? false,
      usersOnline: json['usersOnline'] as int?,
      link:        json['link']        as String?,
      protocol:    json['protocol']    as String?,
      description: json['description'] as String?,
      vlessServer: vsRaw is Map<String, dynamic>
          ? VlessServer.fromJson(vsRaw)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid':        uuid,
    'name':        name,
    'address':     address,
    'serverPort':  serverPort,
    'countryCode': countryCode,
    'isConnected': isConnected,
    'isDisabled':  isDisabled,
    'usersOnline': usersOnline,
    'link':        link,
    'protocol':    protocol,
    'description': description,
    'vlessServer': vlessServer?.toJson(),
  };

  bool get isAvailable => isConnected && !isDisabled;
}
