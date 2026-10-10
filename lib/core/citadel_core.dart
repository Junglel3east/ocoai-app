// Oracle Citadel: stores, service, order flow, execution dialogs.

part of '../main.dart';

abstract final class OracleCitadelStore {
  static const _userIdKey = 'citadel_user_id';
  static const _apiKeyKey = 'citadel_api_key';
  static const _riskPercentKey = 'citadel_risk_percent';
  static const _leverageKey = 'citadel_leverage';
  static const _demoModeKey = 'citadel_use_demo_mode';
  static const _selectedExchangeKey = 'citadel_selected_exchange';
  static const _paperModeKey = 'citadel_paper_mode';

  static String userId = 'demo_user';
  /// Paper mode routes "Send to Oracle Citadel" to graded paper trades instead of the exchange.
  static bool paperMode = false;
  /// Server-side kill switch; refreshed from `/exchange_keys/status`.
  static bool serverPaused = false;
  static String apiKey = '';
  static double defaultRiskPercent = 1.0;
  static double defaultLeverage = 5.0;
  /// BloFin Demo is the default — demo API keys only work against the demo host.
  static bool useDemoMode = true;
  /// Connected exchange: `blofin` or `bitunix`.
  static String selectedExchange = 'blofin';

  static bool get isConfigured => userId.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    userId = prefs.getString(_userIdKey) ?? 'demo_user';
    apiKey = prefs.getString(_apiKeyKey) ?? '';
    final secureKey = await AppApiKeyService.getKey();
    if (secureKey != null && secureKey.isNotEmpty) {
      apiKey = secureKey;
    }
    defaultRiskPercent = prefs.getDouble(_riskPercentKey) ?? 1.0;
    if (defaultRiskPercent < 1.0) defaultRiskPercent = 1.0;
    if (defaultRiskPercent > 100.0) defaultRiskPercent = 100.0;
    defaultLeverage = prefs.getDouble(_leverageKey) ?? 5.0;
    if (defaultLeverage < 1) defaultLeverage = 1;
    if (defaultLeverage > 100) defaultLeverage = 100;
    useDemoMode = prefs.getBool(_demoModeKey) ?? true;
    selectedExchange = prefs.getString(_selectedExchangeKey) ?? 'blofin';
    if (selectedExchange != 'bitunix') selectedExchange = 'blofin';
    useDemoMode = _demoModeForExchange(selectedExchange);
    paperMode = prefs.getBool(_paperModeKey) ?? false;
  }

  static Future<void> savePaperMode(bool enabled) async {
    paperMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_paperModeKey, enabled);
  }

  /// Mode is dictated by the exchange: BloFin = demo-only, Bitunix = live-only.
  static bool _demoModeForExchange(String exchange) => exchange != 'bitunix';

  static String get exchangeDisplayLabel {
    if (selectedExchange == 'bitunix') return 'Bitunix Live';
    return 'BloFin Demo';
  }

  static String get exchangeBrandName =>
      selectedExchange == 'bitunix' ? 'Bitunix' : 'BloFin';

  /// MainScreen stamps the size the user actually sent on MARKET / LIMIT.
  static void Function({
    required String coin,
    required double leverage,
    required double riskPercent,
  })? onOrderSized;

  static Future<void> saveSelectedExchange(String exchange) async {
    selectedExchange = exchange == 'bitunix' ? 'bitunix' : 'blofin';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedExchangeKey, selectedExchange);
    useDemoMode = _demoModeForExchange(selectedExchange);
    await prefs.setBool(_demoModeKey, useDemoMode);
  }

  static Future<void> saveDemoMode(bool enabled) async {
    // Exchange dictates mode (BloFin demo-only, Bitunix live-only) —
    // coerce so no caller can put BloFin in live or Bitunix in demo.
    useDemoMode = _demoModeForExchange(selectedExchange);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_demoModeKey, useDemoMode);
  }

  static Future<void> saveLeverage(double leverage) async {
    defaultLeverage = leverage.clamp(1.0, 100.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_leverageKey, defaultLeverage);
  }

  static Future<void> saveRiskPercent(double riskPercent) async {
    defaultRiskPercent = riskPercent.clamp(1.0, 100.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_riskPercentKey, defaultRiskPercent);
  }

  static Future<bool> isBlofinLinked() async {
    if (!isConfigured) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('citadel_exchange_linked') ?? false;
  }

  static Future<void> clearExchangeLinked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('citadel_exchange_linked', false);
  }

  static Future<void> markExchangeLinked(bool linked) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('citadel_exchange_linked', linked);
  }

  static Future<void> save({
    required String userId,
    required String apiKey,
    double? riskPercent,
  }) async {
    OracleCitadelStore.userId = userId.trim();
    OracleCitadelStore.apiKey = apiKey.trim();
    if (riskPercent != null) defaultRiskPercent = riskPercent;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, OracleCitadelStore.userId);
    await prefs.setString(_apiKeyKey, OracleCitadelStore.apiKey);
    await prefs.setDouble(_riskPercentKey, defaultRiskPercent);
    await prefs.setDouble(_leverageKey, defaultLeverage);
  }
}

/// Last trade setup with complete Citadel levels — survives Citadel connect on another tab.
class CitadelPendingTrade {
  final String coin;
  final String directionLabel;
  final String reportText;
  final double entry;
  final double stopLoss;
  final double tp1;
  final double tp2;
  final DateTime savedAt;

  const CitadelPendingTrade({
    required this.coin,
    required this.directionLabel,
    required this.reportText,
    required this.entry,
    required this.stopLoss,
    required this.tp1,
    required this.tp2,
    required this.savedAt,
  });

  String get direction => citadelDirectionFromSetup(directionLabel, entry, stopLoss);
}

abstract final class CitadelPendingTradeStore {
  static const _coinKey = 'citadel_pending_coin';
  static const _directionKey = 'citadel_pending_direction';
  static const _reportKey = 'citadel_pending_report';
  static const _entryKey = 'citadel_pending_entry';
  static const _slKey = 'citadel_pending_sl';
  static const _tp1Key = 'citadel_pending_tp1';
  static const _tp2Key = 'citadel_pending_tp2';
  static const _savedAtKey = 'citadel_pending_saved_at';

  static Future<void> save({
    required String coin,
    required String directionLabel,
    required String reportText,
    required double entry,
    required double stopLoss,
    required double tp1,
    required double tp2,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_coinKey, coin.trim().toUpperCase());
    await prefs.setString(_directionKey, directionLabel);
    await prefs.setString(_reportKey, reportText);
    await prefs.setDouble(_entryKey, entry);
    await prefs.setDouble(_slKey, stopLoss);
    await prefs.setDouble(_tp1Key, tp1);
    await prefs.setDouble(_tp2Key, tp2);
    await prefs.setString(_savedAtKey, DateTime.now().toIso8601String());
  }

