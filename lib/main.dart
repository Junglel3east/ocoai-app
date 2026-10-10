/*
- Subscription: Free (BTC/ETH/SOL) + Oracle Pro ($49.99/mo, full access; stored internally as `Expert`)
- FCM push notifications + daily 7:30 AM CST local alerts (NotificationService)
- TradingView charts: VWAP + EMA 5/20 + RSI + MACD + Auto Fib; full pinch/pan/zoom
- Watchlist coin search screen (TradingView-style symbol picker)
- UI polish: spacing, empty states, fade-ins, scale-on-tap, premium page transitions
- Dynamic Watchlist with + button (session memory) → Charts navigation
- Bottom nav: Home, Oracle Vision, Trade Setup, Charts, Oracle Desk (Alerts via Home AppBar bell)
- Expert-plan AI Chat FAB on Home + report screens
- Expert-plan Oracle Citadel: MARKET + LIMIT execution via /execute_trade (BloFin)
- App logo: splash screen, Home AppBar, Profile header (assets/images/app_logo.png)
- Oracle Desk — personal trading command center (watchlist bias, performance, setups)
*/
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'services/analysis_history_store.dart';
import 'services/daily_analysis_store.dart';
import 'services/watchlist_binance_ws_service.dart';
import 'services/notification_service.dart';
import 'services/citadel_positions_service.dart';
import 'services/oracle_academy_lessons.dart';
import 'services/oracle_academy_store.dart';
import 'services/oracle_desk_service.dart';
import 'services/oracle_flux_read_service.dart';
import 'services/oracle_vision_service.dart';
import 'services/app_api_key_service.dart';
import 'services/auth_service.dart';
import 'services/google_play_billing_service.dart';
import 'services/entitlement_service.dart';
import 'services/crash_reporter.dart';
import 'services/funnel_analytics.dart';
import 'services/social_links.dart';
import 'services/x_share_service.dart';
import 'widgets/push_to_x_button.dart';
import 'services/user_profile_store.dart';
import 'services/position_sizing.dart';
import 'services/oracle_alert_engine.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/login_screen.dart';
import 'screens/profile_screen.dart' show kProfileBackgroundOrbHeight, kProfileBackgroundOrbOpacity;
import 'widgets/ai_chat_entry.dart';
import 'widgets/background_illustration.dart';
import 'widgets/community_links_section.dart';
part 'screens/tradingview_chart.dart';
part 'core/ai_prompts.dart';
part 'core/subscription_plan_store.dart';
part 'core/citadel_core.dart';
part 'core/access_gates.dart';
part 'screens/chat_screen.dart';
part 'screens/ui_kit.dart';
part 'screens/splash_screen.dart';
part 'screens/main_tabs.dart';
part 'screens/home_screen.dart';
part 'screens/profile_settings.dart';
part 'screens/subscription_screen.dart';
part 'screens/reports.dart';
part 'screens/charts_screen.dart';
part 'screens/alerts_system.dart';
part 'screens/quick_analyze_screen.dart';
part 'screens/oracle_vision_screen.dart';
part 'screens/trade_setup_screen.dart';
part 'screens/trade_performance_screen.dart';
part 'screens/citadel_trade_levels.dart';
part 'screens/citadel_setup_dialog.dart';
part 'screens/citadel_live_positions.dart';
part 'screens/citadel_safety.dart';
part 'screens/track_record_screen.dart';
part 'screens/pro_preview.dart';
part 'screens/oracle_desk_screen.dart';
part 'screens/first_run_setup_screen.dart';
part 'screens/oracle_academy_screen.dart';
part 'screens/oracle_alerts_screen.dart';

const String kNewsApiKey = String.fromEnvironment(
  'NEWS_API_KEY',
  defaultValue: '0164e1b479294ae581c5097fdcf0d69a',
);

/// Production FastAPI backend (Railway live). Override: --dart-define=BACKEND_BASE_URL=...
const String kBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://ocoai-app-production.up.railway.app',
);

/// Oracle Citadel — same production Railway API host.
const String kCitadelBaseUrl = String.fromEnvironment(
  'CITADEL_BASE_URL',
  defaultValue: 'https://ocoai-app-production.up.railway.app',
);

