import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_api_key_service.dart';
import 'citadel_positions_service.dart';
import 'notification_service.dart';
import 'position_sizing.dart';
import 'user_profile_store.dart';

enum OracleAlertKind { guardian, price, pulse, citadel }

enum OracleAlertStatus { armed, triggered, muted }

class OracleAlert {
  final String id;
  final OracleAlertKind kind;
  final String coin;
  final String level; // entry, approach, sl, tp1, tp2, custom, bias, nearStop, fill
  final String title;
  final String body;
  final OracleAlertStatus status;
  final double? targetPrice;
  final bool above;
  final String? tradeId;
  final DateTime createdAt;
  final DateTime? firedAt;

  const OracleAlert({
    required this.id,
    required this.kind,
    required this.coin,
    required this.level,
    required this.title,
    required this.body,
    required this.status,
    this.targetPrice,
    this.above = true,
    this.tradeId,
    required this.createdAt,
    this.firedAt,
  });

  OracleAlert copyWith({
    OracleAlertStatus? status,
    DateTime? firedAt,
    String? title,
    String? body,
  }) {
    return OracleAlert(
      id: id,
      kind: kind,
      coin: coin,
      level: level,
      title: title ?? this.title,
      body: body ?? this.body,
      status: status ?? this.status,
      targetPrice: targetPrice,
      above: above,
      tradeId: tradeId,
      createdAt: createdAt,
      firedAt: firedAt ?? this.firedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'coin': coin,
        'level': level,
        'title': title,
        'body': body,
        'status': status.name,
        'targetPrice': targetPrice,
        'above': above,
        'tradeId': tradeId,
        'createdAt': createdAt.toIso8601String(),
        'firedAt': firedAt?.toIso8601String(),
      };

  factory OracleAlert.fromJson(Map<String, dynamic> json) {
    OracleAlertKind kind;
    try {
      kind = OracleAlertKind.values.byName(json['kind']?.toString() ?? 'price');
    } catch (_) {
      kind = OracleAlertKind.price;
    }
    OracleAlertStatus status;
    try {
      status = OracleAlertStatus.values.byName(json['status']?.toString() ?? 'armed');
    } catch (_) {
      status = OracleAlertStatus.armed;
    }
    return OracleAlert(
      id: json['id']?.toString() ?? '',
      kind: kind,
      coin: (json['coin'] ?? 'BTC').toString().toUpperCase(),
      level: json['level']?.toString() ?? 'custom',
      title: json['title']?.toString() ?? 'Alert',
      body: json['body']?.toString() ?? '',
      status: status,
      targetPrice: (json['targetPrice'] is num) ? (json['targetPrice'] as num).toDouble() : double.tryParse('${json['targetPrice']}'),
      above: json['above'] != false,
      tradeId: json['tradeId']?.toString(),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(),
      firedAt: DateTime.tryParse(json['firedAt']?.toString() ?? ''),
    );
  }
}

class AlertTierPolicy {
  final int maxCustomPrice;
  final bool pulse;
  final bool citadel;

  const AlertTierPolicy({
    required this.maxCustomPrice,
    required this.pulse,
    required this.citadel,
  });

  static const free = AlertTierPolicy(maxCustomPrice: 1, pulse: false, citadel: false);
  static const premium = AlertTierPolicy(maxCustomPrice: 10, pulse: true, citadel: false);
  static const expert = AlertTierPolicy(maxCustomPrice: 25, pulse: true, citadel: true);
}

/// Persisted custom price alerts, mutes, fired keys, last bias.
abstract final class OracleAlertStore {
  static const _alertsKey = 'oco_oracle_alerts_v2';
  static const _firedKey = 'oco_oracle_alert_fired_v2';
  static const _muteAllKey = 'oco_alert_mute_all';
  static const _muteSetupKey = 'oco_alert_mute_setup';
  static const _mutePulseKey = 'oco_alert_mute_pulse';
  static const _muteCitadelKey = 'oco_alert_mute_citadel';
  static const _mutePriceKey = 'oco_alert_mute_price';
  static const _biasKey = 'oco_alert_last_bias';
  static const _biasAtKey = 'oco_alert_last_bias_at';

