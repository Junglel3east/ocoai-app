import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

/// Local persistence + backend ingest for Home "Daily Analysis" (BTC, ETH, SOL).
abstract final class DailyAnalysisStore {
  static const _boxName = 'oco_daily_analysis';
  static const _byDayKey = 'analyses_by_day';

  static const List<String> dailyCoins = ['BTC', 'ETH', 'SOL'];

  static Box<dynamic>? _box;

  static Future<void> init() async {
    if (_box != null && _box!.isOpen) return;
    _box = await Hive.openBox(_boxName);
  }

  /// Calendar day key (local timezone) — matches MainScreen retention.
  static String dayKey([DateTime? dt]) {
    final local = (dt ?? DateTime.now()).toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  static Map<String, List<Map<String, dynamic>>> _loadAllDays() {
    final raw = _box?.get(_byDayKey);
    if (raw is! Map) return {};
    final out = <String, List<Map<String, dynamic>>>{};
    raw.forEach((key, value) {
      if (value is! List) return;
      out[key.toString()] = value
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ))
          .where((m) => m['coin'] != null)
          .toList();
    });
    return out;
  }

  static Future<void> _saveAllDays(Map<String, List<Map<String, dynamic>>> data) async {
    try {
      await _box?.put(_byDayKey, data);
    } catch (e) {
      debugPrint('[DailyAnalysisStore] save failed: $e');
    }
  }

  /// Latest row per coin for [dayKey] (defaults to today).
  static Map<String, Map<String, dynamic>> loadTodayByCoin({String? day}) {
    final key = day ?? dayKey();
    final rows = _loadAllDays()[key] ?? const [];
    final map = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final coin = _normalizeCoin(row['coin']?.toString());
      if (coin == null) continue;
      map[coin] = row;
    }
    return map;
  }

  /// BTC → ETH → SOL, then any other coins saved today.
  static List<Map<String, dynamic>> loadTodayOrdered({String? day}) {
    final byCoin = loadTodayByCoin(day: day);
    final ordered = <Map<String, dynamic>>[];
    for (final coin in dailyCoins) {
      final row = byCoin[coin];
      if (row != null) ordered.add(row);
    }
    for (final entry in byCoin.entries) {
      if (!dailyCoins.contains(entry.key)) ordered.add(entry.value);
    }
    return ordered;
  }

  static Future<Map<String, dynamic>> upsert({
    required String coin,
    required String report,
    String? bias,
    dynamic confidence,
    Map<String, dynamic>? keyLevels,
    String ingestSource = 'local',
    DateTime? at,
  }) async {
    await init();
    final now = at ?? DateTime.now();
    final dk = dayKey(now);
    final normalized = _normalizeCoin(coin) ?? coin.toUpperCase();
    final entry = <String, dynamic>{
      'id': '${dk}_$normalized',
      'coin': normalized,
      'report': report,
      'bias': bias ?? '',
      'confidence': confidence,
      'key_levels': keyLevels,
      'time': _formatTime(now),
      'source': 'analysis',
      'analysisDay': dk,
      'ingestSource': ingestSource,
      'updatedAt': now.toIso8601String(),
    };

    final all = _loadAllDays();
    final dayRows = List<Map<String, dynamic>>.from(all[dk] ?? const []);
    dayRows.removeWhere((r) => _normalizeCoin(r['coin']?.toString()) == normalized);
    dayRows.insert(0, entry);
    all[dk] = dayRows;
    await _saveAllDays(all);
    return entry;
  }

  static Future<List<Map<String, dynamic>>> upsertMany(
    Iterable<Map<String, dynamic>> items, {
    String ingestSource = 'backend',
  }) async {
    for (final raw in items) {
      final coin = raw['coin']?.toString();
      final report = (raw['report'] ?? raw['analysis'] ?? raw['text'])?.toString() ?? '';
      if (coin == null || report.trim().isEmpty) continue;
      await upsert(
        coin: coin,
        report: report,
        bias: raw['bias']?.toString() ?? raw['direction']?.toString(),
        confidence: raw['confidence'] ?? raw['confidence_percent'],
        keyLevels: raw['key_levels'] is Map
            ? Map<String, dynamic>.from(raw['key_levels'] as Map)
            : raw['keyLevels'] is Map
                ? Map<String, dynamic>.from(raw['keyLevels'] as Map)
                : null,
        ingestSource: ingestSource,
      );
    }
    return loadTodayOrdered();
  }

  /// FCM / local notification payload (single coin or batch).
  static Future<List<Map<String, dynamic>>> ingestNotificationPayload(
    Map<String, dynamic> data,
  ) async {
    await init();
    final batch = data['analyses'];
    if (batch is List) {
      final items = batch.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      return upsertMany(items, ingestSource: 'push');
    }

    final report = (data['report'] ?? data['analysis'] ?? data['body'])?.toString();
    final coin = data['coin']?.toString();
    if (coin != null && report != null && report.trim().isNotEmpty) {
      await upsert(
        coin: coin,
        report: report,
        bias: data['bias']?.toString(),
        confidence: data['confidence'],
        ingestSource: 'push',
      );
      return loadTodayOrdered();
    }
    return loadTodayOrdered();
  }

  /// GET /daily_analyses (and /api alias) — no-op if endpoint missing.
  static Future<List<Map<String, dynamic>>> fetchAndPersistFromBackend(
    String baseUrl,
  ) async {
    await init();
    final root = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    for (final path in ['/daily_analyses', '/api/daily_analyses']) {
      try {
        final response = await http.get(Uri.parse('$root$path')).timeout(const Duration(seconds: 25));
        if (response.statusCode != 200) continue;
        final decoded = jsonDecode(response.body);
        final items = _extractAnalysesList(decoded);
        if (items.isNotEmpty) {
          return upsertMany(items, ingestSource: 'backend');
        }
      } catch (e) {
        debugPrint('[DailyAnalysisStore] fetch $path failed: $e');
      }
    }
    return loadTodayOrdered();
  }

  static List<Map<String, dynamic>> _extractAnalysesList(dynamic decoded) {
    if (decoded is List) {
      return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (decoded is! Map) return const [];

    final map = Map<String, dynamic>.from(decoded);
    final candidates = [
      map['analyses'],
      map['daily_analyses'],
      map['items'],
      map['data'] is Map ? (map['data'] as Map)['analyses'] : null,
    ];
    for (final c in candidates) {
      if (c is List) {
        return c.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }
    return const [];
  }

  /// Merge today's daily rows into Home history (newest-first, one row per coin).
  static List<Map<String, dynamic>> mergeIntoHistory(List<Map<String, dynamic>> history) {
    final today = dayKey();
    final daily = loadTodayOrdered(day: today);
    if (daily.isEmpty) return history;

    final out = List<Map<String, dynamic>>.from(history);
    out.removeWhere((item) {
      if (item['source'] != 'analysis') return false;
      return item['analysisDay']?.toString() == today;
    });

    for (var i = daily.length - 1; i >= 0; i--) {
      out.insert(0, Map<String, dynamic>.from(daily[i]));
    }
    return out;
  }

  static Future<void> clearToday() async {
    await init();
    final all = _loadAllDays();
    all.remove(dayKey());
    await _saveAllDays(all);
  }

  static Future<void> removeCoin(String coin) async {
    await init();
    final normalized = _normalizeCoin(coin);
    if (normalized == null) return;
    final dk = dayKey();
    final all = _loadAllDays();
    final dayRows = List<Map<String, dynamic>>.from(all[dk] ?? const []);
    dayRows.removeWhere((r) => _normalizeCoin(r['coin']?.toString()) == normalized);
    all[dk] = dayRows;
    await _saveAllDays(all);
  }

  static String? _normalizeCoin(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final upper = raw.trim().toUpperCase();
    if (upper.endsWith('USDT')) return upper.substring(0, upper.length - 4);
    if (upper.endsWith('USD')) return upper.substring(0, upper.length - 3);
    return upper;
  }

  static String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.month}/${local.day} ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
  }
}