  static Future<CitadelPendingTrade?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final coin = prefs.getString(_coinKey);
    final entry = prefs.getDouble(_entryKey);
    final sl = prefs.getDouble(_slKey);
    final tp1 = prefs.getDouble(_tp1Key);
    final tp2 = prefs.getDouble(_tp2Key);
    if (coin == null || entry == null || sl == null || tp1 == null || tp2 == null) {
      return null;
    }
    final savedAt = DateTime.tryParse(prefs.getString(_savedAtKey) ?? '') ?? DateTime.now();
    return CitadelPendingTrade(
      coin: coin,
      directionLabel: prefs.getString(_directionKey) ?? 'Smart Direction',
      reportText: prefs.getString(_reportKey) ?? '',
      entry: entry,
      stopLoss: sl,
      tp1: tp1,
      tp2: tp2,
      savedAt: savedAt,
    );
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_coinKey);
    await prefs.remove(_directionKey);
    await prefs.remove(_reportKey);
    await prefs.remove(_entryKey);
    await prefs.remove(_slKey);
    await prefs.remove(_tp1Key);
    await prefs.remove(_tp2Key);
    await prefs.remove(_savedAtKey);
  }
}

class OracleCitadelException implements Exception {
  final String userMessage;
  final String? errorCode;

  const OracleCitadelException(this.userMessage, {this.errorCode});

  @override
  String toString() => userMessage;
}

class CitadelServerLinkStatus {
  final bool linked;
  final String? userMessage;
  final String? errorCode;

  const CitadelServerLinkStatus({
    required this.linked,
    this.userMessage,
    this.errorCode,
  });
}

/// Optional Citadel user id + trading venue for analyze/chat/review.
Map<String, dynamic> _analyzeCitadelContext() {
  return {
    if (OracleCitadelStore.isConfigured) 'user_id': OracleCitadelStore.userId,
    ...TradingVenueStore.analyzePayloadFields(),
  };
}

Future<Map<String, dynamic>> _analyzeFluxFields(String coin, String timeframe) async {
  final flux = await OracleFluxReadService.latestFor(
    coin: coin,
    timeframe: timeframe,
    backendBaseUrl: kBackendBaseUrl,
  );
  if (flux == null) return const {};
  return {'oracle_flux': flux, 'chart_context': {'oracle_flux': flux}};
}

abstract final class OracleLivePriceService {
  static Future<Map<String, dynamic>?> fetch(String coin) async {
    final upper = coin.trim().toUpperCase();
    if (upper.isEmpty) return null;
    final params = <String, String>{'coin': upper};
    if (OracleCitadelStore.isConfigured) {
      params['user_id'] = OracleCitadelStore.userId;
    }
    final uri = Uri.parse('$kBackendBaseUrl/live_price').replace(queryParameters: params);
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || data['success'] != true) return null;
      final price = (data['price'] as num?)?.toDouble();
      if (price == null || price <= 0) return null;
      return data;
    } catch (_) {
      return null;
    }
  }
}

/// Compact live price row — shows BloFin label when backend source is BloFin.
class OracleLivePriceStrip extends StatefulWidget {
  final String coin;

  const OracleLivePriceStrip({super.key, required this.coin});

  @override
  State<OracleLivePriceStrip> createState() => _OracleLivePriceStripState();
}

class _OracleLivePriceStripState extends State<OracleLivePriceStrip> {
  Map<String, dynamic>? _quote;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OracleLivePriceStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coin != widget.coin) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await OracleLivePriceService.fetch(widget.coin);
    if (!mounted) return;
    setState(() {
      _quote = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _quote == null) {
      return const SizedBox(height: 22);
    }
    final price = (_quote?['price'] as num?)?.toDouble();
    if (price == null) return const SizedBox.shrink();

    final source = (_quote?['source'] ?? '').toString();
    final isBlofin = source == 'blofin' || source == 'blofin_demo';
    final change = (_quote?['change_24h_pct'] as num?)?.toDouble();
    final changeColor = (change ?? 0) >= 0 ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text(
            _formatOraclePrice(price),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.2),
          ),
          if (change != null) ...[
            const SizedBox(width: 8),
            Text(
              '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: changeColor),
            ),
          ],
          const Spacer(),
          if (isBlofin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: const Color(0xFF00BFFF).withValues(alpha: 0.14),
                border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.45)),
              ),
              child: const Text(
                'BloFin',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF00BFFF)),
              ),
            ),
        ],
      ),
    );
  }
}

abstract final class OracleCitadelService {
  static Future<Map<String, String>> _authHeaders() => AppApiKeyService.backendHeaders();