  static final ValueNotifier<int> triggeredCount = ValueNotifier<int>(0);
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static List<OracleAlert> custom = [];
  static Set<String> fired = {};
  static bool muteAll = false;
  static bool muteSetup = false;
  static bool mutePulse = false;
  static bool muteCitadel = false;
  static bool mutePrice = false;
  static String? lastBias;
  static DateTime? lastBiasAt;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    muteAll = prefs.getBool(_muteAllKey) ?? false;
    muteSetup = prefs.getBool(_muteSetupKey) ?? false;
    mutePulse = prefs.getBool(_mutePulseKey) ?? false;
    muteCitadel = prefs.getBool(_muteCitadelKey) ?? false;
    mutePrice = prefs.getBool(_mutePriceKey) ?? false;
    lastBias = prefs.getString(_biasKey);
    lastBiasAt = DateTime.tryParse(prefs.getString(_biasAtKey) ?? '');
    fired = (prefs.getStringList(_firedKey) ?? const []).toSet();
    final raw = prefs.getString(_alertsKey);
    if (raw == null || raw.isEmpty) {
      custom = [];
    } else {
      try {
        custom = (jsonDecode(raw) as List<dynamic>)
            .whereType<Map<String, dynamic>>()
            .map(OracleAlert.fromJson)
            .toList();
      } catch (_) {
        custom = [];
      }
    }
    _recount();
  }

  static Future<void> _persistAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_alertsKey, jsonEncode(custom.map((a) => a.toJson()).toList()));
    _bump();
  }

  static Future<void> _persistFired() async {
    final prefs = await SharedPreferences.getInstance();
    final list = fired.toList();
    if (list.length > 400) {
      fired = list.sublist(list.length - 300).toSet();
    }
    await prefs.setStringList(_firedKey, fired.toList());
  }

  static Future<void> saveMutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_muteAllKey, muteAll);
    await prefs.setBool(_muteSetupKey, muteSetup);
    await prefs.setBool(_mutePulseKey, mutePulse);
    await prefs.setBool(_muteCitadelKey, muteCitadel);
    await prefs.setBool(_mutePriceKey, mutePrice);
    _bump();
  }

  static Future<void> saveBias(String bias) async {
    lastBias = bias;
    lastBiasAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_biasKey, bias);
    await prefs.setString(_biasAtKey, lastBiasAt!.toIso8601String());
  }

  static Future<void> addCustom(OracleAlert alert) async {
    custom.insert(0, alert);
    await _persistAlerts();
  }

  static Future<void> updateCustom(OracleAlert alert) async {
    final i = custom.indexWhere((a) => a.id == alert.id);
    if (i == -1) return;
    custom[i] = alert;
    await _persistAlerts();
  }

  static Future<void> removeCustom(String id) async {
    custom.removeWhere((a) => a.id == id);
    await _persistAlerts();
  }

  static Future<void> markFired(String key) async {
    fired.add(key);
    await _persistFired();
  }

  static bool wasFired(String key) => fired.contains(key);

  static void _recount() {
    final n = custom.where((a) => a.status == OracleAlertStatus.triggered).length;
    if (triggeredCount.value != n) triggeredCount.value = n;
  }

  static void _bump() {
    _recount();
    revision.value++;
  }
}

/// Watches setup levels, custom prices, desk bias, and Citadel risk using free Binance prices.
class OracleAlertEngine {
  OracleAlertEngine._();
  static final OracleAlertEngine instance = OracleAlertEngine._();

