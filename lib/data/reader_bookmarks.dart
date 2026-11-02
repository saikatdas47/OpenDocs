import 'package:shared_preferences/shared_preferences.dart';

class ReaderBookmarks {
  static Future<List<int>> load(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final pages =
        (prefs.getStringList('bookmarks:$key') ?? [])
            .map(int.tryParse)
            .whereType<int>()
            .where((p) => p > 0)
            .toSet()
            .toList()
          ..sort();
    return pages;
  }

  static Future<void> save(String key, Iterable<int> pages) async {
    final sorted = pages.where((p) => p > 0).toSet().toList()..sort();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setStringList(
      'bookmarks:$key',
      sorted.map((p) => '$p').toList(),
    )) {
      throw StateError('Could not save bookmarks');
    }
  }
}