  static String? _parseUserMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        if (decoded['user_message'] is String) return decoded['user_message'] as String;
        final detail = decoded['detail'];
        if (detail is Map && detail['user_message'] is String) {
          return detail['user_message'] as String;
        }
        if (detail is Map && detail['notification'] is Map) {
          final notif = detail['notification'] as Map;
          if (notif['body'] is String) return notif['body'] as String;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> linkExchangeKeys({
    required String userId,
    required String exchangeApiKey,
    required String exchangeApiSecret,
    String? exchangePassphrase,
    String exchange = 'blofin',
    bool useDemoMode = false,
    double riskPercent = 1.0,
  }) async {
    final uri = Uri.parse('$kCitadelBaseUrl/exchange_keys');
    final payload = <String, dynamic>{
      'user_id': userId,
      'app_api_key': OracleCitadelStore.apiKey,
      'api_key': exchangeApiKey,
      'api_secret': exchangeApiSecret,
      'exchange': exchange,
      'use_demo_mode': useDemoMode,
      'demo_mode': useDemoMode,
      'risk_percent': riskPercent,
    };
    final passphrase = (exchangePassphrase ?? '').trim();
    if (passphrase.isNotEmpty) {
      payload['exchange_passphrase'] = passphrase;
      payload['passphrase'] = passphrase;
    }
    final response = await http
        .post(
          uri,
          headers: await _authHeaders(),
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) return;

    final friendly = _parseUserMessage(response) ??
        'Could not save exchange keys (${response.statusCode}).';
    throw OracleCitadelException(friendly);
  }

  /// Confirms exchange keys exist on the Railway server (not just local prefs).
  static Future<CitadelServerLinkStatus> checkServerLinked() async {
    await OracleCitadelStore.load();
    if (!OracleCitadelStore.isConfigured) {
      return const CitadelServerLinkStatus(
        linked: false,
        userMessage: 'App API Key missing. Open Oracle Citadel Setup and save your credentials.',
        errorCode: 'credentials_missing',
      );
    }
    final uri = Uri.parse('$kCitadelBaseUrl/exchange_keys/status').replace(
      queryParameters: {'user_id': OracleCitadelStore.userId},
    );
    try {
      final response = await http
          .get(uri, headers: await _authHeaders())
          .timeout(const Duration(seconds: 15));

      Map<String, dynamic> body = {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {}

      if (response.statusCode == 200 && body['linked'] == true) {
        final ex = (body['exchange']?.toString() ?? '').toLowerCase();
        if (ex.contains('bitunix')) {
          await OracleCitadelStore.saveSelectedExchange('bitunix');
        } else if (ex.contains('blofin')) {
          await OracleCitadelStore.saveSelectedExchange('blofin');
        }
        if (body['use_demo_mode'] is bool) {
          await OracleCitadelStore.saveDemoMode(body['use_demo_mode'] as bool);
        }
        OracleCitadelStore.serverPaused = body['paused'] == true;
        await OracleCitadelStore.markExchangeLinked(true);
        return const CitadelServerLinkStatus(linked: true);
      }

      final message = body['user_message']?.toString() ??
          _parseUserMessage(response) ??
          'Exchange keys not found on server. Re-link keys in Oracle Citadel Setup.';
      final errorCode = body['error_code']?.toString();
      debugPrint(
        '[Citadel] server link check failed status=${response.statusCode} '
        'code=$errorCode msg=$message',
      );
      await OracleCitadelStore.clearExchangeLinked();
      return CitadelServerLinkStatus(
        linked: false,
        userMessage: message,
        errorCode: errorCode,
      );
    } catch (e) {
      debugPrint('[Citadel] server link check error: $e');
      await OracleCitadelStore.clearExchangeLinked();
      return const CitadelServerLinkStatus(
        linked: false,
        userMessage: 'Could not reach Citadel server. Check connection and try again.',
      );
    }
  }

  static Future<bool> verifyServerLinked() async {
    final status = await checkServerLinked();
    return status.linked;
  }

  /// MARKET Citadel execution — order_type + protective levels.
  static Future<Map<String, dynamic>> executeMarketOrder({
    required String userId,
    required String coin,
    required String direction,
    required double stopLoss,
    required double tp1,
    required double tp2,
    required double riskPercent,
    required double leverage,
  }) async {
    final uri = Uri.parse('$kCitadelBaseUrl/execute_trade');
    await OracleCitadelStore.load();
    final payload = {
      'user_id': userId,
      'coin': coin.toUpperCase(),
      'direction': direction,
      'order_type': 'market',
      'use_demo_mode': OracleCitadelStore.useDemoMode,
      'demo_mode': OracleCitadelStore.useDemoMode,
      'risk_percent': riskPercent,
      'leverage': leverage.round(),
      'stop_loss': stopLoss,
      'tp1': tp1,
      'tp2': tp2,
      // Reference only — market fill uses live price; satisfies /execute_trade validation.
      'entry_price': (tp1 + stopLoss) / 2,
    };

    debugPrint(
      '[Citadel] POST $uri MARKET coin=$coin direction=$direction '
      'demo=${OracleCitadelStore.useDemoMode} '
      'leverage=${leverage.round()}x risk=${riskPercent.toStringAsFixed(1)}%',
    );

    final response = await http
        .post(uri, headers: await _authHeaders(), body: jsonEncode(payload))
        .timeout(const Duration(seconds: 90));

    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}

    if (response.statusCode == 200) return body;

    var friendly = _parseUserMessage(response) ??
        body['user_message']?.toString() ??
        'MARKET order could not be sent (${response.statusCode}).';
    final whitelistIp = body['whitelist_ip']?.toString().trim();
    if (whitelistIp != null && whitelistIp.isNotEmpty) {
      final envLabel = OracleCitadelStore.exchangeDisplayLabel;
      friendly = '$friendly\n\nWhitelist this IP in $envLabel → API Management: $whitelistIp';
    }
    throw OracleCitadelException(
      friendly,
      errorCode: body['error_code']?.toString(),
    );
  }

  /// LIMIT Citadel execution — rests on BloFin Open Orders at planned entry.
  static Future<Map<String, dynamic>> executeLimitOrder({
    required String userId,
    required String coin,
    required String direction,
    required double entryPrice,
    required double stopLoss,
    required double tp1,
    required double tp2,
    required double riskPercent,
    required double leverage,
  }) async {
    final uri = Uri.parse('$kCitadelBaseUrl/execute_trade');
    await OracleCitadelStore.load();
    final payload = {
      'user_id': userId,
      'coin': coin.toUpperCase(),
      'direction': direction,
      'order_type': 'limit',
      'use_demo_mode': OracleCitadelStore.useDemoMode,
      'demo_mode': OracleCitadelStore.useDemoMode,
      'entry_price': entryPrice,
      'risk_percent': riskPercent,
      'leverage': leverage.round(),
      'stop_loss': stopLoss,
      'tp1': tp1,
      'tp2': tp2,
    };

    debugPrint(
      '[Citadel] POST $uri LIMIT coin=$coin direction=$direction entry=$entryPrice '
      'demo=${OracleCitadelStore.useDemoMode} '
      'leverage=${leverage.round()}x risk=${riskPercent.toStringAsFixed(1)}%',
    );

    final response = await http
        .post(uri, headers: await _authHeaders(), body: jsonEncode(payload))
        .timeout(const Duration(seconds: 90));

    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}

    if (response.statusCode == 200) return body;

    var friendly = _parseUserMessage(response) ??
        body['user_message']?.toString() ??
        'LIMIT order could not be sent (${response.statusCode}).';
    final whitelistIp = body['whitelist_ip']?.toString().trim();
    if (whitelistIp != null && whitelistIp.isNotEmpty) {
      final envLabel = OracleCitadelStore.exchangeDisplayLabel;
      friendly = '$friendly\n\nWhitelist this IP in $envLabel → API Management: $whitelistIp';
    }
    throw OracleCitadelException(
      friendly,
      errorCode: body['error_code']?.toString(),
    );
  }
}

String citadelDirectionFromSetup(String selectedDirection, double entry, double sl) {
  final lower = selectedDirection.toLowerCase();
  if (lower.contains('long')) return 'long';
  if (lower.contains('short')) return 'short';
  return sl < entry ? 'long' : 'short';
}

String _formatCitadelPrice(double value) {
  if (value >= 1000) {
    return '\$${value.toStringAsFixed(value >= 10000 ? 0 : 2)}';
  }
  return '\$${value.toStringAsFixed(4).replaceAll(RegExp(r'\.?0+$'), '')}';
}

