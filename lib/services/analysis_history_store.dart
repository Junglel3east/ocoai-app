import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Local persistence for Home "Recent Analyses" (analyses + trade setup reports).
///
/// Uses Hive — survives full app restarts. Initialized in [main] via [init].
abstract final class AnalysisHistoryStore {
  static const _boxName = 'oco_analysis_history';
  static const _historyKey = 'history_items';
  static const _tradesKey = 'trade_items';

  static Box<dynamic>? _box;

  /// Call once before [runApp] (see main.dart).
  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox(_boxName);
  }

  static List<Map<String, dynamic>> loadHistory() {
    final raw = _box?.get(_historyKey);
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => _deepStringKeyMap(e))
        .where((m) => m['id'] != null)
        .toList();
  }

  static List<Map<String, dynamic>> loadTrades() {
    final raw = _box?.get(_tradesKey);
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => _deepStringKeyMap(e))
        .where((m) => m['id'] != null)
        .toList();
  }

  /// Persists analyses + trade setup history rows (newest-first list).
  static Future<void> saveHistory(List<Map<String, dynamic>> items) async {
    try {
      await _box?.put(_historyKey, items.map(_toHiveMap).toList());
    } catch (e) {
      debugPrint('[AnalysisHistoryStore] saveHistory failed: $e');
    }
  }

  /// Persists open/closed trades linked to trade setup history.
  static Future<void> saveTrades(List<Map<String, dynamic>> items) async {
    try {
      await _box?.put(_tradesKey, items.map(_toHiveMap).toList());
    } catch (e) {
      debugPrint('[AnalysisHistoryStore] saveTrades failed: $e');
    }
  }

  static Future<void> clearHistory() async {
    await _box?.delete(_historyKey);
  }

  static Future<void> clearTrades() async {
    await _box?.delete(_tradesKey);
  }

  static Map<String, dynamic> _deepStringKeyMap(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) => MapEntry(key.toString(), _fromHiveValue(value)));
  }

  static Map<dynamic, dynamic> _toHiveMap(Map<String, dynamic> map) {
    return map.map((key, value) => MapEntry(key, _toHiveValue(value)));
  }

  static dynamic _toHiveValue(dynamic value) {
    if (value is Map<String, dynamic>) return _toHiveMap(value);
    if (value is Map) return _toHiveMap(Map<String, dynamic>.from(value));
    if (value is List) return value.map(_toHiveValue).toList();
    return value;
  }

  static dynamic _fromHiveValue(dynamic value) {
    if (value is Map) return _deepStringKeyMap(value);
    if (value is List) return value.map(_fromHiveValue).toList();
    return value;
  }
}
