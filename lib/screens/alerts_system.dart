// Alerts: records, repository, store, editor.

part of '../main.dart';

// ==================== ALERTS SYSTEM ====================

class AlertRecord {
  final String id;
  final String coin;
  final String alertType;
  final String condition;
  final String value;
  final String timeframe;
  final String status;
  final String category;

  const AlertRecord({
    required this.id,
    required this.coin,
    required this.alertType,
    required this.condition,
    required this.value,
    required this.timeframe,
    required this.status,
    required this.category,
  });

  AlertRecord copyWith({
    String? id,
    String? coin,
    String? alertType,
    String? condition,
    String? value,
    String? timeframe,
    String? status,
    String? category,
  }) {
    return AlertRecord(
      id: id ?? this.id,
      coin: coin ?? this.coin,
      alertType: alertType ?? this.alertType,
      condition: condition ?? this.condition,
      value: value ?? this.value,
      timeframe: timeframe ?? this.timeframe,
      status: status ?? this.status,
      category: category ?? this.category,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'coin': coin,
        'alertType': alertType,
        'condition': condition,
        'value': value,
        'timeframe': timeframe,
        'status': status,
        'category': category,
      };

  factory AlertRecord.fromJson(Map<String, dynamic> json) => AlertRecord(
        id: json['id']?.toString() ?? '',
        coin: json['coin']?.toString() ?? 'BTC',
        alertType: json['alertType']?.toString() ?? 'Price',
        condition: json['condition']?.toString() ?? 'Above',
        value: json['value']?.toString() ?? '',
        timeframe: json['timeframe']?.toString() ?? '1h',
        status: json['status']?.toString() ?? 'Active',
        category: json['category']?.toString() ?? 'price',
      );

  bool get isAbove => condition == 'Above';

  String get directionSymbol => isAbove ? 'â†‘' : 'â†“';

  Color get directionColor => isAbove ? const Color(0xFF00E676) : const Color(0xFFFF5252);

  String get conditionLabel {
    switch (alertType) {
      case 'Price':
        final op = isAbove ? '>' : '<';
        return '$coin $op \$${_formatDisplayValue(value)}';
      case 'RSI':
        final op = isAbove ? '>' : '<';
        return 'RSI $op $value';
      case 'MACD':
        return isAbove ? 'MACD Bullish Cross' : 'MACD Bearish Cross';
      case 'Volume':
        return 'Volume ${isAbove ? '+' : '-'}$value%';
      case 'VWAP Cross':
        return isAbove ? 'VWAP Cross Above' : 'VWAP Cross Below';
      case 'News':
        return '$coin Breaking News Alert';
      default:
        return '$alertType ${isAbove ? 'Above' : 'Below'} $value';
    }
  }

  static String _formatDisplayValue(String raw) {
    final parsed = double.tryParse(raw.replaceAll(',', ''));
    if (parsed == null) return raw;
    if (parsed >= 1000) {
      return parsed.toStringAsFixed(0).replaceAllMapped(
            RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          );
    }
    return parsed.toString();
  }
}

class AlertsRepository {
  static const _storageKey = 'oco_alerts_v1';
  static List<AlertRecord>? _memoryCache;

  static List<AlertRecord> defaultAlerts() => [
        AlertRecord(
          id: 'seed_btc_price',
          coin: 'BTC',
          alertType: 'Price',
          condition: 'Above',
          value: '76500',
          timeframe: '1h',
          status: 'Active',
          category: 'price',
        ),
        AlertRecord(
          id: 'seed_eth_rsi',
          coin: 'ETH',
          alertType: 'RSI',
          condition: 'Below',
          value: '30',
          timeframe: '4h',
          status: 'Active',
          category: 'technical',
        ),
        AlertRecord(
          id: 'seed_sol_vol',
          coin: 'SOL',
          alertType: 'Volume',
          condition: 'Above',
          value: '25',
          timeframe: '1d',
          status: 'Triggered',
          category: 'technical',
        ),
        AlertRecord(
          id: 'seed_xrp_macd',
          coin: 'XRP',
          alertType: 'MACD',
          condition: 'Above',
          value: '0',
          timeframe: '1h',
          status: 'Active',
          category: 'technical',
        ),
        AlertRecord(
          id: 'seed_btc_news',
          coin: 'BTC',
          alertType: 'News',
          condition: 'Above',
          value: '0',
          timeframe: '1h',
          status: 'Active',
          category: 'news',
        ),
      ];

  static Future<List<AlertRecord>> load() async {
    if (_memoryCache != null) {
      return List<AlertRecord>.from(_memoryCache!);
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      final seeded = defaultAlerts();
      _memoryCache = List<AlertRecord>.from(seeded);
      await save(seeded);
      return List<AlertRecord>.from(_memoryCache!);
    }
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(AlertRecord.fromJson)
          .toList();
      _memoryCache = list.isEmpty ? defaultAlerts() : list;
      return List<AlertRecord>.from(_memoryCache!);
    } catch (_) {
      _memoryCache = defaultAlerts();
      return List<AlertRecord>.from(_memoryCache!);
    }
  }

  static Future<void> save(List<AlertRecord> alerts) async {
    _memoryCache = List<AlertRecord>.from(alerts);
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(alerts.map((a) => a.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }
}

/// In-memory alert store â€” list updates instantly; persists via [AlertsRepository].
class AlertsStore {
  AlertsStore._();
  static final AlertsStore instance = AlertsStore._();

  final List<AlertRecord> alerts = [];
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    alerts
      ..clear()
      ..addAll(await AlertsRepository.load());
    _loaded = true;
  }

  void add(AlertRecord alert) {
    alerts.insert(0, alert);
    unawaited(AlertsRepository.save(List.from(alerts)));
  }

  void update(AlertRecord alert) {
    final index = alerts.indexWhere((a) => a.id == alert.id);
    if (index == -1) return;
    alerts[index] = alert;
    unawaited(AlertsRepository.save(List.from(alerts)));
  }

  void remove(String id) {
    alerts.removeWhere((a) => a.id == id);
    unawaited(AlertsRepository.save(List.from(alerts)));
  }

  void replaceAt(int index, AlertRecord alert) {
    if (index < 0 || index >= alerts.length) return;
    alerts[index] = alert;
    unawaited(AlertsRepository.save(List.from(alerts)));
  }
}