/// MARKET entry — BloFin execution after user confirms in Citadel dialog.
Future<void> _sendMarketOrder(
  BuildContext context,
  String coin,
  String direction, {
  required String reportText,
  required double plannedEntry,
  required double stopLoss,
  required double tp1,
  required double tp2,
  required double leverage,
  required double riskPercent,
}) async {
  final messengerContext = _citadelMessengerContext(context);
  if (messengerContext == null) {
    debugPrint('[Citadel] MARKET aborted — no valid ScaffoldMessenger context');
    return;
  }
  final rootContext = Navigator.of(messengerContext, rootNavigator: true).context;

  if (OracleCitadelStore.paperMode) {
    await _sendPaperOrder(
      messengerContext,
      orderType: 'market',
      coin: coin,
      direction: direction,
      plannedEntry: plannedEntry,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
    );
    return;
  }
  final confirmed = await _previewAndConfirmCitadelOrder(
    messengerContext,
    orderType: 'market',
    coin: coin,
    direction: direction,
    entryPrice: plannedEntry,
    stopLoss: stopLoss,
    tp1: tp1,
    tp2: tp2,
    riskPercent: riskPercent,
    leverage: leverage,
  );
  if (!confirmed || !messengerContext.mounted) return;

  ScaffoldMessenger.of(messengerContext).showSnackBar(
    SnackBar(
      content: Text('Executing MARKET ${direction.toUpperCase()} on $coin…'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ),
  );

  try {
    await OracleCitadelStore.load();
    final result = await OracleCitadelService.executeMarketOrder(
      userId: OracleCitadelStore.userId,
      coin: coin,
      direction: direction,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
      riskPercent: riskPercent,
      leverage: leverage,
    );

    await CitadelPendingTradeStore.clear();
    OracleCitadelStore.onOrderSized?.call(
      coin: coin,
      leverage: leverage,
      riskPercent: riskPercent,
    );

    if (messengerContext.mounted) {
      ScaffoldMessenger.of(messengerContext).showSnackBar(
        SnackBar(
          content: Text(
            'MARKET ${direction.toUpperCase()} on $coin sent to '
            '${OracleCitadelStore.selectedExchange == 'bitunix' ? 'Bitunix' : 'BloFin'}',
          ),
          backgroundColor: const Color(0xFF43A047),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    if (!rootContext.mounted) return;
    _showCitadelPostExecutionReviewDialog(
      rootContext,
      reportText: reportText,
      plannedEntry: plannedEntry,
      originalStopLoss: stopLoss,
      marketResult: result,
      coin: coin,
      direction: direction,
    );
  } on OracleCitadelException catch (e) {
    if (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch') {
      await OracleCitadelStore.clearExchangeLinked();
    }
    if (!messengerContext.mounted) return;
    ScaffoldMessenger.of(messengerContext).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch')
            ? SnackBarAction(
                label: 'Setup',
                textColor: Colors.white,
                onPressed: () => showCitadelSetupDialog(messengerContext),
              )
            : null,
      ),
    );
  } catch (e) {
    debugPrint('[Citadel] MARKET unexpected error: $e');
    if (!messengerContext.mounted) return;
    ScaffoldMessenger.of(messengerContext).showSnackBar(
      const SnackBar(
        content: Text('MARKET order failed. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 8),
      ),
    );
  }
}

/// LIMIT entry — BloFin resting order at planned entry price.
Future<void> _sendLimitOrder(
  BuildContext context,
  String coin,
  String direction, {
  required String reportText,
  required double plannedEntry,
  required double stopLoss,
  required double tp1,
  required double tp2,
  required double leverage,
  required double riskPercent,
}) async {
  final messengerContext = _citadelMessengerContext(context);
  if (messengerContext == null) {
    debugPrint('[Citadel] LIMIT aborted — no valid ScaffoldMessenger context');
    return;
  }
  final rootContext = Navigator.of(messengerContext, rootNavigator: true).context;

  if (OracleCitadelStore.paperMode) {
    await _sendPaperOrder(
      messengerContext,
      orderType: 'limit',
      coin: coin,
      direction: direction,
      plannedEntry: plannedEntry,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
    );
    return;
  }
  final confirmed = await _previewAndConfirmCitadelOrder(
    messengerContext,
    orderType: 'limit',
    coin: coin,
    direction: direction,
    entryPrice: plannedEntry,
    stopLoss: stopLoss,
    tp1: tp1,
    tp2: tp2,
    riskPercent: riskPercent,
    leverage: leverage,
  );
  if (!confirmed || !messengerContext.mounted) return;

  ScaffoldMessenger.of(messengerContext).showSnackBar(
    SnackBar(
      content: Text(
        'Placing LIMIT ${direction.toUpperCase()} on $coin at ${_formatCitadelPrice(plannedEntry)}…',
      ),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ),
  );

  try {
    await OracleCitadelStore.load();
    final result = await OracleCitadelService.executeLimitOrder(
      userId: OracleCitadelStore.userId,
      coin: coin,
      direction: direction,
      entryPrice: plannedEntry,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
      riskPercent: riskPercent,
      leverage: leverage,
    );

    await CitadelPendingTradeStore.clear();
    OracleCitadelStore.onOrderSized?.call(
      coin: coin,
      leverage: leverage,
      riskPercent: riskPercent,
    );

    if (messengerContext.mounted) {
      ScaffoldMessenger.of(messengerContext).showSnackBar(
        SnackBar(
          content: Text(
            'LIMIT ${direction.toUpperCase()} on $coin placed on '
            '${OracleCitadelStore.selectedExchange == 'bitunix' ? 'Bitunix' : 'BloFin'}',
          ),
          backgroundColor: const Color(0xFF43A047),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    if (!rootContext.mounted) return;
    _showCitadelLimitPostPlacementDialog(
      rootContext,
      reportText: reportText,
      plannedEntry: plannedEntry,
      stopLoss: stopLoss,
      limitResult: result,
      coin: coin,
      direction: direction,
    );
  } on OracleCitadelException catch (e) {
    if (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch') {
      await OracleCitadelStore.clearExchangeLinked();
    }
    if (!messengerContext.mounted) return;
    ScaffoldMessenger.of(messengerContext).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch')
            ? SnackBarAction(
                label: 'Setup',
                textColor: Colors.white,
                onPressed: () => showCitadelSetupDialog(messengerContext),
              )
            : null,
      ),
    );
  } catch (e) {
    debugPrint('[Citadel] LIMIT unexpected error: $e');
    if (!messengerContext.mounted) return;
    ScaffoldMessenger.of(messengerContext).showSnackBar(
      const SnackBar(
        content: Text('LIMIT order failed. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 8),
      ),
    );
  }
}

/// Parent screen context for snackbars after the Citadel execute dialog closes.
BuildContext? _citadelMessengerContext(BuildContext context) {
  if (context.mounted) return context;
  final root = Navigator.maybeOf(context, rootNavigator: true)?.context;
  if (root != null && root.mounted) return root;
  return null;
}

/// Oracle Citadel — MARKET or LIMIT execution choice.
Future<void> _showCitadelExecuteChoiceDialog(
  BuildContext context, {
  required String reportText,
  required String coin,
  required String direction,
  required double plannedEntry,
  required double stopLoss,
  required double tp1,
  required double tp2,
}) async {
  await OracleCitadelStore.load();
  if (!context.mounted) return;

  // Parent screen — survives closing the execute dialog (dialog builder context is disposed on pop).
  final hostContext = context;

  var leverage = OracleCitadelStore.defaultLeverage;
  var riskPercent = OracleCitadelStore.defaultRiskPercent;

  showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        final maxDialogHeight = MediaQuery.sizeOf(context).height * 0.88;
        return Dialog(
        backgroundColor: const Color(0xFF141414),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 400, maxHeight: maxDialogHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Oracle Citadel',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            OracleCitadelStore.paperMode
                                ? 'Paper trade · no real order'
                                : 'Market or Limit · ${OracleCitadelStore.exchangeDisplayLabel}',
                            style: TextStyle(
                              fontSize: 13,
                              color: OracleCitadelStore.paperMode ? const Color(0xFFB39DDB) : Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Entry ${_formatCitadelPrice(plannedEntry)} · SL ${_formatCitadelPrice(stopLoss)}',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400], height: 1.4),
                ),
                const SizedBox(height: 16),
                _CitadelLeverageRiskPanel(
                  leverage: leverage,
                  onLeverageChanged: (value) => setDialogState(() => leverage = value),
                  riskPercent: riskPercent,
                  onRiskPercentChanged: (value) => setDialogState(() => riskPercent = value),
                  entry: plannedEntry,
                  stopLoss: stopLoss,
                ),
                const SizedBox(height: 16),
                _CitadelExecutionOptionTile(
                  icon: Icons.rocket_launch_rounded,
                  iconColor: const Color(0xFF43A047),
                  title: 'Execute as MARKET Order NOW',
                  subtitle:
                      'Enter immediately at the current market price on ${OracleCitadelStore.selectedExchange == 'bitunix' ? 'Bitunix' : 'BloFin'}. '
                      'Stop loss is placed on entry; TP1 (40%) and TP2 (60%) legs follow fill.',
                  highlighted: true,
                  showSliders: false,
                  actionLabel: 'Execute as MARKET Order NOW',
                  actionColor: const Color(0xFF43A047),
                  onTap: () async {
                    final selectedLeverage = leverage.clamp(1.0, 100.0);
                    final selectedRisk = riskPercent.clamp(1.0, 100.0);
                    await OracleCitadelStore.saveLeverage(selectedLeverage);
                    await OracleCitadelStore.saveRiskPercent(selectedRisk);
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _sendMarketOrder(
                      hostContext,
                      coin,
                      direction,
                      reportText: reportText,
                      plannedEntry: plannedEntry,
                      stopLoss: stopLoss,
                      tp1: tp1,
                      tp2: tp2,
                      leverage: selectedLeverage,
                      riskPercent: selectedRisk,
                    );
                  },
                ),
                const SizedBox(height: 12),
                _CitadelExecutionOptionTile(
                  icon: Icons.schedule_rounded,
                  iconColor: const Color(0xFF00BFFF),
                  title: 'Place LIMIT Order at Entry',
                  subtitle:
                      'Rest on the ${OracleCitadelStore.selectedExchange == 'bitunix' ? 'Bitunix' : 'BloFin'} order book at ${_formatCitadelPrice(plannedEntry)}. '
                      'Stop loss attaches to the limit order. TP1/TP2 are set after the order fills.',
                  highlighted: true,
                  showSliders: false,
                  accentColor: const Color(0xFF00BFFF),
                  actionLabel: 'Place LIMIT Order at Entry',
                  actionColor: const Color(0xFF00BFFF),
                  onTap: () async {
                    final selectedLeverage = leverage.clamp(1.0, 100.0);
                    final selectedRisk = riskPercent.clamp(1.0, 100.0);
                    await OracleCitadelStore.saveLeverage(selectedLeverage);
                    await OracleCitadelStore.saveRiskPercent(selectedRisk);
                    if (!dialogContext.mounted) return;
                    Navigator.pop(dialogContext);
                    await _sendLimitOrder(
                      hostContext,
                      coin,
                      direction,
                      reportText: reportText,
                      plannedEntry: plannedEntry,
                      stopLoss: stopLoss,
                      tp1: tp1,
                      tp2: tp2,
                      leverage: selectedLeverage,
                      riskPercent: selectedRisk,
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '$coin · ${direction.toUpperCase()}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600], letterSpacing: 0.3),
                ),
              ],
            ),
          ),
        ),
      );
      },
    ),
  );
}

