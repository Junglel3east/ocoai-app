import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for Academy lesson chat threads (last N turns sent to /chat).
abstract final class OracleAcademyStore {
  static const _prefix = 'oco_academy_chat_v1_';
  static const maxTurns = 20;

  static Future<List<Map<String, String>>> loadThread(String lessonId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$lessonId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => {
                'role': (e['role'] ?? '').toString(),
                'text': (e['text'] ?? e['content'] ?? '').toString(),
              })
          .where((m) => m['role']!.isNotEmpty && m['text']!.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveThread(String lessonId, List<Map<String, String>> messages) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = messages.length > maxTurns + 1
        ? messages.sublist(messages.length - (maxTurns + 1))
        : messages;
    await prefs.setString('$_prefix$lessonId', jsonEncode(trimmed));
  }

  static Future<void> clearThread(String lessonId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$lessonId');
  }
}