  static const _backend = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );

  AlertTierPolicy policy = AlertTierPolicy.free;
  Timer? _timer;
  bool _ticking = false;
  DateTime? _lastSync;
  List<Map<String, dynamic>> _trades = const [];
  List<CitadelLivePosition> _positions = const [];
  Set<String> _lastPositionIds = {};

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 18), (_) => tick());
    unawaited(tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void bindTrades(List<Map<String, dynamic>> trades) {
    _trades = trades;
  }

  void bindPositions(List<CitadelLivePosition> positions) {
    _positions = positions;
  }

  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await OracleAlertStore.load();
      if (OracleAlertStore.muteAll) return;
      final coins = <String>{};
      for (final t in _openTrades()) {
        final c = (t['coin'] ?? '').toString().trim().toUpperCase();
        if (c.isNotEmpty) coins.add(c);
      }
      for (final a in OracleAlertStore.custom) {
        if (a.status == OracleAlertStatus.armed) coins.add(a.coin);
      }
      for (final p in _positions) {
        if (p.coin.isNotEmpty) coins.add(p.coin);
      }
      if (coins.isEmpty) {
        await _maybeSyncBackend(const {});
        return;
      }
      final prices = await fetchPrices(coins.toList());
      if (prices.isEmpty) return;
      if (!OracleAlertStore.muteSetup) {
        await _evalGuardians(prices);
      }
      if (!OracleAlertStore.mutePrice) {
        await _evalCustom(prices);
      }
      if (policy.citadel && !OracleAlertStore.muteCitadel) {
        await _evalCitadel(prices);
      }
      await _maybeSyncBackend(prices);
    } catch (e) {
      debugPrint('[AlertEngine] tick failed: $e');
    } finally {
      _ticking = false;
    }
  }

  List<Map<String, dynamic>> _openTrades() {
    return _trades.where((t) => (t['status'] ?? '').toString() == 'Open').toList();
  }

  Future<void> _evalGuardians(Map<String, double> prices) async {
    for (final trade in _openTrades()) {
      final coin = (trade['coin'] ?? '').toString().trim().toUpperCase();
      final price = prices[coin];
      if (coin.isEmpty || price == null) continue;
      final entry = _d(trade['entry']);
      final sl = _d(trade['sl']);
      final tp1 = _d(trade['tp1']);
      final tp2 = _d(trade['tp2']);
      if (entry == null || sl == null) continue;
      final long = _isLong(trade);
      final id = '${trade['id']}';

      Future<void> fire(String level, String title, String body) async {
        final key = 'g:$id:$level';
        if (OracleAlertStore.wasFired(key)) return;
        if (_quietHours && level != 'sl') return;
        await OracleAlertStore.markFired(key);
        await _notify(
          kind: OracleAlertKind.guardian,
          coin: coin,
          title: title,
          body: body,
          tradeId: id,
          level: level,
        );
      }

      final band = entry.abs() * 0.0015;
      final approach = entry.abs() * 0.004;
      if ((price - entry).abs() <= approach && (price - entry).abs() > band) {
        await fire(
          'approach',
          '$coin approaching entry',
          _setupCopy(trade, price, 'Price is near entry ${PositionSizing.formatUsd(entry)}.'),
        );
      }
      if ((price - entry).abs() <= band) {
        await fire(
          'entry',
          '$coin at entry',
          _setupCopy(trade, price, 'Entry ${PositionSizing.formatUsd(entry)} touched.'),
        );
      }
      if (sl > 0 && ((long && price <= sl) || (!long && price >= sl))) {
        await fire(
          'sl',
          '$coin stop touched',
          _setupCopy(trade, price, 'Stop ${PositionSizing.formatUsd(sl)} hit. Close the setup to log the exit.'),
        );
      }
      if (tp1 != null && ((long && price >= tp1) || (!long && price <= tp1))) {
        await fire(
          'tp1',
          '$coin TP1 hit',
          _setupCopy(trade, price, 'TP1 ${PositionSizing.formatUsd(tp1)} reached.'),
        );
      }
      if (tp2 != null && ((long && price >= tp2) || (!long && price <= tp2))) {
        await fire(
          'tp2',
          '$coin TP2 hit',
          _setupCopy(trade, price, 'TP2 ${PositionSizing.formatUsd(tp2)} reached.'),
        );
      }
    }
  }

  String _setupCopy(Map<String, dynamic> trade, double price, String lead) {
    final capital = StartingCapitalStore.capitalUsd;
    final risk = _d(trade['riskPercent']) ?? 1.0;
    final lev = _d(trade['leverage']) ?? 5.0;
    final dir = _isLong(trade) ? 'long' : 'short';
    return '$lead ${trade['coin']} $dir · ${PositionSizing.formulaLine(capital: capital, riskPercent: risk, leverage: lev)} → '
        '${PositionSizing.breakdownLine(capital: capital, riskPercent: risk, leverage: lev, entry: _d(trade['entry']), sl: _d(trade['sl']))}';
  }

  Future<void> _evalCustom(Map<String, double> prices) async {
    for (var i = 0; i < OracleAlertStore.custom.length; i++) {
      final alert = OracleAlertStore.custom[i];
      if (alert.status != OracleAlertStatus.armed || alert.targetPrice == null) continue;
      final price = prices[alert.coin];
      if (price == null) continue;
      final hit = alert.above ? price >= alert.targetPrice! : price <= alert.targetPrice!;
      if (!hit) continue;
      final key = 'p:${alert.id}';
      if (OracleAlertStore.wasFired(key)) continue;
      if (_quietHours) continue;
      await OracleAlertStore.markFired(key);
      final next = alert.copyWith(
        status: OracleAlertStatus.triggered,
        firedAt: DateTime.now(),
        body: '${alert.coin} ${alert.above ? '≥' : '≤'} ${PositionSizing.formatUsd(alert.targetPrice!)} (now ${PositionSizing.formatUsd(price)})',
      );
      await OracleAlertStore.updateCustom(next);
      await _notify(
        kind: OracleAlertKind.price,
        coin: alert.coin,
        title: '${alert.coin} price alert',
        body: next.body,
        level: 'custom',
      );
    }
  }

  Future<void> _evalCitadel(Map<String, double> prices) async {
    final nowIds = _positions.map((p) => p.positionId).where((id) => id.isNotEmpty).toSet();
    if (_lastPositionIds.isNotEmpty) {
      for (final p in _positions) {
        if (p.positionId.isEmpty || _lastPositionIds.contains(p.positionId)) continue;
        final key = 'c:fill:${p.positionId}';
        if (OracleAlertStore.wasFired(key)) continue;
        await OracleAlertStore.markFired(key);
        await _notify(
          kind: OracleAlertKind.citadel,
          coin: p.coin,
          title: '${p.coin} Citadel fill',
          body: '${p.direction.toUpperCase()} filled near ${PositionSizing.formatUsd(p.entryPrice)} · ${p.leverage.round()}x',
          level: 'fill',
        );
      }
    }
    _lastPositionIds = nowIds;

    for (final p in _positions) {
      if (p.liquidationPrice <= 0 || p.markPrice <= 0) continue;
      final dist = (p.markPrice - p.liquidationPrice).abs() / p.markPrice;
      if (dist > 0.012) continue;
      final key = 'c:liq:${p.positionId}';
      if (OracleAlertStore.wasFired(key)) continue;
      await OracleAlertStore.markFired(key);
      await _notify(
        kind: OracleAlertKind.citadel,
        coin: p.coin,
        title: '${p.coin} near liquidation',
        body: 'Mark ${PositionSizing.formatUsd(p.markPrice)} is ${(dist * 100).toStringAsFixed(2)}% from liq ${PositionSizing.formatUsd(p.liquidationPrice)}.',
        level: 'nearStop',
      );
    }

    for (final trade in _openTrades()) {
      if ((trade['executedVia'] ?? '') != 'citadel') continue;
      final coin = (trade['coin'] ?? '').toString().toUpperCase();
      final sl = _d(trade['sl']);
      final entry = _d(trade['entry']);
      final price = prices[coin];
      if (sl == null || entry == null || price == null) continue;
      final risk = (entry - sl).abs();
      if (risk < 1e-12) continue;
      final toStop = _isLong(trade) ? (price - sl) : (sl - price);
      final remainR = toStop / risk;
      if (remainR > 0.35 || remainR < 0) continue;
      final key = 'c:r:${trade['id']}';
      if (OracleAlertStore.wasFired(key)) continue;
      await OracleAlertStore.markFired(key);
      await _notify(
        kind: OracleAlertKind.citadel,
        coin: coin,
        title: '$coin ${remainR.toStringAsFixed(2)}R from stop',
        body: _setupCopy(trade, price, 'Citadel position is close to the stop.'),
        tradeId: '${trade['id']}',
        level: 'nearStop',
      );
    }
  }

  Future<void> noteBias(String label) async {
    final prev = OracleAlertStore.lastBias;
    if (prev == label) return;
    await OracleAlertStore.saveBias(label);
    if (prev == null) return;
    if (!policy.pulse || OracleAlertStore.muteAll || OracleAlertStore.mutePulse) return;
    final key = 'bias:$prev->$label:${DateTime.now().toIso8601String().substring(0, 10)}';
    if (OracleAlertStore.wasFired(key) || _quietHours) return;
    await OracleAlertStore.markFired(key);
    await _notify(
      kind: OracleAlertKind.pulse,
      coin: 'BTC',
      title: 'Desk bias changed',
      body: 'Oracle bias moved from $prev to $label. Open the War Room.',
      level: 'bias',
    );
  }

  Future<void> _notify({
    required OracleAlertKind kind,
    required String coin,
    required String title,
    required String body,
    String? tradeId,
    required String level,
  }) async {
    OracleAlertStore.triggeredCount.value = OracleAlertStore.triggeredCount.value + 1;
    OracleAlertStore.revision.value++;
    await NotificationService.instance.showAlertHit(
      coin: coin,
      condition: '$title — $body',
      extra: {
        'kind': kind.name,
        'level': level,
        if (tradeId != null) 'tradeId': tradeId,
        'open': kind == OracleAlertKind.pulse ? 'desk' : 'alerts',
      },
    );
  }

  bool get _quietHours {
    final h = DateTime.now().hour;
    return h >= 22 || h < 7;
  }

  Future<Map<String, double>> fetchPrices(List<String> coins) async {
    final out = <String, double>{};
    if (coins.isEmpty) return out;
    try {
      final response = await http
          .get(
            Uri.parse('https://api.binance.com/api/v3/ticker/price'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body);
        if (list is List) {
          final want = {for (final c in coins) '${c}USDT': c};
          for (final raw in list) {
            if (raw is! Map) continue;
            final sym = raw['symbol']?.toString();
            final coin = want[sym];
            if (coin == null) continue;
            final p = double.tryParse(raw['price']?.toString() ?? '');
            if (p != null && p > 0) out[coin] = p;
          }
        }
      }
    } catch (e) {
      debugPrint('[AlertEngine] binance batch failed: $e');
    }
    for (final coin in coins) {
      if (out.containsKey(coin)) continue;
      try {
        final uri = Uri.parse('$_backend/live_price').replace(queryParameters: {'coin': coin});
        final response = await http.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body);
        if (data is Map) {
          final p = double.tryParse(data['price']?.toString() ?? data['live_price']?.toString() ?? '');
          if (p != null && p > 0) out[coin] = p;
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> _maybeSyncBackend(Map<String, double> prices) async {
    final now = DateTime.now();
    if (_lastSync != null && now.difference(_lastSync!) < const Duration(seconds: 45)) return;
    _lastSync = now;
    try {
      final token = await NotificationService.instance.fcmToken();
      if (token == null || token.isEmpty) return;
      final levels = <Map<String, dynamic>>[];
      for (final trade in _openTrades()) {
        final coin = (trade['coin'] ?? '').toString().toUpperCase();
        final entry = _d(trade['entry']);
        final sl = _d(trade['sl']);
        final tp1 = _d(trade['tp1']);
        if (coin.isEmpty || entry == null || sl == null) continue;
        final id = '${trade['id']}';
        levels.add({'id': 'g:$id:entry', 'coin': coin, 'price': entry, 'op': 'touch', 'kind': 'guardian'});
        levels.add({'id': 'g:$id:sl', 'coin': coin, 'price': sl, 'op': _isLong(trade) ? 'below' : 'above', 'kind': 'guardian'});
        if (tp1 != null) {
          levels.add({'id': 'g:$id:tp1', 'coin': coin, 'price': tp1, 'op': _isLong(trade) ? 'above' : 'below', 'kind': 'guardian'});
        }
      }
      for (final a in OracleAlertStore.custom.where((x) => x.status == OracleAlertStatus.armed && x.targetPrice != null)) {
        levels.add({
          'id': 'p:${a.id}',
          'coin': a.coin,
          'price': a.targetPrice,
          'op': a.above ? 'above' : 'below',
          'kind': 'price',
        });
      }
      if (levels.isEmpty) return;
      final headers = await AppApiKeyService.backendHeaders();
      await http
          .post(
            Uri.parse('$_backend/alerts/sync'),
            headers: headers,
            body: jsonEncode({
              'fcm_token': token,
              'levels': levels,
              'mute_all': OracleAlertStore.muteAll,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[AlertEngine] backend sync skipped: $e');
    }
  }

  static bool _isLong(Map<String, dynamic> trade) {
    final selected = (trade['direction'] ?? '').toString();
    if (selected == 'Long Only') return true;
    if (selected == 'Short Only') return false;
    final entry = _d(trade['entry']);
    final sl = _d(trade['sl']);
    if (entry != null && sl != null) return sl < entry;
    return true;
  }

  static double? _d(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '').trim());
  }
}