/// Post-placement success — limit order resting on BloFin Open Orders.
void _showCitadelLimitPostPlacementDialog(
  BuildContext context, {
  required String reportText,
  required double plannedEntry,
  required double stopLoss,
  required Map<String, dynamic> limitResult,
  required String coin,
  required String direction,
}) {
  Future.delayed(const Duration(milliseconds: 400), () {
    if (!context.mounted) return;

    final analysis = parseCitadelAnalysisSnapshot(reportText);
    final orderId = limitResult['order_id']?.toString();
    final displayCoin = limitResult['coin']?.toString() ?? coin;
    final displayDirection =
        (limitResult['direction']?.toString() ?? direction).toUpperCase();
    final entry = limitResult['entry_price'] is num
        ? (limitResult['entry_price'] as num).toDouble()
        : plannedEntry;
    final limitStatus = limitResult['limit_status']?.toString() ?? 'resting';
    final filledImmediately = limitStatus == 'filled';
    final fillEntry = limitResult['fill_entry_price'] is num
        ? (limitResult['fill_entry_price'] as num).toDouble()
        : (limitResult['blofin_confirm'] is Map
            ? double.tryParse(
                (limitResult['blofin_confirm'] as Map)['average_price']?.toString() ?? '',
              )
            : null);
    final exchangeLabel = limitResult['exchange']?.toString() == 'bitunix'
        ? 'Bitunix'
        : 'BloFin';
    final confidence = analysis.confidencePercent;
    final grade = analysis.confluenceGrade;

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF141414),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: filledImmediately ? const Color(0xFF1B3320) : const Color(0xFF1A2533),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (filledImmediately ? const Color(0xFF43A047) : const Color(0xFF00BFFF))
                          .withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        filledImmediately ? Icons.check_circle_rounded : Icons.schedule_rounded,
                        color: filledImmediately ? const Color(0xFF43A047) : const Color(0xFF00BFFF),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              filledImmediately ? 'LIMIT Order Filled' : 'LIMIT Order Placed',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            if (displayCoin.isNotEmpty)
                              Text(
                                filledImmediately
                                    ? '$displayCoin $displayDirection · $exchangeLabel Position'
                                    : '$displayCoin $displayDirection · $exchangeLabel Open Orders',
                                style: TextStyle(fontSize: 12.5, color: Colors.grey[400]),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  filledImmediately && fillEntry != null && fillEntry > 0
                      ? 'Fill ${_formatCitadelPrice(fillEntry)} · SL ${_formatCitadelPrice(stopLoss)}'
                      : 'Entry ${_formatCitadelPrice(entry)} · SL ${_formatCitadelPrice(stopLoss)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  filledImmediately
                      ? 'Your limit filled immediately on $exchangeLabel. TP1 (40%) and TP2 (60%) legs were attached when possible.'
                      : 'Your limit is on the book — no position until price hits entry. '
                          'TP1 (40%) and TP2 (60%) will apply after fill.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400], height: 1.45),
                ),
                if (orderId != null && orderId.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Order ID: $orderId',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                  ),
                ],
                if (confidence != null || grade != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A2533),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Confluence (from your analysis)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue[200],
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (confidence != null)
                          Text(
                            'Confidence: $confidence%',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        if (grade != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Grade: $grade',
                            style: TextStyle(fontSize: 14, color: Colors.grey[300]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  });
}

/// Post-fill success — confluence + suggested stop-loss after MARKET fill.
void _showCitadelPostExecutionReviewDialog(
  BuildContext context, {
  required String reportText,
  required double plannedEntry,
  required double originalStopLoss,
  required Map<String, dynamic> marketResult,
  required String coin,
  required String direction,
}) {
  Future.delayed(const Duration(milliseconds: 400), () {
    if (!context.mounted) return;

    final analysis = parseCitadelAnalysisSnapshot(reportText);
    final review = marketResult['post_trade_review'];
    final reviewMap = review is Map<String, dynamic> ? review : marketResult;

    double parseNum(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0;
    }

    final fillEntry = parseNum(
      reviewMap['fill_entry_price'] ??
          marketResult['fill_entry_price'] ??
          (marketResult['blofin_confirm'] is Map
              ? (marketResult['blofin_confirm'] as Map)['average_price']
              : null),
    );
    final planned = parseNum(reviewMap['planned_entry_price'] ?? plannedEntry);
    final originalSl = parseNum(reviewMap['original_stop_loss'] ?? originalStopLoss);
    final suggestedSl = parseNum(reviewMap['suggested_stop_loss'] ?? originalSl);
    final orderId = marketResult['order_id']?.toString();
    final displayCoin = marketResult['coin']?.toString() ?? coin;
    final displayDirection =
        (marketResult['direction']?.toString() ?? direction).toUpperCase();
    final exchangeLabel = marketResult['exchange']?.toString() == 'bitunix'
        ? 'Bitunix'
        : 'BloFin';

    final confidence = analysis.confidencePercent;
    final grade = analysis.confluenceGrade;
    final slDrift = (suggestedSl - originalSl).abs() > 0.0001;
    final entryDrift = fillEntry > 0 && planned > 0 && (fillEntry - planned).abs() / planned > 0.002;

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF141414),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B3320),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: Color(0xFF43A047), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'MARKET Order Filled',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            if (displayCoin.isNotEmpty)
                              Text(
                                '$displayCoin $displayDirection · $exchangeLabel',
                                style: TextStyle(fontSize: 12.5, color: Colors.grey[400]),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Position Live — Desk Review',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Review your fill and update stop loss in BloFin if needed.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400], height: 1.45),
                ),
                if (orderId != null && orderId.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Order ID: $orderId',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                  ),
                ],
                const SizedBox(height: 18),
                if (confidence != null || grade != null)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2A1E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.35)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Confluence (from your analysis)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.green[200],
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (confidence != null)
                          Text(
                            'Confidence: $confidence%',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        if (grade != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Grade: $grade',
                            style: TextStyle(fontSize: 14, color: Colors.grey[300]),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Stop loss reference',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue[200],
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (fillEntry > 0)
                        Text(
                          'Market fill (entry): ${_formatCitadelPrice(fillEntry)}'
                          '${entryDrift ? ' — vs planned ${_formatCitadelPrice(planned)}' : ''}',
                          style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.4),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        'Original SL (from setup): ${_formatCitadelPrice(originalSl)}',
                        style: TextStyle(fontSize: 14, color: Colors.grey[300], height: 1.4),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2218),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFFFB74D).withValues(alpha: 0.45)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Suggested SL (from fill)',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.orange[200],
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _formatCitadelPrice(suggestedSl),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFFFB74D),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              slDrift
                                  ? 'Same risk distance from your fill — adjust in BloFin.'
                                  : 'Matches your setup distance from fill.',
                              style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.35),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF43A047),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  });
}

