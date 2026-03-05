import 'package:flutter/foundation.dart';

import '../models/server_node.dart';

/// Shared notifier for the currently selected VPN server.
///
/// Used to synchronise selection between [HomePage] and [ServersPage]
/// without introducing an external state-management dependency.
final ValueNotifier<ServerNode?> selectedServerNotifier =
    ValueNotifier<ServerNode?>(null);