/// GET /health on startup (logs only; does not block UI or change AI behavior).
Future<void> pingBackendHealth() async {
  final uri = Uri.parse('$kBackendBaseUrl/health');
  try {
    final response = await http
        .get(uri)
        .timeout(const Duration(seconds: 10));
    debugPrint('[Backend] health ${response.statusCode}: ${response.body}');
  } catch (e) {
    debugPrint('[Backend] health check failed: $e');
  }
}

/// App branding asset (full logo with icon + wordmark).
const String kAppLogoAsset = 'assets/images/app_logo.png';

/// Exact disclaimer required at the bottom of every AI report.
const String kReportDisclaimer =
    '**Disclaimer**: This is for informational and educational purposes only. Not financial advice. Always DYOR.';

/// Keep in sync with `pubspec.yaml` version (`name+build`).
abstract final class AppVersionInfo {
  static const versionName = '1.0.8';
  static const buildNumber = '19';
  static const label = 'v$versionName';
  static const aboutLine = 'Version $versionName (Build $buildNumber)';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CrashReporter.install(appVersion: AppVersionInfo.aboutLine);
  // Hive — Recent Analyses / trade setup history survives app restarts.
  await AnalysisHistoryStore.init();
  await DailyAnalysisStore.init();
  await NotificationService.instance.initialize();
  try {
    await GooglePlayBillingService.init().timeout(const Duration(seconds: 8));
  } catch (e) {
    debugPrint('[main] Google Play Billing init skipped: $e');
  }
  await SubscriptionPlanStore.load();
  // After Play's silent restore has reported owned purchases, adopt the server's entitlement.
  unawaited(
    Future<void>.delayed(const Duration(seconds: 6), () async {
      await EntitlementService.sync();
      await SubscriptionPlanStore.load();
    }),
  );
  if (kDebugMode) pingBackendHealth();
  runApp(const OnChainOracleAI());
}