/// Shared leverage + position size controls for Citadel execute dialog.
class _CitadelLeverageRiskPanel extends StatelessWidget {
  final double leverage;
  final ValueChanged<double> onLeverageChanged;
  final double riskPercent;
  final ValueChanged<double> onRiskPercentChanged;
  final double? entry;
  final double? stopLoss;

  static const _riskPresets = [1, 5, 10, 25, 50, 100];

  const _CitadelLeverageRiskPanel({
    required this.leverage,
    required this.onLeverageChanged,
    required this.riskPercent,
    required this.onRiskPercentChanged,
    this.entry,
    this.stopLoss,
  });

  @override
  Widget build(BuildContext context) {
    final roundedLeverage = leverage.round();
    final riskLabel = riskPercent == riskPercent.roundToDouble()
        ? riskPercent.round().toString()
        : riskPercent.toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 16, color: Colors.orange[200]),
              const SizedBox(width: 6),
              Text(
                'Leverage: ${roundedLeverage}x',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF43A047),
              inactiveTrackColor: Colors.grey[800],
              thumbColor: const Color(0xFF43A047),
              overlayColor: const Color(0xFF43A047).withValues(alpha: 0.12),
              trackHeight: 3,
            ),
            child: Slider(
              value: leverage.clamp(1, 100),
              min: 1,
              max: 100,
              divisions: 99,
              label: '${roundedLeverage}x',
              onChanged: onLeverageChanged,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.pie_chart_outline_rounded, size: 16, color: Colors.blue[200]),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Position size: $riskLabel% of account'
                  '${riskPercent >= 25 ? ' (large size — elevated liquidation risk)' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '(Larger position sizes increase liquidation and drawdown risk — size only what you can afford to lose.)',
            style: TextStyle(fontSize: 11, color: Colors.grey[600], height: 1.35),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF43A047),
              inactiveTrackColor: Colors.grey[800],
              thumbColor: const Color(0xFF43A047),
              overlayColor: const Color(0xFF43A047).withValues(alpha: 0.12),
              trackHeight: 3,
            ),
            child: Slider(
              value: riskPercent.clamp(1, 100),
              min: 1,
              max: 100,
              divisions: 99,
              label: '$riskLabel%',
              onChanged: onRiskPercentChanged,
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _riskPresets.map((preset) {
              final selected = (riskPercent - preset).abs() < 0.5;
              return GestureDetector(
                onTap: () => onRiskPercentChanged(preset.toDouble()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: selected
                        ? const Color(0xFF43A047).withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.25),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF43A047).withValues(alpha: 0.55)
                          : Colors.grey[800]!,
                    ),
                  ),
                  child: Text(
                    '$preset%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: selected ? const Color(0xFF43A047) : Colors.grey[500],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          _PositionAtRiskLine(
            capital: StartingCapitalStore.capitalUsd,
            riskPercent: riskPercent,
            leverage: leverage,
            entry: entry,
            stopLoss: stopLoss,
            accent: const Color(0xFF43A047),
          ),
        ],
      ),
    );
  }
}

