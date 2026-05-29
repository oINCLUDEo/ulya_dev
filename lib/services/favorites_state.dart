import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefKey = 'favorite_server_uuids';

final ValueNotifier<Set<String>> favoritesNotifier =
    ValueNotifier<Set<String>>({});

Future<void> loadFavorites() async {
  final prefs = await SharedPreferences.getInstance();
  final list = prefs.getStringList(_prefKey) ?? [];
  favoritesNotifier.value = Set<String>.from(list);
}

Future<void> toggleFavorite(String uuid) async {
  final current = Set<String>.from(favoritesNotifier.value);
  if (current.contains(uuid)) {
    current.remove(uuid);
  } else {
    current.add(uuid);
  }
  favoritesNotifier.value = current;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(_prefKey, current.toList());
}