class OnChainOracleAI extends StatelessWidget {
  const OnChainOracleAI({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'On-Chain Oracle AI',
        debugShowCheckedModeBanner: false,
        theme: _buildAppTheme(),
        home: const SplashScreen(),
      );
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const int _tabHome = 0;
  static const int _tabCitadel = 1;
  static const int _tabTradeSetup = 2;
  static const int _tabOracleVision = 3;
  static const int _tabOracleDesk = 4;

  int _selectedIndex = _tabHome;
  final List<Map<String, dynamic>> history = [];
  final List<Map<String, dynamic>> trades = [];
  DateTime? _lastTradeRefreshAt;

  /// Scrolls Home to Daily Analyses when a daily-analysis push is opened.
  final GlobalKey<_HomeScreenState> _homeKey = GlobalKey<_HomeScreenState>();

  /// Default watchlist coins; user-added coins append for the session.
  final List<String> _watchlist = ['BTC', 'ETH', 'SOL', 'BNB'];
  static const Set<String> _defaultWatchlist = {'BTC', 'ETH', 'SOL', 'BNB'};

  Future<void> addToWatchlist(String symbol) async {
    final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol);
    if (normalized == null || _watchlist.contains(normalized)) return;
    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.canAddWatchlistCoin(_watchlist.length)) {
      if (mounted) _showWatchlistLimitPrompt(context);
      return;
    }
    setState(() => _watchlist.add(normalized));
    unawaited(WatchlistStore.save(_watchlist));
    debugPrint('[Watchlist] Added coin: $normalized');
  }

  void removeFromWatchlist(String symbol) {
    final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
    setState(() {
      _watchlist.removeWhere((s) {
        final n = CoinAccessPolicy.normalizeCoinSymbol(s) ?? s.trim().toUpperCase();
        return n == normalized;
      });
    });
    unawaited(WatchlistStore.save(_watchlist));
    debugPrint('[Watchlist] Removed coin: $normalized');
  }

  /// Watchlist coin → full-screen Charts (Charts no longer a bottom tab).
  void goToCharts(String symbol) {
    final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
    debugPrint('[Navigation] Watchlist → Charts: $normalized');
    if (!mounted) return;
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => ChartsScreen(initialSymbol: normalized, isTabActive: true),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPersistedHistory().then((_) {
      if (!mounted) return Future<void>.value();
      _syncAlertEngine();
      return FirstRunStore.load();
    }).then((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowFirstRun());
    });
    SubscriptionPlanStore.load();
    OracleCitadelStore.load();
    UserProfileStore.load();
    TradingVenueStore.load();
    StartingCapitalStore.load();
    WatchlistStore.load().then((coins) {
      if (!mounted || coins.isEmpty) return;
      setState(() {
        _watchlist
          ..clear()
          ..addAll(coins);
      });
    });
    OracleCitadelStore.onOrderSized = stampCitadelSizeOnOpenTrade;
    unawaited(OracleAlertStore.load());
    NotificationService.instance.onAlertOpened = _onAlertNotificationOpened;
    NotificationService.instance.registerDailyAnalysesNavigator(_openDailyAnalysesFromNotification);
    NotificationService.instance.onDailyAnalysisPayload = _ingestDailyAnalysisFromPush;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.dispatchPendingDailyAnalysesNavigation();
      _refreshDailyAnalysesForHome();
    });
  }

  @override
  void dispose() {
    if (identical(OracleCitadelStore.onOrderSized, stampCitadelSizeOnOpenTrade)) {
      OracleCitadelStore.onOrderSized = null;
    }
    NotificationService.instance.onAlertOpened = null;
    OracleAlertEngine.instance.stop();
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.registerDailyAnalysesNavigator(null);
    NotificationService.instance.onDailyAnalysisPayload = null;
    super.dispose();
  }

  void _syncAlertEngine() {
    OracleAlertEngine.instance.policy = SubscriptionPlanStore.alertPolicy;
    OracleAlertEngine.instance.bindTrades(trades);
    OracleAlertEngine.instance.start();
  }

  void _onAlertNotificationOpened(Map<String, dynamic> data) {
    final open = data['open']?.toString();
    if (open == 'desk') {
      if (mounted) setState(() => _selectedIndex = _tabOracleDesk);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(
      _premiumPageRoute(
        (_) => AlertsScreen(trades: trades, onCloseTrade: closeTradeWithExit),
      ),
    );
  }

  Future<void> _maybeShowFirstRun() async {
    if (!mounted || FirstRunStore.completed) return;
    if (trades.isNotEmpty || history.isNotEmpty) {
      await FirstRunStore.markComplete();
      return;
    }
    final coins = await Navigator.of(context).push<List<String>>(
      PageRouteBuilder<List<String>>(
        pageBuilder: (_, __, ___) => const FirstRunSetupScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 400),
        fullscreenDialog: true,
      ),
    );
    if (!mounted) return;
    if (coins != null && coins.isNotEmpty) {
      setState(() {
        _watchlist
          ..clear()
          ..addAll(coins);
      });
      await WatchlistStore.save(_watchlist);
    }
  }

  void stampCitadelSizeOnOpenTrade({
    required String coin,
    required double leverage,
    required double riskPercent,
  }) {
    final normalized = coin.trim().toUpperCase();
    Map<String, dynamic>? target;
    for (final trade in trades) {
      if (trade['status'] != 'Open') continue;
      final tradeCoin = (trade['coin'] ?? '').toString().trim().toUpperCase();
      if (tradeCoin == normalized) {
        target = trade;
        break;
      }
    }
    if (target == null) return;
    setState(() {
      target!['leverage'] = leverage;
      target['riskPercent'] = riskPercent;
      target['executedVia'] = 'citadel';
    });
    _persistTrades();
  }

  void closeTradeWithExit({
    required dynamic tradeId,
    required String status,
    required double exitPrice,
    double feesUsd = 0,
  }) {
    Map<String, dynamic>? target;
    for (final trade in trades) {
      if (_historyIdsMatch(trade['id'], tradeId)) {
        target = trade;
        break;
      }
    }
    if (target == null) return;
    setState(() {
      target!['status'] = status;
      target['exitPrice'] = exitPrice;
      target['feesUsd'] = feesUsd;
      target['closedVia'] = 'manual';
      target['closedAt'] = DateTime.now().toIso8601String();
    });
    _syncTradeStatusToHistory();
    _persistTrades();
    _persistHistory();
    _syncAlertEngine();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshDailyAnalysesForHome());
    }
  }

  Future<void> _ingestDailyAnalysisFromPush(Map<String, dynamic> data) async {
    await DailyAnalysisStore.ingestNotificationPayload(data);
    await _applyDailyAnalysesToHistory();
  }

  Future<void> _refreshDailyAnalysesForHome() async {
    await DailyAnalysisStore.fetchAndPersistFromBackend(kBackendBaseUrl);
    await _applyDailyAnalysesToHistory();
  }

  Future<void> _applyDailyAnalysesToHistory() async {
    await SubscriptionPlanStore.load();
    _pruneAnalysisHistoryBeforeDay(_analysisDayKey(DateTime.now()));
    final merged = CoinAccessPolicy.filterDailyAnalysesInHistory(
      DailyAnalysisStore.mergeIntoHistory(history),
    );
    if (!mounted) return;
    setState(() => history
      ..clear()
      ..addAll(merged));
    await AnalysisHistoryStore.saveHistory(history);
    _homeKey.currentState?.reloadDailyAnalysesFromParent();
  }

  /// Push notification → Home tab → Daily Analyses section.
  void _openDailyAnalysesFromNotification() {
    if (!mounted) return;
    unawaited(_refreshDailyAnalysesForHome());
    setState(() => _selectedIndex = _tabHome);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _homeKey.currentState?.scrollToDailyAnalysesSection();
    });
  }

  /// Calendar day key for daily analysis retention (local timezone).
  String _analysisDayKey(DateTime dt) {
    final local = dt.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  /// Removes prior-day Quick Analyze rows when a new daily batch arrives.
  void _pruneAnalysisHistoryBeforeDay(String dayKey) {
    history.removeWhere((item) {
      if (item['source'] != 'analysis') return false;
      return item['analysisDay']?.toString() != dayKey;
    });
  }

  void _migrateAndPruneDailyAnalyses() {
    for (final item in history) {
      if (item['source'] != 'analysis') continue;
      if (item['analysisDay'] != null) continue;
      final idMs = int.tryParse(item['id']?.toString() ?? '');
      if (idMs != null) {
        item['analysisDay'] = _analysisDayKey(DateTime.fromMillisecondsSinceEpoch(idMs));
      } else {
        item['analysisDay'] = _analysisDayKey(DateTime.now());
      }
    }
    _pruneAnalysisHistoryBeforeDay(_analysisDayKey(DateTime.now()));
  }

  /// Load saved analyses + trade setups from Hive on cold start.
  Future<void> _loadPersistedHistory() async {
    final savedHistory = AnalysisHistoryStore.loadHistory();
    final savedTrades = AnalysisHistoryStore.loadTrades();
    if (!mounted) return;
    setState(() {
      history
        ..clear()
        ..addAll(savedHistory);
      trades
        ..clear()
        ..addAll(savedTrades);
    });
    _migrateAndPruneDailyAnalyses();
    _sanitizePlaceholderReports();
    _repairTradeHistoryLinks();
    await _refreshOpenTrades();
    await DailyAnalysisStore.init();
    await SubscriptionPlanStore.load();
    final merged = CoinAccessPolicy.filterDailyAnalysesInHistory(
      DailyAnalysisStore.mergeIntoHistory(history),
    );
    if (mounted) {
      history
        ..clear()
        ..addAll(merged);
    }
    if (mounted) {
      await AnalysisHistoryStore.saveHistory(history);
      await AnalysisHistoryStore.saveTrades(trades);
      _homeKey.currentState?.reloadDailyAnalysesFromParent();
    }
  }

  /// Clears placeholder report text saved before async fetch completed (e.g. "Loading...").
  void _sanitizePlaceholderReports() {
    var changed = false;
    for (final trade in trades) {
      if (isPlaceholderStoredReport(trade['report']?.toString())) {
        trade.remove('report');
        changed = true;
      }
    }
    for (final item in history) {
      if (isPlaceholderStoredReport(item['report']?.toString())) {
        item.remove('report');
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// Backfill missing tradeId/report links so every Trade Performance row can open.
  void _repairTradeHistoryLinks() {
    final usedHistoryIds = <String>{};
    var changed = false;
    final ordered = List<Map<String, dynamic>>.from(trades)
      ..sort((a, b) {
        final at = DateTime.tryParse(a['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = DateTime.tryParse(b['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });

    for (final trade in ordered) {
      final existing = resolveHistoryItemForTrade(trade, history, excludeHistoryIds: usedHistoryIds);
      if (existing == null) continue;

      final hid = existing['id']?.toString();
      if (hid != null) usedHistoryIds.add(hid);

      final report = existing['report']?.toString() ?? '';
      if (isPlaceholderStoredReport(report)) continue;

      final tradeReport = trade['report']?.toString() ?? '';
      if (isPlaceholderStoredReport(tradeReport)) {
        trade['report'] = report;
        changed = true;
      }
      if (trade['historyId'] == null && existing['id'] != null) {
        trade['historyId'] = existing['id'];
        changed = true;
      }
      for (final item in history) {
        if (item['source'] != 'trade_setup') continue;
        if (!_historyIdsMatch(item['id'], existing['id'])) continue;
        if (!_historyIdsMatch(item['tradeId'], trade['id'])) {
          item['tradeId'] = trade['id'];
          changed = true;
        }
        break;
      }
    }

    if (changed && mounted) setState(() {});
  }

  Map<String, dynamic>? _resolveHistoryForTrade(Map<String, dynamic> trade) {
    return resolveHistoryItemForTrade(trade, history);
  }

  Future<void> _persistHistory() => AnalysisHistoryStore.saveHistory(history);

  Future<void> _persistTrades() => AnalysisHistoryStore.saveTrades(trades);

  void addToHistory(String coin, String report) {
    final now = DateTime.now();
    final dayKey = _analysisDayKey(now);
    unawaited(DailyAnalysisStore.upsert(
      coin: coin,
      report: report,
      ingestSource: 'quick_analyze',
      at: now,
    ));
    setState(() {
      // New daily analyses replace yesterday's Quick Analyze rows only.
      _pruneAnalysisHistoryBeforeDay(dayKey);
      history.insert(0, {
        "id": now.millisecondsSinceEpoch.toString(),
        "coin": coin,
        "report": report,
        "time": "${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}",
        "source": "analysis",
        "analysisDay": dayKey,
      });
    });
    _persistHistory();
    _homeKey.currentState?.reloadDailyAnalysesFromParent();
  }

  void addTradeSetupResult(Map<String, dynamic> payload) {
    final reportText = payload['report']?.toString() ?? '';
    if (isPlaceholderStoredReport(reportText)) {
      debugPrint('[TradeSetup] Skipping save — report not ready or placeholder.');
      return;
    }
    final now = DateTime.now();
    // String id avoids Hive int precision loss; same id on trade + history row.
    final tradeId = now.millisecondsSinceEpoch.toString();
    final trade = {
      "id": tradeId,
      "coin": payload["coin"],
      "timeframe": payload["timeframe"],
      "direction": payload["direction"],
      "entry": payload["entry"],
      "tp1": payload["tp1"],
      "tp2": payload["tp2"],
      "sl": payload["sl"],
      "status": "Open",
      "createdAt": now.toIso8601String(),
      "lastPrice": null,
      // Snapshot so Trade Performance cards work if history row is trimmed.
      "report": payload["report"],
      "historyId": tradeId,
      "leverage": OracleCitadelStore.defaultLeverage,
      "riskPercent": OracleCitadelStore.defaultRiskPercent,
    };

    setState(() {
      trades.insert(0, trade);
      history.insert(0, {
        "id": tradeId,
        "coin": payload["coin"],
        "report": payload["report"],
        "time": "${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}",
        "source": "trade_setup",
        "tradeId": tradeId,
        "tradeStatus": "Open",
        "historyId": tradeId,
      });
      if (history.length > 20) history.removeLast();
    });
    _persistHistory();
    _persistTrades();
    _syncAlertEngine();
    unawaited(OracleAlertEngine.instance.tick());
  }

  void deleteFromHistory(dynamic id) {
    setState(() {
      final removed = history.where((item) => _historyIdsMatch(item['id'], id)).toList();
      history.removeWhere((item) => _historyIdsMatch(item['id'], id));
      for (final item in removed) {
        if (item['source'] == 'analysis') {
          unawaited(DailyAnalysisStore.removeCoin(item['coin']?.toString() ?? ''));
        }
        if (item['source'] == 'trade_setup' && item['tradeId'] != null) {
          trades.removeWhere((t) => _historyIdsMatch(t['id'], item['tradeId']));
        }
      }
    });
    _persistHistory();
    _persistTrades();
    _homeKey.currentState?.reloadDailyAnalysesFromParent();
  }

  /// Trade Performance trash — removes trade and any linked history row.
  void deleteTradeById(dynamic tradeId) {
    setState(() {
      trades.removeWhere((t) => _historyIdsMatch(t['id'], tradeId));
      history.removeWhere(
        (item) => item['source'] == 'trade_setup' && _historyIdsMatch(item['tradeId'], tradeId),
      );
    });
    _persistHistory();
    _persistTrades();
  }

  /// Clears only Quick Analyze rows — trade setups stay for Trade Performance.
  void clearDailyAnalyses() {
    unawaited(DailyAnalysisStore.clearToday());
    setState(() {
      history.removeWhere((item) => item['source'] == 'analysis');
    });
    _persistHistory();
    _homeKey.currentState?.reloadDailyAnalysesFromParent();
  }

  int get _winCount => trades.where((t) => t["status"] == "Win").length;
  int get _closedTradeCount => trades.where((t) => t["status"] == "Win" || t["status"] == "Loss").length;

  String get winRateText {
    if (_closedTradeCount == 0) {
      return "Win Rate: 0% (0 Wins / 0 Total)";
    }
    final rate = ((_winCount / _closedTradeCount) * 100).round();
    return "Win Rate: $rate% ($_winCount Wins / $_closedTradeCount Total)";
  }

  /// Citadel close — win/loss from realized PnL (early exit counts if profitable).
  void recordCitadelRealizedClose({required String coin, required double realizedPnl}) {
    final normalized = coin.trim().toUpperCase();
    Map<String, dynamic>? target;
    for (final trade in trades) {
      if (trade['status'] != 'Open') continue;
      final tradeCoin = (trade['coin'] ?? '').toString().trim().toUpperCase();
      if (tradeCoin == normalized) {
        target = trade;
        break;
      }
    }
    if (target == null) return;

    String nextStatus;
    if (realizedPnl > 0) {
      nextStatus = 'Win';
    } else if (realizedPnl < 0) {
      nextStatus = 'Loss';
    } else {
      nextStatus = 'Closed';
    }

    setState(() {
      target!['status'] = nextStatus;
      target['realizedPnl'] = realizedPnl;
      target['closedVia'] = 'citadel';
      target['closedAt'] = DateTime.now().toIso8601String();
    });
    _syncTradeStatusToHistory();
    _persistTrades();
    _persistHistory();
  }

  Future<void> _refreshOpenTrades() async {
    final hasOpenTrades = trades.any((trade) => trade["status"] == "Open");
    if (!hasOpenTrades) return;

    for (final trade in trades) {
      if (trade["status"] != "Open") continue;
      final coin = (trade["coin"] ?? "").toString().toUpperCase();
      if (coin.isEmpty) continue;

      final price = await _fetchCurrentPrice(coin);
      if (price == null) continue;

      final entry = _toDouble(trade["entry"]);
      final tp1 = _toDouble(trade["tp1"]);
      final tp2 = _toDouble(trade["tp2"]);
      final sl = _toDouble(trade["sl"]);
      if (entry == null || tp1 == null || tp2 == null || sl == null) continue;

      final resolvedDirection = _resolveDirection(
        trade["direction"]?.toString() ?? "Smart Direction",
        entry,
        sl,
      );

      String? nextStatus;
      double? exitPrice;
      if (resolvedDirection == "Long Only") {
        if (price >= tp2) {
          nextStatus = "Win";
          exitPrice = tp2;
        } else if (price >= tp1) {
          nextStatus = "Win";
          exitPrice = tp1;
        } else if (price <= sl) {
          nextStatus = "Loss";
          exitPrice = sl;
        }
      } else {
        if (price <= tp2) {
          nextStatus = "Win";
          exitPrice = tp2;
        } else if (price <= tp1) {
          nextStatus = "Win";
          exitPrice = tp1;
        } else if (price >= sl) {
          nextStatus = "Loss";
          exitPrice = sl;
        }
      }

      if (nextStatus != null) {
        trade["status"] = nextStatus;
        trade["exitPrice"] = exitPrice ?? price;
        trade["closedVia"] = 'auto';
        trade["closedAt"] = DateTime.now().toIso8601String();
      }
      trade["lastPrice"] = price;
    }

    _syncTradeStatusToHistory();
    if (mounted) {
      setState(() {});
      _persistTrades();
      _persistHistory();
    }
  }

  Future<double?> _fetchCurrentPrice(String coin) async {
    final normalizedCoin = CoinAccessPolicy.normalizeCoinSymbol(coin) ?? coin.trim().toUpperCase();
    try {
      final response = await http.get(
        Uri.parse('https://api.binance.com/api/v3/ticker/price?symbol=${normalizedCoin}USDT'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final price = _toDouble(data['price']);
        if (price != null && price > 0) return price;
      }
    } catch (_) {}

    // Expanded CoinGecko fallback for symbols not on Binance USDT pair.
    final coingeckoIdMap = {
      'BTC': 'bitcoin',
      'ETH': 'ethereum',
      'SOL': 'solana',
      'BNB': 'binancecoin',
      'XRP': 'ripple',
      'HYPE': 'hyperliquid',
      'RENDER': 'render-token',
      'RNDR': 'render-token',
      'WIF': 'dogwifcoin',
      'PEPE': 'pepe',
      'TAO': 'bittensor',
    };

    final geckoId = coingeckoIdMap[normalizedCoin];
    if (geckoId == null) return null;

    try {
      final response = await http.get(
        Uri.parse("https://api.coingecko.com/api/v3/simple/price?ids=$geckoId&vs_currencies=usd"),
      );
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final usd = (data[geckoId] as Map<String, dynamic>?)?["usd"];
      final price = _toDouble(usd);
      if (price != null && price > 0) return price;
    } catch (_) {
      return null;
    }
    return null;
  }

  void _syncTradeStatusToHistory() {
    for (final item in history) {
      if (item["source"] != "trade_setup") continue;
      final tradeId = item["tradeId"];
      final trade = trades.cast<Map<String, dynamic>?>().firstWhere(
            (t) => t != null && _historyIdsMatch(t['id'], tradeId),
            orElse: () => null,
          );
      if (trade == null) continue;
      item["tradeStatus"] = trade["status"];
    }
  }

  String _resolveDirection(String selectedDirection, double entry, double sl) {
    if (selectedDirection == "Long Only" || selectedDirection == "Short Only") {
      return selectedDirection;
    }
    return sl < entry ? "Long Only" : "Short Only";
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '').trim());
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedIndex == _tabHome) {
      final now = DateTime.now();
      final shouldRefresh = _lastTradeRefreshAt == null || now.difference(_lastTradeRefreshAt!) > const Duration(seconds: 20);
      if (shouldRefresh) {
        _lastTradeRefreshAt = now;
        Future.microtask(_refreshOpenTrades);
      }
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          HomeScreen(
            key: _homeKey,
            onCoinTap: goToCharts,
            watchlist: _watchlist,
            onAddWatchlistCoin: addToWatchlist,
            onRemoveWatchlistCoin: removeFromWatchlist,
            history: history,
            trades: trades,
            winRateText: winRateText,
            onViewReport: (item) {
              Navigator.push(
                context,
                _premiumPageRoute((_) => AnalysisReportScreen.fromHistory(item)),
              );
            },
            onDelete: deleteFromHistory,
            onDeleteTrade: deleteTradeById,
            resolveTradeHistory: _resolveHistoryForTrade,
            repairTradeHistoryLinks: _repairTradeHistoryLinks,
            onClearDailyAnalyses: clearDailyAnalyses,
            onRefreshDailyAnalyses: _refreshDailyAnalysesForHome,
            onCloseTrade: closeTradeWithExit,
          ),
          _CitadelScreen(
            isActive: _selectedIndex == _tabCitadel,
            onPositionClosed: ({required String coin, required double realizedPnl}) {
              recordCitadelRealizedClose(coin: coin, realizedPnl: realizedPnl);
            },
          ),
          TradeSetupScreen(
            coin: 'BTC',
            trades: trades,
            onTradeSetupGenerated: addTradeSetupResult,
          ),
          _OracleVisionTabScreen(
            isActive: _selectedIndex == _tabOracleVision,
            watchlist: _watchlist,
            trades: trades,
            history: history,
            onTradeSetupGenerated: addTradeSetupResult,
          ),
          _OracleDeskTabScreen(
            isActive: _selectedIndex == _tabOracleDesk,
            watchlist: _watchlist,
            trades: trades,
            history: history,
            onTradeSetupGenerated: addTradeSetupResult,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        backgroundColor: const Color(0xFF1A1A1A),
        selectedItemColor: const Color(0xFF00BFFF),
        unselectedItemColor: Colors.grey,
        selectedFontSize: 11,
        unselectedFontSize: 10,
        elevation: 12,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shield_outlined),
            activeIcon: Icon(Icons.shield),
            label: 'Citadel',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.gps_fixed_outlined),
            activeIcon: Icon(Icons.gps_fixed),
            label: 'Trade Setup',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.visibility_outlined),
            activeIcon: Icon(Icons.visibility),
            label: 'Oracle Vision',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_customize_outlined),
            activeIcon: Icon(Icons.dashboard_customize),
            label: 'Oracle Desk',
          ),
        ],
      ),
    );
  }
}