class _PositionAtRiskLine extends StatelessWidget {
  final double capital;
  final double riskPercent;
  final double leverage;
  final double? entry;
  final double? stopLoss;
  final Color accent;

  const _PositionAtRiskLine({
    required this.capital,
    required this.riskPercent,
    required this.leverage,
    this.entry,
    this.stopLoss,
    this.accent = const Color(0xFF00BFFF),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            PositionSizing.formulaLine(
              capital: capital,
              riskPercent: riskPercent,
              leverage: leverage,
            ),
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: accent),
          ),
          const SizedBox(height: 4),
          Text(
            PositionSizing.breakdownLine(
              capital: capital,
              riskPercent: riskPercent,
              leverage: leverage,
              entry: entry,
              sl: stopLoss,
            ),
            style: TextStyle(fontSize: 12, height: 1.4, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}

/// Single selectable row inside the Citadel execution choice dialog.
class _CitadelExecutionOptionTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? badge;
  final bool highlighted;
  final bool showSliders;
  final Color? accentColor;
  final Color? actionColor;
  final String? actionLabel;
  final double? leverage;
  final ValueChanged<double>? onLeverageChanged;
  final double? riskPercent;
  final ValueChanged<double>? onRiskPercentChanged;
  final VoidCallback onTap;

  static const _riskPresets = [1, 5, 10, 25, 50, 100];

  const _CitadelExecutionOptionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
    this.highlighted = false,
    this.showSliders = true,
    this.accentColor,
    this.actionColor,
    this.actionLabel,
    this.leverage,
    this.onLeverageChanged,
    this.riskPercent,
    this.onRiskPercentChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? const Color(0xFF43A047);
    final borderColor = highlighted
        ? accent.withValues(alpha: 0.55)
        : Colors.grey[800]!;
    final bg = highlighted
        ? (accentColor != null ? const Color(0xFF1A2533) : const Color(0xFF1B3320))
        : const Color(0xFF1E1E1E);
    final roundedLeverage = leverage?.round() ?? 5;
    final riskValue = riskPercent ?? 1.0;
    final riskLabel = riskValue == riskValue.roundToDouble()
        ? riskValue.round().toString()
        : riskValue.toStringAsFixed(1);
    final buttonColor = actionColor ?? const Color(0xFF43A047);
    final buttonLabel = actionLabel ?? title;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: highlighted ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: highlighted ? Colors.white : Colors.grey[200],
                      ),
                    ),
                  ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey[400]),
                      ),
                    ),
                  if (highlighted)
                    Icon(Icons.chevron_right_rounded, color: accent),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[500]),
              ),
              if (showSliders && highlighted && leverage != null && onLeverageChanged != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.bolt_rounded, size: 16, color: Colors.orange[200]),
                          const SizedBox(width: 6),
                          Text(
                            'Leverage: ${roundedLeverage}x',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFF43A047),
                          inactiveTrackColor: Colors.grey[800],
                          thumbColor: const Color(0xFF43A047),
                          overlayColor: const Color(0xFF43A047).withValues(alpha: 0.12),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: leverage!.clamp(1, 100),
                          min: 1,
                          max: 100,
                          divisions: 99,
                          label: '${roundedLeverage}x',
                          onChanged: onLeverageChanged,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (showSliders && highlighted && riskPercent != null && onRiskPercentChanged != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.pie_chart_outline_rounded, size: 16, color: Colors.blue[200]),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Position size: $riskLabel% of account'
                              '${riskPercent! >= 25 ? ' (large size — elevated liquidation risk)' : ''}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '(Larger position sizes increase liquidation and drawdown risk — size only what you can afford to lose.)',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600], height: 1.35),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFF43A047),
                          inactiveTrackColor: Colors.grey[800],
                          thumbColor: const Color(0xFF43A047),
                          overlayColor: const Color(0xFF43A047).withValues(alpha: 0.12),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: riskPercent!.clamp(1, 100),
                          min: 1,
                          max: 100,
                          divisions: 99,
                          label: '$riskLabel%',
                          onChanged: onRiskPercentChanged,
                        ),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _riskPresets.map((preset) {
                          final selected = (riskPercent! - preset).abs() < 0.5;
                          return GestureDetector(
                            onTap: () => onRiskPercentChanged!(preset.toDouble()),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: selected
                                    ? const Color(0xFF43A047).withValues(alpha: 0.2)
                                    : Colors.black.withValues(alpha: 0.25),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFF43A047).withValues(alpha: 0.55)
                                      : Colors.grey[800]!,
                                ),
                              ),
                              child: Text(
                                '$preset%',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: selected ? const Color(0xFF43A047) : Colors.grey[500],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ],
              if (highlighted) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onTap,
                    style: FilledButton.styleFrom(
                      backgroundColor: buttonColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      buttonLabel,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void showCitadelUpgradePrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Oracle Pro Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Automated trading via Oracle Citadel is included with Oracle Pro. '
        'Unlock it to send AI trade setups directly to the secure execution backend.',
        style: TextStyle(height: 1.45, color: Colors.grey[400]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Not Now', style: TextStyle(color: Colors.grey[500])),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(ctx);
            Navigator.push(ctx, _premiumPageRoute((_) => const SubscriptionPlanScreen()));
          },
          child: const Text(
            'View Plans',
            style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class SendToCitadelButton extends StatefulWidget {
  final String coin;
  final String directionLabel;
  final String reportText;
  final double? entry;
  final double? stopLoss;
  final double? tp1;
  final double? tp2;

  const SendToCitadelButton({
    super.key,
    required this.coin,
    required this.directionLabel,
    required this.reportText,
    this.entry,
    this.stopLoss,
    this.tp1,
    this.tp2,
  });

  @override
  State<SendToCitadelButton> createState() => _SendToCitadelButtonState();
}

class _SendToCitadelButtonState extends State<SendToCitadelButton> {
  bool _validating = false;
  bool _isExpert = false;
  CitadelParsedLevels? _previewLevels;
  /// Set only after a failed Send tap — never shown on initial build (avoids stale IP/errors).
  String? _sendErrorMessage;

  @override
  void initState() {
    super.initState();
    _previewLevels = parseCitadelTradeLevels(widget.reportText);
    _stashPendingTradeIfComplete();
    _loadTier();
    // Drop lingering Scaffold snackbars (e.g. prior MARKET failure) so they do not cover this screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
    });
  }

  Future<void> _loadTier() async {
    await SubscriptionPlanStore.load();
    if (mounted) setState(() => _isExpert = SubscriptionPlanStore.isExpert);
  }

  @override
  void didUpdateWidget(covariant SendToCitadelButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reportText != widget.reportText) {
      _previewLevels = parseCitadelTradeLevels(widget.reportText);
      _sendErrorMessage = null;
      _stashPendingTradeIfComplete();
    }
  }

  void _stashPendingTradeIfComplete() {
    final parsed = _previewLevels ?? parseCitadelTradeLevels(widget.reportText);
    final entry = widget.entry ?? parsed.entry;
    final sl = widget.stopLoss ?? parsed.sl;
    final tp1 = widget.tp1 ?? parsed.tp1;
    final tp2 = widget.tp2 ?? parsed.tp2;
    if (entry == null || sl == null || tp1 == null || tp2 == null) return;
    CitadelPendingTradeStore.save(
      coin: widget.coin,
      directionLabel: widget.directionLabel,
      reportText: widget.reportText,
      entry: entry,
      stopLoss: sl,
      tp1: tp1,
      tp2: tp2,
    );
  }

  void _clearSendError() {
    if (_sendErrorMessage == null) return;
    setState(() => _sendErrorMessage = null);
  }

  Future<void> _onPressed() async {
    try {
      await _runCitadelSendFlow();
    } catch (e) {
      debugPrint('[Citadel] Send flow error: $e');
      if (!mounted) return;
      setState(() {
        _sendErrorMessage = _citadelFriendlyErrorMessage(e);
      });
    }
  }

  Future<void> _runCitadelSendFlow() async {
    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.hasCitadelAccess) {
      if (mounted) showCitadelUpgradePrompt(context);
      return;
    }

    await OracleCitadelStore.load();
    if (!OracleCitadelStore.isConfigured) {
      if (mounted) await showCitadelSetupDialog(context);
      await OracleCitadelStore.load();
      if (!OracleCitadelStore.isConfigured) return;
    }

    var linkStatus = OracleCitadelStore.paperMode
        ? const CitadelServerLinkStatus(linked: true)
        : await OracleCitadelService.checkServerLinked();
    if (!linkStatus.linked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      await showCitadelSetupDialog(context);
      await OracleCitadelStore.load();
      if (!mounted) return;
      linkStatus = await OracleCitadelService.checkServerLinked();
      if (!linkStatus.linked) {
        if (!mounted) return;
        setState(() {
          _sendErrorMessage = linkStatus.userMessage ??
              'BloFin keys not found on server. Re-link in Oracle Citadel Setup '
              '(enter App API Key + BloFin API Key + Secret, then Save & Connect).';
        });
        return;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      setState(() => _sendErrorMessage = null);
    }

    if (mounted) {
      setState(() {
        _validating = true;
        _sendErrorMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Validating trade levels…'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    final parsed = parseCitadelTradeLevels(widget.reportText);
    if (!mounted) return;
    setState(() {
      _validating = false;
      _previewLevels = parsed;
    });

    final entry = widget.entry ?? parsed.entry;
    final sl = widget.stopLoss ?? parsed.sl;
    final tp1 = widget.tp1 ?? parsed.tp1;
    final tp2 = widget.tp2 ?? parsed.tp2;

    if (entry == null || sl == null || tp1 == null || tp2 == null) {
      if (mounted) {
        setState(() {
          _sendErrorMessage = parsed.userErrorMessage ??
              'Could not find Entry, SL, TP1, and TP2 in this report. '
              'Generate a complete trade setup first.';
        });
      }
      return;
    }

    final direction = citadelDirectionFromSetup(widget.directionLabel, entry, sl);
    if (!mounted) return;
    _showCitadelExecuteChoiceDialog(
      context,
      reportText: widget.reportText,
      coin: widget.coin,
      direction: direction,
      plannedEntry: entry,
      stopLoss: sl,
      tp1: tp1,
      tp2: tp2,
    );
  }

  String _citadelFriendlyErrorMessage(Object error) {
    // Prefer the backend's precise, actionable message when available.
    if (error is OracleCitadelException && error.userMessage.trim().isNotEmpty) {
      return error.userMessage;
    }
    final text = error.toString();
    if (text.toLowerCase().contains('brokerid') ||
        text.contains('152011') ||
        text.contains('152012') ||
        text.contains('152013')) {
      return 'Your BloFin API key is linked to a broker. Oracle Citadel needs a '
          'standard key: on BloFin, delete this key and create a new "API Key" '
          '(not the "Connect to Third-Party Applications" option), enable '
          '"Trade", then re-save it in Citadel Setup.';
    }
    if (text.contains('152404') || text.contains('operation is not supported')) {
      return 'BloFin authenticated your key but blocked the trade. Your live API '
          'key needs the "Trade" permission enabled (Read alone is not enough), '
          'and USDT-M Futures must be active on your account. Enable Trade on the '
          'key, re-save it in Citadel Setup, then try MARKET again.';
    }
    return 'Could not send to Citadel. Check connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    _previewLevels ??= parseCitadelTradeLevels(widget.reportText);
    final incomplete = _previewLevels != null && !_previewLevels!.hasMinimumForPreview;

    if (!_isExpert) {
      return _ScaleTap(
        onTap: () => showCitadelUpgradePrompt(context),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.grey[850]!,
                Colors.grey[900]!,
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.grey[700]!),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, color: Colors.grey[500], size: 20),
              const SizedBox(width: 10),
              Text(
                'Send to Oracle Citadel — Expert Plan',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final missing = _previewLevels?.missingLabelsForPreview ?? const <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (incomplete && missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: const Color(0xFF3E2723),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFB74D), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Trade levels incomplete: ${missing.join(', ')}. '
                        'Citadel needs Entry, TP1, TP2, and Stop Loss before sending.',
                        style: TextStyle(fontSize: 13, height: 1.4, color: Colors.orange[100]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_sendErrorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: const Color(0xFFB71C1C),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _sendErrorMessage!,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        _clearSendError();
                        await showCitadelSetupDialog(context);
                        if (!mounted) return;
                        final ok = await OracleCitadelService.verifyServerLinked();
                        if (ok) setState(() => _sendErrorMessage = null);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Setup', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: _clearSendError,
                      icon: const Icon(Icons.close, color: Colors.white, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _validating ? null : _onPressed,
            icon: _validating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.shield_outlined, size: 22),
            label: Text(
              _validating ? 'Validating trade levels…' : 'Send to Oracle Citadel',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFFF),
              foregroundColor: Colors.black,
              disabledBackgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 4,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Coin symbol normalization & tier access ─────────────────────────────────
