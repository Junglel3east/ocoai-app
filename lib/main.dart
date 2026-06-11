/*
- Subscription tiers: Free (BTC/ETH/SOL), Premium (Top 150), Expert (any symbol)
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
import 'services/oracle_desk_service.dart';
import 'services/oracle_vision_service.dart';
import 'services/app_api_key_service.dart';
import 'services/auth_service.dart';
import 'services/social_links.dart';
import 'services/user_profile_store.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/login_screen.dart';
import 'screens/profile_screen.dart' show kProfileBackgroundOrbHeight, kProfileBackgroundOrbOpacity;
import 'widgets/ai_chat_entry.dart';
import 'widgets/background_illustration.dart';
import 'widgets/community_links_section.dart';
part 'screens/quick_analyze_screen.dart';
part 'screens/oracle_vision_screen.dart';
part 'screens/trade_setup_screen.dart';
part 'screens/trade_performance_screen.dart';
part 'screens/citadel_trade_levels.dart';
part 'screens/citadel_setup_dialog.dart';
part 'screens/citadel_live_positions.dart';
part 'screens/oracle_desk_screen.dart';

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

/// Lets WebView claim pan/pinch/zoom gestures (avoids parent ScrollView stealing touches).
final Set<Factory<OneSequenceGestureRecognizer>> kTradingViewGestureRecognizers = {
  Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
};

WebViewController createTradingViewController(String symbol) {
  final sym = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
  final tvSymbol = CoinAccessPolicy.resolveTradingViewSymbol(sym);

  late final PlatformWebViewControllerCreationParams params;
  if (WebViewPlatform.instance is WebKitWebViewPlatform) {
    params = WebKitWebViewControllerCreationParams(
      allowsInlineMediaPlayback: true,
      mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
    );
  } else {
    params = const PlatformWebViewControllerCreationParams();
  }

  final controller = WebViewController.fromPlatformCreationParams(params)
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFF0F0F0F));

  if (controller.platform is AndroidWebViewController) {
    final android = controller.platform as AndroidWebViewController;
    android.setMediaPlaybackRequiresUserGesture(true);
    android.setMixedContentMode(MixedContentMode.compatibilityMode);
  }

  controller.loadHtmlString(buildTradingViewHTML(sym, tvSymbol: tvSymbol));
  return controller;
}

/// Premium full-screen loading while Grok analysis / trade setup generates.
class _PremiumAiLoadingPanel extends StatelessWidget {
  final String title;
  final String subtitle;

  const _PremiumAiLoadingPanel({
    required this.title,
    this.subtitle = 'Powered by On-Chain Oracle AI',
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0F0F0F),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 88,
                height: 88,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.25), width: 2),
                      ),
                    ),
                    const SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Color(0xFF00BFFF),
                      ),
                    ),
                    Icon(Icons.auto_awesome, size: 22, color: Colors.grey[400]),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 18),
              Text(
                'Powered by On-Chain Oracle AI',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, letterSpacing: 0.2, color: Colors.grey[700]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared TradingView HTML — VWAP + EMA 5/20 + Auto Fib on main pane; RSI + MACD below.
String buildTradingViewHTML(String symbol, {String? tvSymbol}) {
  final sym = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
  final resolvedTvSymbol = tvSymbol ?? CoinAccessPolicy.resolveTradingViewSymbol(sym);
  return '''
    <html><head>
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
      <style>
        html, body { margin: 0; padding: 0; height: 100%; width: 100%; overflow: hidden; background: #0F0F0F; touch-action: none; }
        #tradingview { height: 100%; width: 100%; }
      </style>
    </head>
    <body>
      <div id="tradingview"></div>
      <script src="https://s3.tradingview.com/tv.js"></script>
      <script>
        new TradingView.widget({
          "autosize": true,
          "symbol": "$resolvedTvSymbol",
          "interval": "60",
          "timezone": "Etc/UTC",
          "theme": "dark",
          "style": "1",
          "locale": "en",
          "toolbar_bg": "#1A1A1A",
          "enable_publishing": false,
          "hide_side_toolbar": false,
          "allow_symbol_change": true,
          "hide_top_toolbar": false,
          "withdateranges": true,
          "range": "1M",
          "details": true,
          "hotlist": false,
          "calendar": false,
          "enabled_features": [
            "study_templates",
            "side_toolbar_in_fullscreen_mode",
            "header_chart_type",
            "header_settings",
            "header_indicators",
            "header_fullscreen_button",
            "header_compare",
            "header_undo_redo",
            "header_screenshot",
            "left_toolbar",
            "control_bar",
            "timeframes_toolbar",
            "chart_property_page",
            "context_menus",
            "pane_context_menu",
            "scales_context_menu",
            "legend_context_menu",
            "main_series_scale_menu",
            "use_localstorage_for_settings",
            "chart_zoom",
            "chart_scroll",
            "mouse_wheel_scroll",
            "pinch_scale",
            "axis_pressed_mouse_move_scale",
            "horz_touch_drag_scroll",
            "vert_touch_drag_scroll",
            "pressed_mouse_move_scroll",
            "show_zoom_and_move_icons_on_touch",
            "constraint_dialogs_movement"
          ],
          "disabled_features": [
            "header_symbol_search",
            "symbol_search_hot_key"
          ],
          "drawings_access": {
            "type": "white",
            "tools": [
              { "name": "Fib Retracement" },
              { "name": "Trend Line" },
              { "name": "Horizontal Line" }
            ]
          },
          "studies": [
            {"id": "VWAP@tv-basicstudies", "inputs": {"Anchor period": "Session"}},
            {"id": "MAExp@tv-basicstudies", "inputs": {"Length": 5}},
            {"id": "MAExp@tv-basicstudies", "inputs": {"Length": 20}},
            {"id": "AutoFibRetracement@tv-basicstudies"},
            "RSI@tv-basicstudies",
            "MACD@tv-basicstudies"
          ],
          "studies_overrides": {
            "paneProperties.background": "#0F0F0F",
            "paneProperties.backgroundType": "solid",
            "paneProperties.legendProperties.showLegend": true,
            "scalesProperties.textColor": "#9E9E9E",
            "mainSeriesProperties.candleStyle.upColor": "#26A69A",
            "mainSeriesProperties.candleStyle.downColor": "#EF5350",
            "mainSeriesProperties.candleStyle.borderUpColor": "#26A69A",
            "mainSeriesProperties.candleStyle.borderDownColor": "#EF5350",
            "mainSeriesProperties.candleStyle.wickUpColor": "#26A69A",
            "mainSeriesProperties.candleStyle.wickDownColor": "#EF5350",
            "vwap.color": "#AB47BC",
            "vwap.linewidth": 2,
            "MAExp@tv-basicstudies.plot.color": "#00E5FF",
            "MAExp@tv-basicstudies.plot.color[1]": "#FFB300",
            "MAExp@tv-basicstudies.plot.linewidth": 2,
            "MAExp@tv-basicstudies.plot.linewidth[1]": 2,
            "VWAP@tv-basicstudies.plot.color": "#AB47BC",
            "VWAP@tv-basicstudies.plot.linewidth": 2,
            "RSI@tv-basicstudies.rsi.color": "#7E57C2",
            "RSI@tv-basicstudies.rsi.linewidth": 2,
            "MACD.macd.color": "#00E5FF",
            "MACD.signal.color": "#FFB300",
            "MACD.histogram.color": "#26A69A",
            "auto_fib_retracement.color": "#FF9800"
          },
          "overrides": {
            "mainSeriesProperties.priceAxisProperties.autoScale": true,
            "mainSeriesProperties.priceAxisProperties.percentage": false,
            "mainSeriesProperties.priceAxisProperties.log": false,
            "paneProperties.vertGridProperties.color": "#1A1A1A",
            "paneProperties.horzGridProperties.color": "#1A1A1A"
          },
          "container_id": "tradingview",
          "support_host": "https://www.tradingview.com"
        });
      </script>
    </body></html>
    ''';
}

/// Map app timeframe labels to TradingView widget interval codes.
String tradingViewIntervalForTimeframe(String timeframe) {
  switch (timeframe.trim().toLowerCase()) {
    case '5m':
      return '5';
    case '10m':
      return '15';
    case '15m':
      return '15';
    case '20m':
      return '30';
    case '30m':
      return '30';
    case '1h':
      return '60';
    case '2h':
      return '120';
    case '4h':
      return '240';
    case '8h':
      return '480';
    case '1d':
      return 'D';
    default:
      return '60';
  }
}

/// Trade Setup chart — Heikin Ashi + Daily VWAP + Prev Day VWAP + Fib 0.382/0.5/0.618/0.786 only.
/// No EMAs, RSI, MACD, volume, or trade level lines (Entry/TP/SL stay in the report).
String buildTradeSetupTradingViewHTML(
  String symbol, {
  String? tvSymbol,
  required String timeframe,
}) {
  final sym = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
  final resolvedTvSymbol = tvSymbol ?? CoinAccessPolicy.resolveTradingViewSymbol(sym);
  final interval = tradingViewIntervalForTimeframe(timeframe);
  return '''
    <html><head>
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
      <style>
        html, body { margin: 0; padding: 0; height: 100%; width: 100%; overflow: hidden; background: #0F0F0F; touch-action: none; }
        #tradingview { height: 100%; width: 100%; }
      </style>
    </head>
    <body>
      <div id="tradingview"></div>
      <script src="https://s3.tradingview.com/tv.js"></script>
      <script>
        new TradingView.widget({
          "autosize": true,
          "symbol": "$resolvedTvSymbol",
          "interval": "$interval",
          "timezone": "Etc/UTC",
          "theme": "dark",
          "style": "8",
          "locale": "en",
          "toolbar_bg": "#1A1A1A",
          "enable_publishing": false,
          "hide_side_toolbar": true,
          "allow_symbol_change": false,
          "hide_top_toolbar": false,
          "withdateranges": true,
          "range": "1M",
          "details": false,
          "hotlist": false,
          "calendar": false,
          "enabled_features": [
            "side_toolbar_in_fullscreen_mode",
            "header_chart_type",
            "header_fullscreen_button",
            "timeframes_toolbar",
            "chart_zoom",
            "chart_scroll",
            "mouse_wheel_scroll",
            "pinch_scale",
            "axis_pressed_mouse_move_scale",
            "horz_touch_drag_scroll",
            "vert_touch_drag_scroll",
            "pressed_mouse_move_scroll",
            "show_zoom_and_move_icons_on_touch"
          ],
          "disabled_features": [
            "header_symbol_search",
            "symbol_search_hot_key",
            "header_indicators",
            "header_compare",
            "header_undo_redo",
            "header_screenshot",
            "left_toolbar",
            "control_bar",
            "chart_property_page",
            "context_menus",
            "pane_context_menu",
            "scales_context_menu",
            "legend_context_menu",
            "main_series_scale_menu",
            "use_localstorage_for_settings"
          ],
          "studies": [
            {"id": "VWAP@tv-basicstudies", "inputs": {"Anchor period": "Session"}},
            {"id": "AutoFibRetracement@tv-basicstudies"}
          ],
          "studies_overrides": {
            "paneProperties.background": "#0F0F0F",
            "paneProperties.backgroundType": "solid",
            "paneProperties.legendProperties.showLegend": true,
            "scalesProperties.textColor": "#9E9E9E",
            "mainSeriesProperties.haStyle.upColor": "#26A69A",
            "mainSeriesProperties.haStyle.downColor": "#EF5350",
            "mainSeriesProperties.haStyle.borderUpColor": "#26A69A",
            "mainSeriesProperties.haStyle.borderDownColor": "#EF5350",
            "mainSeriesProperties.haStyle.wickUpColor": "#26A69A",
            "mainSeriesProperties.haStyle.wickDownColor": "#EF5350",
            "VWAP@tv-basicstudies.plot.color": "#00E5FF",
            "VWAP@tv-basicstudies.plot.linewidth": 2,
            "auto_fib_retracement.trendline.color": "rgba(255,152,0,0.45)",
            "auto_fib_retracement.trendline.linewidth": 1,
            "auto_fib_retracement.level1.color": "#FF9800",
            "auto_fib_retracement.level2.color": "#00E676",
            "auto_fib_retracement.level3.color": "#26C6DA",
            "auto_fib_retracement.level4.color": "#2196F3",
            "auto_fib_retracement.level5.color": "#2196F3",
            "auto_fib_retracement.level6.color": "#2196F3",
            "auto_fib_retracement.level7.color": "#2196F3",
            "auto_fib_retracement.level1.coeff": 0.382,
            "auto_fib_retracement.level2.coeff": 0.5,
            "auto_fib_retracement.level3.coeff": 0.618,
            "auto_fib_retracement.level4.coeff": 0.786,
            "auto_fib_retracement.level5.visible": false,
            "auto_fib_retracement.level6.visible": false,
            "auto_fib_retracement.level7.visible": false,
            "auto_fib_retracement.level8.visible": false,
            "auto_fib_retracement.level9.visible": false,
            "auto_fib_retracement.level10.visible": false,
            "auto_fib_retracement.level11.visible": false
          },
          "overrides": {
            "mainSeriesProperties.priceAxisProperties.autoScale": true,
            "paneProperties.vertGridProperties.color": "#1A1A1A",
            "paneProperties.horzGridProperties.color": "#1A1A1A",
            "paneProperties.legendProperties.showStudyTitles": true,
            "paneProperties.legendProperties.showStudyValues": true
          },
          "container_id": "tradingview",
          "support_host": "https://www.tradingview.com"
        });
      </script>
    </body></html>
    ''';
}

WebViewController createTradeSetupTradingViewController(
  String symbol, {
  required String timeframe,
}) {
  final sym = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
  final tvSymbol = CoinAccessPolicy.resolveTradingViewSymbol(sym);

  late final PlatformWebViewControllerCreationParams params;
  if (WebViewPlatform.instance is WebKitWebViewPlatform) {
    params = WebKitWebViewControllerCreationParams(
      allowsInlineMediaPlayback: true,
      mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
    );
  } else {
    params = const PlatformWebViewControllerCreationParams();
  }

  final controller = WebViewController.fromPlatformCreationParams(params)
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFF0F0F0F));

  if (controller.platform is AndroidWebViewController) {
    final android = controller.platform as AndroidWebViewController;
    android.setMediaPlaybackRequiresUserGesture(true);
    android.setMixedContentMode(MixedContentMode.compatibilityMode);
  }

  controller.loadHtmlString(buildTradeSetupTradingViewHTML(
    sym,
    tvSymbol: tvSymbol,
    timeframe: timeframe,
  ));
  return controller;
}

/// Embedded chart with expand-to-fullscreen control (Analysis, Trade Setup, etc.).
class TradingViewChartPanel extends StatefulWidget {
  final String symbol;
  final WebViewController controller;
  final double height;
  final bool mountWebView;
  /// When set, fullscreen opens the same focused Trade Setup chart (Heikin Ashi + VWAP + Fib).
  final String? tradeSetupTimeframe;
  final bool premiumFrame;

  const TradingViewChartPanel({
    super.key,
    required this.symbol,
    required this.controller,
    this.height = 420,
    this.mountWebView = true,
    this.tradeSetupTimeframe,
    this.premiumFrame = false,
  });

  @override
  State<TradingViewChartPanel> createState() => _TradingViewChartPanelState();
}

class _TradingViewChartPanelState extends State<TradingViewChartPanel> {
  void _openFullScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FullScreenChartScreen(
          symbol: widget.symbol,
          tradeSetupTimeframe: widget.tradeSetupTimeframe,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chartStack = Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.premiumFrame ? 9 : 8),
            child: widget.mountWebView
                ? RepaintBoundary(
                    child: WebViewWidget(
                      controller: widget.controller,
                      gestureRecognizers: kTradingViewGestureRecognizers,
                    ),
                  )
                : const ColoredBox(color: Color(0xFF0F0F0F)),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: _FullScreenChartButton(onPressed: () => _openFullScreen(context)),
        ),
      ],
    );

    if (!widget.premiumFrame) {
      return SizedBox(height: widget.height, child: chartStack);
    }

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00BFFF).withValues(alpha: 0.10),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: chartStack,
    );
  }
}

class _FullScreenChartButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _FullScreenChartButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.fullscreen, color: Colors.white70, size: 22),
        ),
      ),
    );
  }
}

/// Full-screen modal chart with maximum viewport and close control.
class FullScreenChartScreen extends StatefulWidget {
  final String symbol;
  final String? tradeSetupTimeframe;

  const FullScreenChartScreen({
    super.key,
    required this.symbol,
    this.tradeSetupTimeframe,
  });

  @override
  State<FullScreenChartScreen> createState() => _FullScreenChartScreenState();
}

class _FullScreenChartScreenState extends State<FullScreenChartScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    final tf = widget.tradeSetupTimeframe;
    _controller = tf != null
        ? createTradeSetupTradingViewController(widget.symbol, timeframe: tf)
        : createTradingViewController(widget.symbol);
  }

  @override
  Widget build(BuildContext context) {
    final sym = widget.symbol.trim().toUpperCase();
    final tf = widget.tradeSetupTimeframe;
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(tf != null ? '$sym/USDT · $tf' : '$sym/USDT'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: WebViewWidget(
          controller: _controller,
          gestureRecognizers: kTradingViewGestureRecognizers,
        ),
      ),
    );
  }
}

/// Exact disclaimer required at the bottom of every AI report.
const String kReportDisclaimer =
    '**Disclaimer**: This is for informational and educational purposes only. Not financial advice. Always DYOR.';

/// Builds the Grok system prompt enforced for analysis and trade setup outputs.
String grokSystemPrompt({required String mode}) {
  const sharedRules = '''
You are On-Chain Oracle AI — a sharp crypto leverage trader explaining setups on stream. Voice: direct,
confident, technical but conversational. Not hedge-fund desk. Not tutorial. Not influencer hype.

TONE EXEMPLAR:
"BTC 1D reclaiming Daily VWAP with strong bid absorption + funding flipping positive. Clear liquidity sweep
below equal lows — strong LONG bias here."

═══════════════════════════════════════
NON-NEGOTIABLE RULES (never violate)
═══════════════════════════════════════

1. RISK:REWARD (HARD FLOOR)
   • Every actionable level set MUST achieve minimum 2.1:1 R:R on TP1 vs stop distance.
   • TARGET 2.3:1 or better on TP1 whenever structure allows.
   • NEVER publish setups below 2:1.
   • TRADE LEVELS format: Entry at \$X, TP1 (40%) at \$X, TP2 (60%) at \$X, SL at \$X (R:R X.X:1)
   • Show math: Reward = |TP1 − Entry|, Risk = |Entry − SL|, R:R = Reward ÷ Risk.
   • No valid ≥2.1:1 edge → omit TRADE LEVELS and call FLAT.

2. DISCLAIMER (EXACT — FINAL LINE ONLY)
$kReportDisclaimer

3. NO CHATBOT BEHAVIOR
   • No questions, upsells, or follow-ups.
   • No hedging filler ("might", "could", "perhaps", "maybe").
   • End: last section → disclaimer.

4. BANNED JARGON
   Never: session VWAP, previous session, tape, regime, fade, macro tape, weighted momentum, Oracle flow,
   balanced session, institutional desk voice.
   Use: Daily VWAP, Previous Day VWAP, liquidity sweep, inducement, order block, FVG, BOS, CHOCH,
   mitigation, displacement, reclaiming, sweeping, liquidity grab, previous highs/lows.

5. REQUIRED LEXICON
   liquidity sweep, inducement, order block, FVG, BOS, CHOCH, mitigation, displacement, reclaiming,
   sweeping, equal highs/lows, liquidity grab, invalidation, premium/discount, crowded longs/shorts,
   Daily VWAP, Previous Day VWAP.

═══════════════════════════════════════
ANALYTICAL FRAMEWORK
═══════════════════════════════════════

MTF: HTF (Daily/4h) bias → requested TF → LTF trigger. ALIGNED or CONFLICTED — name HTF veto.

VWAP: Daily VWAP, Previous Day VWAP, weekly, monthly — reclaiming/rejecting, premium/discount,
clusters ~0.3–0.8%. NEVER "session VWAP".

STRUCTURE: BOS/CHOCH, order blocks, FVGs, inducement, mitigation, displacement, previous highs/lows,
liquidity sweeps/grabs, sweeping + reclaiming.

MOMENTUM: EMA 5/20, RSI (>50 bull structure / <50 bear structure) with structure only, MACD, volume on breaks.

DERIVATIVES: funding flip, OI build, crowded side, liq cascade — woven into prose, never metric dump.

**Confluence Summary**: ONE sentence. STRONG / MODERATE / WEAK. Stream-trader verdict.

═══════════════════════════════════════
REPORT FORMAT
═══════════════════════════════════════

**Asset**: [COIN] | \$[PRICE] | [24h %]
**Overall Bias**: [Mildly Bullish / Mildly Bearish / Neutral] (Confidence: XX%)
**Key Drivers**: Volume-Weighted Analysis, Liquidity & Sentiment, Heikin Ashi, Fibonacci, Technicals, Market Structure
**Confluence Summary**: One decisive sentence.
**If I Were to Trade Today...**: Execution card — trigger, entry, invalidation, time box.
**Risks & Watchlist**: 2–3 bullets.
**TRADE LEVELS** (when applicable):
Entry at \$XXXXX, TP1 (40%) at \$XXXXX, TP2 (60%) at \$XXXXX, SL at \$XXXXX (R:R X.X:1)
''';

  if (mode == 'tradesetup') {
    return '''
$sharedRules
═══════════════════════════════════════
MODE: TRADE SETUP (execution-ready)
═══════════════════════════════════════

• Deliver ONE high-conviction directional setup (Long or Short per direction constraint).
• TRADE LEVELS section is MANDATORY — never omit.
• Entry must be justified by confluence (VWAP + structure + momentum alignment).
• SL must sit beyond invalidation structure — not arbitrary.
• TP1 must hit ≥2.1:1 R:R (target ≥2.3:1); TP2 extends toward next logical liquidity/structure target.
• "If I Were to Trade Today..." must read like a desk note: trigger, management hint, invalidation.
• Be decisive — if direction constraint forces Long Only or Short Only, commit fully; do not hedge both sides.
''';
  }

  return '''
$sharedRules
═══════════════════════════════════════
MODE: MARKET ANALYSIS (deep read)
═══════════════════════════════════════

• Primary goal: premium situational awareness — where price is, why it matters, what happens next.
• Include TRADE LEVELS only when confluence is MODERATE or STRONG and ≥2.1:1 TP1 R:R is achievable; otherwise omit the section entirely and explain why waiting is the edge.
• Depth over breadth: fewer, sharper insights beat generic indicator recitation.
• Always tie observations back to VWAP stack + MTF alignment.
• End with clear bias and what would flip it — traders should know exactly what they're watching.
''';
}

/// System prompt for Expert-plan Oracle Trader AI Chat (Grok).
String oracleTraderChatSystemPrompt() {
  return '''
You are Oracle Trader AI — a world-class, institutional-grade crypto trader and technical analyst with 20+ years of experience.

Your style is:
- Extremely sharp, concise, and decisive
- Professional but direct (no fluff, no generic answers)
- Strong emphasis on risk management, R:R, and probability
- Deep expertise in VWAP (multiple timeframes), Heikin Ashi, multi-timeframe analysis, Fibonacci, order flow, liquidity, market structure, and trader psychology

Always:
- Think step-by-step before answering (reason internally; output stays concise)
- Give clear, actionable insights
- Use realistic probability and risk assessment
- Never be overly bullish or bearish without strong evidence
- If the user asks for a trade idea, always include Entry, Stop Loss, TP1, TP2, and exact R:R ratio (minimum 2.1:1 on TP1; target 2.3:1+ when structure allows). Show the math.

You are helping serious traders make better decisions. Be honest, even if the setup is unclear or risky.

Current user is on the Top Tier / Expert Plan — deliver maximum value and depth.

CHAT MODE RULES:
- Conversational and responsive — not a full formal report unless the user asks for one.
- Use bullets or short paragraphs for clarity; avoid walls of text.
- Reference VWAP stack (session, previous session, weekly, monthly) and MTF alignment when relevant.
- No trailing questions or upsells. No "let me know if..." endings.
- Do NOT append the report disclaimer unless the user explicitly asks for a formal written report.
''';
}

// ─── AI Chat (Expert / Top Tier plan) ────────────────────────────────────────

abstract final class SubscriptionPlanStore {
  static const _planKey = 'subscription_plan';
  static const _homeChatHiddenKey = 'home_chat_fab_hidden';

  static String currentPlan = 'Free';

  static bool get hasExpertChatAccess {
    final plan = currentPlan.trim().toLowerCase();
    return plan == 'expert' || plan == 'top tier';
  }

  static bool get isExpert => hasExpertChatAccess;

  static bool get isPremium {
    final plan = currentPlan.trim().toLowerCase();
    return plan == 'premium';
  }

  static bool get isFree => !isPremium && !isExpert;

  static bool get isPremiumOrHigher => isPremium || isExpert;

  static bool get hasOracleVisionAccess => isPremiumOrHigher;

  static bool get hasOracleDeskAccess => isExpert;

  static bool get hasCitadelAccess => isExpert;

  static bool get hasAiChatAccess => isPremiumOrHigher;

  static bool get hasUnlimitedAiChat => isExpert;

  static const int freeWatchlistMax = 5;

  static const int freeTradeSetupsPerDay = 3;

  static const String freeTradeSetupTimeframe = '1d';

  static const Duration freeTradeSetupWindow = Duration(hours: 24);

  static const int premiumChatMessagesPerDay = 10;

  static const _premiumChatDayKey = 'premium_chat_day';

  static const _premiumChatCountKey = 'premium_chat_count';

  static String _localDayKey([DateTime? dt]) {
    final local = (dt ?? DateTime.now()).toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  static bool canAddWatchlistCoin(int currentCount) {
    if (!isFree) return true;
    return currentCount < freeWatchlistMax;
  }

  static bool isFreeAllowedTradeSetupTimeframe(String timeframe) {
    final tf = timeframe.trim().toLowerCase();
    return tf == '1d' || tf == 'daily' || tf == 'd1';
  }

  static int countTradeSetupsInWindow(List<Map<String, dynamic>> trades) {
    final cutoff = DateTime.now().subtract(freeTradeSetupWindow);
    return trades.where((t) {
      final created = DateTime.tryParse(t['createdAt']?.toString() ?? '');
      if (created == null) return false;
      return !created.isBefore(cutoff);
    }).length;
  }

  static bool canGenerateTradeSetup(List<Map<String, dynamic>> trades) {
    if (!isFree) return true;
    return countTradeSetupsInWindow(trades) < freeTradeSetupsPerDay;
  }

  static bool canUseAlertType(String type) {
    if (!isFree) return true;
    return type == 'Price';
  }

  static Future<bool> canSendChatMessage() async {
    if (isExpert) return true;
    if (!isPremium) return false;
    final prefs = await SharedPreferences.getInstance();
    final today = _localDayKey();
    final storedDay = prefs.getString(_premiumChatDayKey) ?? '';
    final count = storedDay == today ? (prefs.getInt(_premiumChatCountKey) ?? 0) : 0;
    return count < premiumChatMessagesPerDay;
  }

  static Future<void> recordPremiumChatMessage() async {
    if (!isPremium || isExpert) return;
    final prefs = await SharedPreferences.getInstance();
    final today = _localDayKey();
    final storedDay = prefs.getString(_premiumChatDayKey) ?? '';
    var count = storedDay == today ? (prefs.getInt(_premiumChatCountKey) ?? 0) : 0;
    count++;
    await prefs.setString(_premiumChatDayKey, today);
    await prefs.setInt(_premiumChatCountKey, count);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    currentPlan = prefs.getString(_planKey) ?? 'Free';
  }

  static Future<void> setPlan(String plan) async {
    currentPlan = plan;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_planKey, plan);
    await UserProfileStore.saveTier(plan);
  }

  static Future<bool> isHomeChatFabHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_homeChatHiddenKey) ?? false;
  }

  static Future<void> setHomeChatFabHidden(bool hidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_homeChatHiddenKey, hidden);
  }
}

// ─── Oracle Citadel (Expert automated trading) ───────────────────────────────

abstract final class OracleCitadelStore {
  static const _userIdKey = 'citadel_user_id';
  static const _apiKeyKey = 'citadel_api_key';
  static const _riskPercentKey = 'citadel_risk_percent';
  static const _leverageKey = 'citadel_leverage';
  static const _demoModeKey = 'citadel_use_demo_mode';

  static String userId = 'demo_user';
  static String apiKey = '';
  static double defaultRiskPercent = 1.0;
  static double defaultLeverage = 5.0;
  /// BloFin Demo is the default — demo API keys only work against the demo host.
  static bool useDemoMode = true;

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
  }

  static Future<void> saveDemoMode(bool enabled) async {
    useDemoMode = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_demoModeKey, enabled);
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

/// Optional Citadel user id for analyze/live_price — enables BloFin mark price when linked.
Map<String, dynamic> _analyzeCitadelContext() {
  if (!OracleCitadelStore.isConfigured) return const {};
  return {'user_id': OracleCitadelStore.userId};
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
  }) async {
    final uri = Uri.parse('$kCitadelBaseUrl/exchange_keys');
    final response = await http
        .post(
          uri,
          headers: await _authHeaders(),
          body: jsonEncode({
            'user_id': userId,
            'app_api_key': OracleCitadelStore.apiKey,
            'api_key': exchangeApiKey,
            'api_secret': exchangeApiSecret,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) return;

    final friendly = _parseUserMessage(response) ??
        'Could not save exchange keys (${response.statusCode}).';
    throw OracleCitadelException(friendly);
  }

  /// Confirms exchange keys exist on the Railway server (not just local prefs).
  static Future<CitadelServerLinkStatus> checkServerLinked() async {
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
        await OracleCitadelStore.markExchangeLinked(true);
        return const CitadelServerLinkStatus(linked: true);
      }

      final message = body['user_message']?.toString() ??
          _parseUserMessage(response) ??
          'Exchange keys not found on server. Re-link BloFin keys in Oracle Citadel Setup.';
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
      friendly = '$friendly\n\nWhitelist this IP in BloFin Demo → API Management: $whitelistIp';
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
      friendly = '$friendly\n\nWhitelist this IP in BloFin Demo → API Management: $whitelistIp';
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
  if (!context.mounted) return;
  final rootContext = Navigator.of(context, rootNavigator: true).context;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Executing MARKET ${direction.toUpperCase()} on $coin…'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
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
    if (!context.mounted) return;
    if (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch') {
      await OracleCitadelStore.clearExchangeLinked();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch')
            ? SnackBarAction(
                label: 'Setup',
                textColor: Colors.white,
                onPressed: () => showCitadelSetupDialog(context),
              )
            : null,
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('MARKET order failed. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
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
  if (!context.mounted) return;
  final rootContext = Navigator.of(context, rootNavigator: true).context;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Placing LIMIT ${direction.toUpperCase()} on $coin at ${_formatCitadelPrice(plannedEntry)}…',
      ),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
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
    if (!context.mounted) return;
    if (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch') {
      await OracleCitadelStore.clearExchangeLinked();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: (e.errorCode == 'credentials_missing' || e.errorCode == 'credentials_mismatch')
            ? SnackBarAction(
                label: 'Setup',
                textColor: Colors.white,
                onPressed: () => showCitadelSetupDialog(context),
              )
            : null,
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('LIMIT order failed. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
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
                            OracleCitadelStore.useDemoMode
                                ? 'Market or Limit · BloFin Demo'
                                : 'Market or Limit · BloFin LIVE',
                            style: const TextStyle(fontSize: 13, color: Colors.grey),
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
                ),
                const SizedBox(height: 16),
                _CitadelExecutionOptionTile(
                  icon: Icons.rocket_launch_rounded,
                  iconColor: const Color(0xFF43A047),
                  title: 'Execute as MARKET Order NOW',
                  subtitle:
                      'Enter immediately at the current market price on BloFin. '
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
                    _sendMarketOrder(
                      context,
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
                      'Rest on the BloFin order book at ${_formatCitadelPrice(plannedEntry)}. '
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
                    _sendLimitOrder(
                      context,
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
                                    ? '$displayCoin $displayDirection · BloFin Position'
                                    : '$displayCoin $displayDirection · BloFin Open Orders',
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
                      ? 'Your limit filled immediately on BloFin. TP1 (40%) and TP2 (60%) legs were attached when possible.'
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
                                '$displayCoin $displayDirection · BloFin',
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

  static const _riskPresets = [1, 5, 10, 25, 50, 100];

  const _CitadelLeverageRiskPanel({
    required this.leverage,
    required this.onLeverageChanged,
    required this.riskPercent,
    required this.onRiskPercentChanged,
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
      title: const Text('Expert Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Automated trading via Oracle Citadel is available on the Expert (Top Tier) plan. '
        'Upgrade to send AI trade setups directly to the secure execution backend.',
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
    }
  }

  void _clearSendError() {
    if (_sendErrorMessage == null) return;
    setState(() => _sendErrorMessage = null);
  }

  Future<void> _onPressed() async {
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

    var linkStatus = await OracleCitadelService.checkServerLinked();
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

enum CoinAccessDenial { invalidSymbol, freeTierLimit, premiumTop150Limit }

class CoinAccessResult {
  final String? coin;
  final CoinAccessDenial? denial;

  const CoinAccessResult._(this.coin, this.denial);

  bool get allowed => coin != null && denial == null;

  factory CoinAccessResult.allowed(String coin) => CoinAccessResult._(coin, null);

  factory CoinAccessResult.denied(CoinAccessDenial reason, {String? coin}) =>
      CoinAccessResult._(coin, reason);
}

abstract final class CoinAccessPolicy {
  static const freeCoins = {'BTC', 'ETH', 'SOL'};

  /// Top ~150 tradable symbols by market cap (Expert unlocks anything beyond this).
  static const top150Coins = {
    '1INCH', 'AAVE', 'ADA', 'AGIX', 'AKT', 'ALGO', 'ANKR', 'APE', 'API3', 'APT',
    'ARB', 'ARKM', 'ASTR', 'ATOM', 'AUDIO', 'AVAX', 'AXS', 'BAND', 'BAT', 'BCH',
    'BEAM', 'BLUR', 'BNB', 'BONK', 'BRETT', 'BSV', 'BTC', 'BTT', 'CAKE', 'CATI',
    'CELO', 'CFX', 'CHZ', 'CKB', 'COMP', 'CORE', 'CRO', 'CRV', 'CVX', 'DASH',
    'DOGE', 'DOGS', 'DOT', 'DYDX', 'EGLD', 'EIGEN', 'ENA', 'ENJ', 'ENS', 'EOS',
    'ETH', 'ETHFI', 'FET', 'FIL', 'FLR', 'FLOKI', 'FLOW', 'FTM', 'FXS', 'GALA',
    'GLMR', 'GMT', 'GMX', 'GRT', 'HBAR', 'HIGH', 'HMSTR', 'HNT', 'HOT', 'ICP',
    'ICX', 'ILV', 'IMX', 'INJ', 'IOST', 'IOTA', 'JASMY', 'JUP', 'KAS', 'KAVA',
    'KLAY', 'KCS', 'KSM', 'LDO', 'LEO', 'LINK', 'LRC', 'LTC', 'LUNA', 'LUNC',
    'MAGIC', 'MANA', 'MASK', 'MATIC', 'MEW', 'MINA', 'MKR', 'MOG', 'MOVR', 'NEAR',
    'NEO', 'NOT', 'OCEAN', 'OKB', 'ONDO', 'OP', 'ORDI', 'OSMO', 'PENDLE', 'PEPE',
    'POL', 'POPCAT', 'PYTH', 'QNT', 'QTUM', 'RAY', 'RENDER', 'RNDR', 'RON', 'ROSE',
    'RPL', 'RUNE', 'RVN', 'SAND', 'SC', 'SEI', 'SKL', 'SNX', 'SOL', 'SPELL',
    'SSV', 'STEEM', 'STG', 'STORJ', 'STRK', 'STX', 'SUI', 'SUPER', 'SUSHI', 'TAO',
    'TFUEL', 'THETA', 'TIA', 'TON', 'TRX', 'TURBO', 'UMA', 'UNI', 'VET', 'W',
    'WAVES', 'WIF', 'WLD', 'WOO', 'XDC', 'XLM', 'XMR', 'XRP', 'XTZ', 'YFI',
    'ZEC', 'ZEN', 'ZIL', 'ZRX',
  };

  static const _symbolAliases = {
    'RENDER': 'RNDR',
    'POLYGON': 'POL',
    'MATICUSD': 'POL',
    'HYPERLIQUID': 'HYPE',
  };

  /// Preferred TradingView exchange pairs for symbols that may not use Binance USDT.
  static const _tradingViewSymbolOverrides = {
    'HYPE': 'BYBIT:HYPEUSDT',
    'WIF': 'BINANCE:WIFUSDT',
    'PEPE': 'BINANCE:PEPEUSDT',
    'BONK': 'BINANCE:BONKUSDT',
    'FLOKI': 'BINANCE:FLOKIUSDT',
    'TAO': 'BINANCE:TAOUSDT',
    'RENDER': 'BINANCE:RNDRUSDT',
    'RNDR': 'BINANCE:RNDRUSDT',
  };

  static const _coinDisplayNames = {
    'BTC': 'Bitcoin',
    'ETH': 'Ethereum',
    'SOL': 'Solana',
    'BNB': 'BNB',
    'XRP': 'XRP',
    'ADA': 'Cardano',
    'DOGE': 'Dogecoin',
    'AVAX': 'Avalanche',
    'DOT': 'Polkadot',
    'LINK': 'Chainlink',
    'MATIC': 'Polygon',
    'POL': 'Polygon',
    'UNI': 'Uniswap',
    'ATOM': 'Cosmos',
    'LTC': 'Litecoin',
    'NEAR': 'NEAR Protocol',
    'APT': 'Aptos',
    'ARB': 'Arbitrum',
    'OP': 'Optimism',
    'INJ': 'Injective',
    'SUI': 'Sui',
    'SEI': 'Sei',
    'TIA': 'Celestia',
    'PEPE': 'Pepe',
    'WIF': 'dogwifhat',
    'HYPE': 'Hyperliquid',
    'RENDER': 'Render',
    'RNDR': 'Render',
    'TAO': 'Bittensor',
    'JUP': 'Jupiter',
    'FET': 'Fetch.ai',
    'FIL': 'Filecoin',
    'AAVE': 'Aave',
    'MKR': 'Maker',
    'CRV': 'Curve',
    'LDO': 'Lido DAO',
    'RUNE': 'THORChain',
    'STX': 'Stacks',
    'IMX': 'Immutable X',
    'GRT': 'The Graph',
    'SAND': 'The Sandbox',
    'MANA': 'Decentraland',
    'AXS': 'Axie Infinity',
    'EGLD': 'MultiversX',
    'KAS': 'Kaspa',
    'TON': 'Toncoin',
    'TRX': 'TRON',
    'SHIB': 'Shiba Inu',
    'BCH': 'Bitcoin Cash',
    'ETC': 'Ethereum Classic',
    'XLM': 'Stellar',
    'HBAR': 'Hedera',
  };

  static const _popularSymbols = ['BTC', 'ETH', 'SOL', 'BNB', 'XRP', 'DOGE', 'AVAX', 'HYPE'];

  static String displayName(String symbol) => _coinDisplayNames[symbol] ?? symbol;

  static String resolveTradingViewSymbol(String raw) {
    final base = normalizeCoinSymbol(raw) ?? raw.trim().toUpperCase();
    return _tradingViewSymbolOverrides[base] ?? 'BINANCE:${base}USDT';
  }

  /// Coins browsable in the watchlist search for the current subscription tier.
  static List<String> browseableCoins() {
    if (SubscriptionPlanStore.isExpert || SubscriptionPlanStore.isPremium) {
      return top150Coins.toList()..sort();
    }
    return freeCoins.toList()..sort();
  }

  static List<String> popularForTier() {
    final allowed = browseableCoins().toSet();
    final popular = _popularSymbols.where(allowed.contains).toList();
    if (SubscriptionPlanStore.isExpert && !popular.contains('HYPE')) {
      popular.add('HYPE');
    }
    return popular;
  }

  static List<String> searchCoins(String query) {
    final q = query.trim().toUpperCase();
    final pool = browseableCoins();
    if (q.isEmpty) return pool;

    return pool.where((symbol) {
      final name = displayName(symbol).toUpperCase();
      return symbol.contains(q) || name.contains(q);
    }).toList();
  }

  /// Expert-only: resolve a custom symbol not in the Top 150 browse list.
  static String? resolveCustomSearchSymbol(String query) {
    if (!SubscriptionPlanStore.isExpert) return null;
    return normalizeCoinSymbol(query);
  }

  /// Normalizes user input into a base ticker (e.g. "btc/usdt" → "BTC", "\$HYPE" → "HYPE").
  static String? normalizeCoinSymbol(String raw) {
    var s = raw.trim().toUpperCase();
    if (s.isEmpty) return null;

    s = s.replaceFirst(RegExp(r'^\$+'), '');
    s = s.replaceAll(RegExp(r'\s+'), '');

    if (s.contains('/')) s = s.split('/').first.trim();
    if (s.contains('-')) s = s.split('-').first.trim();
    if (s.contains(':')) s = s.split(':').last.trim();

    if (s.endsWith('USDT') && s.length > 4) {
      s = s.substring(0, s.length - 4);
    } else if (s.endsWith('USD') && s.length > 3) {
      s = s.substring(0, s.length - 3);
    }

    s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (s.isEmpty || s.length < 2 || s.length > 15) return null;

    return _symbolAliases[s] ?? s;
  }

  static CoinAccessResult evaluate(String raw) {
    final coin = normalizeCoinSymbol(raw);
    if (coin == null) {
      return CoinAccessResult.denied(CoinAccessDenial.invalidSymbol);
    }

    if (SubscriptionPlanStore.isExpert) {
      return CoinAccessResult.allowed(coin);
    }

    if (SubscriptionPlanStore.isPremium) {
      if (top150Coins.contains(coin)) {
        return CoinAccessResult.allowed(coin);
      }
      return CoinAccessResult.denied(CoinAccessDenial.premiumTop150Limit, coin: coin);
    }

    if (freeCoins.contains(coin)) {
      return CoinAccessResult.allowed(coin);
    }
    return CoinAccessResult.denied(CoinAccessDenial.freeTierLimit, coin: coin);
  }

  static String tierCoinHint() {
    if (SubscriptionPlanStore.isExpert) {
      return 'Any symbol — e.g. BTC, HYPE, PEPE';
    }
    if (SubscriptionPlanStore.isPremium) {
      return 'Top 150 coins — e.g. BTC, SOL, AVAX';
    }
    return 'Free plan: BTC, ETH, SOL only';
  }

  /// Free tier: BTC / ETH / SOL only on Home Daily Analysis.
  static List<Map<String, dynamic>> filterDailyAnalysesForPlan(
    List<Map<String, dynamic>> rows,
  ) {
    if (SubscriptionPlanStore.isPremiumOrHigher) return rows;
    return rows.where((r) {
      final coin = normalizeCoinSymbol(r['coin']?.toString() ?? '') ?? '';
      return freeCoins.contains(coin);
    }).toList();
  }

  static List<Map<String, dynamic>> filterDailyAnalysesInHistory(
    List<Map<String, dynamic>> history,
  ) {
    if (SubscriptionPlanStore.isPremiumOrHigher) return history;
    return history.where((item) {
      if (item['source'] != 'analysis') return true;
      final coin = normalizeCoinSymbol(item['coin']?.toString() ?? '') ?? '';
      return freeCoins.contains(coin);
    }).toList();
  }
}

Future<String?> resolveCoinForCurrentPlan(
  BuildContext context,
  String raw, {
  bool showDialogs = true,
}) async {
  await SubscriptionPlanStore.load();
  final result = CoinAccessPolicy.evaluate(raw);
  if (result.allowed) return result.coin;

  if (!showDialogs || !context.mounted) return null;

  switch (result.denial) {
    case CoinAccessDenial.invalidSymbol:
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid ticker (2–15 letters/numbers), e.g. BTC or HYPE.'),
        ),
      );
    case CoinAccessDenial.freeTierLimit:
      _showPremiumCoinUpgradePrompt(context, result.coin ?? raw);
    case CoinAccessDenial.premiumTop150Limit:
      _showExpertCoinUpgradePrompt(context, result.coin ?? raw);
    case null:
      break;
  }
  return null;
}

void _showPremiumCoinUpgradePrompt(BuildContext context, String coin) {
  final normalized = CoinAccessPolicy.normalizeCoinSymbol(coin) ?? coin.toUpperCase();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Premium Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Your Free plan includes BTC, ETH, and SOL only.\n\n'
        '$normalized is outside the Free tier. Upgrade to Premium (\$39/mo) for Top 150 coin coverage.',
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
            'View Premium',
            style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

void _showExpertCoinUpgradePrompt(BuildContext context, String coin) {
  final normalized = CoinAccessPolicy.normalizeCoinSymbol(coin) ?? coin.toUpperCase();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Expert Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        '$normalized is not in the Top 150 coin list included with Premium.\n\n'
        'Upgrade to Expert (\$79/mo) to analyze any symbol — including new and emerging coins like HYPE.',
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
            'Upgrade to Expert',
            style: TextStyle(color: Color(0xFFFFB74D), fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// TradingView-style symbol search — watchlist add or pick-only (Trade Setup / Analyze).
class WatchlistCoinSearchScreen extends StatefulWidget {
  final List<String> existingWatchlist;
  final ValueChanged<String> onCoinSelected;
  final bool pickOnly;
  final String title;

  const WatchlistCoinSearchScreen({
    super.key,
    required this.existingWatchlist,
    required this.onCoinSelected,
    this.pickOnly = false,
    this.title = 'Add Symbol',
  });

  @override
  State<WatchlistCoinSearchScreen> createState() => _WatchlistCoinSearchScreenState();
}

class _WatchlistCoinSearchScreenState extends State<WatchlistCoinSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<String> _filtered = [];
  List<String> _popular = [];
  String _tierHint = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadTierData();
  }

  Future<void> _loadTierData() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() {
      _filtered = CoinAccessPolicy.browseableCoins();
      _popular = CoinAccessPolicy.popularForTier();
      _tierHint = CoinAccessPolicy.tierCoinHint();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _filtered = CoinAccessPolicy.searchCoins(_searchController.text);
    });
  }

  String? get _customExpertSymbol {
    final custom = CoinAccessPolicy.resolveCustomSearchSymbol(_searchController.text);
    if (custom == null) return null;
    if (CoinAccessPolicy.top150Coins.contains(custom)) return null;
    if (_filtered.contains(custom)) return null;
    return custom;
  }

  Future<void> _selectCoin(String raw) async {
    final coin = await resolveCoinForCurrentPlan(context, raw);
    if (coin == null || !mounted) return;
    if (!widget.pickOnly && widget.existingWatchlist.contains(coin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$coin is already in your watchlist')),
      );
      return;
    }
    widget.onCoinSelected(coin);
    Navigator.pop(context, widget.pickOnly ? coin : null);
  }

  @override
  Widget build(BuildContext context) {
    final customSymbol = _customExpertSymbol;
    final query = _searchController.text.trim();

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: Text(widget.title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 4, _AppSpacing.screen, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'Search symbol or name…',
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00BFFF)),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.clear, color: Colors.grey[500]),
                        onPressed: () {
                          _searchController.clear();
                          FocusScope.of(context).requestFocus(FocusNode());
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF1A1A1A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFF00BFFF)),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _AppSpacing.screen),
            child: Text(_tierHint, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ),
          if (query.isEmpty && _popular.isNotEmpty) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _AppSpacing.screen),
              child: Text('Popular', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[400])),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _AppSpacing.screen),
                itemCount: _popular.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final symbol = _popular[index];
                  final inList = widget.existingWatchlist.contains(symbol);
                  return ActionChip(
                    label: Text(symbol),
                    backgroundColor: inList
                        ? Colors.white.withValues(alpha: 0.06)
                        : const Color(0xFF00BFFF).withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      color: inList ? Colors.grey[600] : const Color(0xFF00BFFF),
                      fontWeight: FontWeight.w600,
                    ),
                    onPressed: (!widget.pickOnly && inList) ? null : () => _selectCoin(symbol),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _AppSpacing.screen),
            child: Text(
              query.isEmpty ? 'Top markets' : 'Results (${_filtered.length})',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[400]),
            ),
          ),
          const SizedBox(height: 8),
          if (customSymbol != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 0, _AppSpacing.screen, 8),
              child: Material(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFFFB74D).withValues(alpha: 0.18),
                    child: const Icon(Icons.bolt, color: Color(0xFFFFB74D), size: 20),
                  ),
                  title: Text('Add $customSymbol', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    CoinAccessPolicy.resolveTradingViewSymbol(customSymbol),
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  trailing: const Icon(Icons.add_circle_outline, color: Color(0xFFFFB74D)),
                  onTap: () => _selectCoin(customSymbol),
                ),
              ),
            ),
          Expanded(
            child: _filtered.isEmpty
                ? _AppEmptyState(
                    icon: Icons.search_off_outlined,
                    title: query.isEmpty ? 'No symbols' : 'No matches',
                    subtitle: SubscriptionPlanStore.isExpert
                        ? 'Try a different query or type a custom symbol like HYPE.'
                        : 'Try another symbol from your plan\'s coin list.',
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 0, _AppSpacing.screen, 24),
                    itemCount: _filtered.length,
                    itemBuilder: (context, index) {
                      final symbol = _filtered[index];
                      final inList = widget.existingWatchlist.contains(symbol);
                      final name = CoinAccessPolicy.displayName(symbol);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(14),
                          child: ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
                            ),
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                              child: Text(
                                symbol.length >= 2 ? symbol.substring(0, 2) : symbol,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF00BFFF),
                                ),
                              ),
                            ),
                            title: Text(symbol, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              '$name · ${CoinAccessPolicy.resolveTradingViewSymbol(symbol)}',
                              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                            ),
                            trailing: inList
                                ? Icon(Icons.check_circle, color: Colors.grey[600], size: 22)
                                : const Icon(Icons.add, color: Color(0xFF00BFFF)),
                            onTap: (!widget.pickOnly && inList) ? null : () => _selectCoin(symbol),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full symbol search modal — same UI as watchlist Add Symbol; returns chosen ticker.
Future<String?> showCoinSymbolSearchModal(BuildContext context, {String? currentSymbol}) {
  final normalized = currentSymbol != null && currentSymbol.trim().isNotEmpty
      ? (CoinAccessPolicy.normalizeCoinSymbol(currentSymbol) ?? currentSymbol.trim().toUpperCase())
      : null;
  return Navigator.push<String>(
    context,
    _premiumPageRoute(
      (_) => WatchlistCoinSearchScreen(
        existingWatchlist: normalized != null ? [normalized] : const [],
        pickOnly: true,
        title: 'Select Symbol',
        onCoinSelected: (_) {},
      ),
    ),
  );
}

Future<void> openAiChat(BuildContext context) async {
  await SubscriptionPlanStore.load();
  if (!SubscriptionPlanStore.hasAiChatAccess) {
    if (context.mounted) _showChatUpgradePrompt(context, minimumTier: 'Premium');
    return;
  }
  if (SubscriptionPlanStore.isPremium && !await SubscriptionPlanStore.canSendChatMessage()) {
    if (context.mounted) _showChatDailyLimitPrompt(context);
    return;
  }
  if (context.mounted) {
    Navigator.push(context, _premiumPageRoute((_) => const ChatScreen()));
  }
}

void _showWatchlistLimitPrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Watchlist Limit Reached', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Free plan includes up to ${SubscriptionPlanStore.freeWatchlistMax} watchlist coins. '
        'Upgrade to Premium for full Top 150 coverage.',
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

/// Free tier gate — Daily TF, BTC/ETH/SOL, 3 setups / 24h. Shows upgrade prompts when blocked.
Future<bool> ensureFreeTradeSetupAllowed(
  BuildContext context, {
  required String coin,
  required String timeframe,
  required List<Map<String, dynamic>> trades,
}) async {
  await SubscriptionPlanStore.load();
  if (!SubscriptionPlanStore.isFree) return true;

  if (!SubscriptionPlanStore.isFreeAllowedTradeSetupTimeframe(timeframe)) {
    if (context.mounted) showTradeSetupTimeframeUpgradePrompt(context);
    return false;
  }

  final coinResult = CoinAccessPolicy.evaluate(coin);
  if (!coinResult.allowed) {
    if (context.mounted) {
      await resolveCoinForCurrentPlan(context, coin);
    }
    return false;
  }

  if (!SubscriptionPlanStore.canGenerateTradeSetup(trades)) {
    if (context.mounted) showTradeSetupLimitPrompt(context);
    return false;
  }

  return true;
}

void showTradeSetupTimeframeUpgradePrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Premium Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Free plan trade setups are limited to the Daily (1D) timeframe on BTC, ETH, and SOL.\n\n'
        'Upgrade to Premium for all timeframes and Top 150 coins, or Expert for unlimited access.',
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

void showTradeSetupLimitPrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('24-Hour Limit Reached', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Free plan includes ${SubscriptionPlanStore.freeTradeSetupsPerDay} Daily trade setups '
        'on BTC, ETH, and SOL every 24 hours.\n\n'
        'Upgrade to Premium or Expert for unlimited setups and more timeframes.',
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

void _showChatUpgradePrompt(BuildContext context, {required String minimumTier}) {
  final premiumGate = minimumTier == 'Premium';
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        premiumGate ? 'Premium Plan Required' : 'Expert Plan Required',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      content: Text(
        premiumGate
            ? 'Oracle AI Chat is available on Premium (limited) and Expert (unlimited) plans. '
                'Upgrade to unlock real-time AI assistance for your analyses and trade setups.'
            : 'Unlimited Oracle AI Chat is available on the Expert (Top Tier) plan.',
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

void _showChatDailyLimitPrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Daily Chat Limit Reached', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Premium includes ${SubscriptionPlanStore.premiumChatMessagesPerDay} AI chat messages per day. '
        'Upgrade to Expert for unlimited Oracle Trader AI Chat.',
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

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, String>> _messages = [
    {
      'role': 'assistant',
      'text':
          'Oracle Trader AI online. Ask about structure, VWAP confluence, MTF alignment, trade logic, or risk — I\'ll give you a direct, actionable read.',
    },
  ];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.hasAiChatAccess) {
      if (mounted) _showChatUpgradePrompt(context, minimumTier: 'Premium');
      return;
    }
    if (SubscriptionPlanStore.isPremium && !await SubscriptionPlanStore.canSendChatMessage()) {
      if (mounted) _showChatDailyLimitPrompt(context);
      return;
    }

    setState(() {
      _sending = true;
      _messages.add({'role': 'user', 'text': text});
      _controller.clear();
    });
    _scrollToBottom();

    try {
      final history = _messages
          .sublist(0, _messages.length - 1)
          .map((m) => {'role': m['role']!, 'content': m['text']!})
          .toList();

      final response = await _postChatWithRetry(
        message: text,
        history: history,
        systemPrompt: oracleTraderChatSystemPrompt(),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final reply = (data['reply'] ?? '').toString().trim();
        await SubscriptionPlanStore.recordPremiumChatMessage();
        if (mounted) {
          setState(() {
            _messages.add({
              'role': 'assistant',
              'text': reply.isNotEmpty ? reply : 'No response received. Please try again.',
            });
          });
        }
      } else {
        debugPrint('[Chat] HTTP ${response.statusCode}: ${response.body}');
        if (mounted) {
          setState(() {
            _messages.add({
              'role': 'assistant',
              'text': 'Unable to reach Oracle Trader AI right now. Check your connection and retry.',
            });
          });
        }
      }
    } catch (e) {
      debugPrint('[Chat] Request failed: $e');
      if (mounted) {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'text': 'Connection error. Ensure the backend is running and try again.',
          });
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text('Oracle Trader AI'),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(_AppSpacing.screen),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (context, index) {
                if (_sending && index == _messages.length) {
                  return const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                      ),
                    ),
                  );
                }
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                    decoration: BoxDecoration(
                      color: isUser
                          ? const Color(0xFF00BFFF).withValues(alpha: 0.18)
                          : const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                    ),
                    child: Text(msg['text'] ?? '', style: const TextStyle(height: 1.45)),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 8, _AppSpacing.screen, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_sending,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Ask Oracle Trader AI...',
                        prefixIcon: Icon(Icons.auto_awesome, color: Color(0xFF00BFFF), size: 20),
                      ),
                      onSubmitted: _sending ? null : (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FloatingActionButton.small(
                    heroTag: 'chat_send',
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    onPressed: _sending ? null : _sendMessage,
                    child: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── UI polish tokens & helpers (visual only) ───────────────────────────────

abstract final class _AppSpacing {
  static const double screen = 20;
  static const double section = 24;
  static const double card = 16;
  static const double item = 12;
}

/// Scroll + min-height fill for Analyze / Trade Setup tab forms (removes empty bottom void).
Widget _premiumTabScrollBody({
  required double minHeight,
  required List<Widget> children,
}) {
  return SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    ),
  );
}

Route<T> _premiumPageRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.035), end: Offset.zero).animate(curve),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 320),
  );
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const _FadeIn({
    required this.child,
    this.delay = Duration.zero,
  }) : duration = const Duration(milliseconds: 420);

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    Future<void>.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

class _ScaleTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _ScaleTap({required this.child, this.onTap});

  @override
  State<_ScaleTap> createState() => _ScaleTapState();
}

class _ScaleTapState extends State<_ScaleTap> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null ? null : (_) => setState(() => _pressed = false),
      onTapCancel: widget.onTap == null ? null : () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _AppSpacing.item),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _AppEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;
  /// When true, sizes down and centers within a bounded parent (avoids overflow).
  final bool fitHeight;

  const _AppEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
    this.fitHeight = false,
  });

  Widget _buildContent({required bool compact}) {
    const accent = Color(0xFF00BFFF);
    final outerSize = compact ? 84.0 : 112.0;
    final innerSize = compact ? 58.0 : 76.0;
    final iconSize = compact ? 28.0 : 34.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 28, vertical: compact ? 8 : 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: outerSize,
                height: outerSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.05),
                  border: Border.all(color: accent.withValues(alpha: 0.08)),
                ),
              ),
              Container(
                width: innerSize,
                height: innerSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent.withValues(alpha: 0.22),
                      accent.withValues(alpha: 0.06),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.12),
                      blurRadius: compact ? 16 : 24,
                      spreadRadius: compact ? 1 : 2,
                    ),
                  ],
                ),
                child: Icon(icon, size: iconSize, color: accent.withValues(alpha: 0.95)),
              ),
              if (!compact) ...[
                Positioned(
                  top: -4,
                  right: -8,
                  child: Icon(Icons.auto_awesome, size: 16, color: Colors.amber.withValues(alpha: 0.55)),
                ),
                Positioned(
                  bottom: 2,
                  left: -10,
                  child: Icon(Icons.circle, size: 8, color: accent.withValues(alpha: 0.35)),
                ),
              ],
            ],
          ),
          SizedBox(height: compact ? 14 : 22),
          Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 15 : 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: compact ? 3 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 13 : 14, height: 1.4, color: Colors.grey[500]),
          ),
          if (action != null) ...[
            SizedBox(height: compact ? 12 : 20),
            action!,
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!fitHeight) {
      return Center(child: _buildContent(compact: false));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 260;
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: _buildContent(compact: compact)),
          ),
        );
      },
    );
  }
}

ThemeData _buildAppTheme() {
  const accent = Color(0xFF00BFFF);
  const surface = Color(0xFF1A1A1A);
  const scaffold = Color(0xFF0F0F0F);

  return ThemeData.dark().copyWith(
    primaryColor: accent,
    scaffoldBackgroundColor: scaffold,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      surface: surface,
      onSurface: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: scaffold,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
        letterSpacing: -0.3,
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    dividerTheme: DividerThemeData(color: Colors.white.withValues(alpha: 0.06), thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: accent, width: 1.2),
      ),
      labelStyle: TextStyle(color: Colors.grey[500]),
      hintStyle: TextStyle(color: Colors.grey[600]),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 0.1),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 15, height: 1.5),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55),
    ),
  );
}

/// Reusable app logo — scales cleanly for AppBar, splash, and profile headers.
class AppLogo extends StatelessWidget {
  final double height;
  final Alignment alignment;

  const AppLogo({
    super.key,
    this.height = 40,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Image.asset(
        kAppLogoAsset,
        height: height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, __, ___) => Text(
          'On-Chain Oracle',
          style: TextStyle(
            fontSize: height * 0.38,
            fontWeight: FontWeight.w700,
            color: Colors.grey[200],
          ),
        ),
      ),
    );
  }
}

/// Premium launch screen with subtle fade + scale animation.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
    Future<void>.delayed(const Duration(milliseconds: 2400), _goHome);
  }

  void _navigateTo(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => screen,
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 450),
      ),
    );
  }

  Future<void> _goHome() async {
    if (!mounted) return;
    await AuthService.init();
    await AppApiKeyService.ensureKey();
    await OracleCitadelStore.load();

    if (await AuthService.hasValidSession()) {
      _navigateTo(const MainScreen());
      return;
    }

    if (await AuthService.tryBiometricUnlock()) {
      if (!mounted) return;
      _navigateTo(const MainScreen());
      return;
    }

    final rememberedEmail = await AuthService.getRememberedEmail();
    if (!mounted) return;
    _navigateTo(
      LoginScreen(
        prefillEmail: rememberedEmail,
        onSuccess: (ctx) {
          Navigator.of(ctx).pushReplacement(
            PageRouteBuilder<void>(
              pageBuilder: (_, __, ___) => const MainScreen(),
              transitionsBuilder: (_, animation, __, child) =>
                  FadeTransition(opacity: animation, child: child),
              transitionDuration: const Duration(milliseconds: 450),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, child) => Opacity(
            opacity: _fade.value,
            child: Transform.scale(scale: _scale.value, child: child),
          ),
          child: const AppLogo(height: 220, alignment: Alignment.center),
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hive — Recent Analyses / trade setup history survives app restarts.
  await AnalysisHistoryStore.init();
  await DailyAnalysisStore.init();
  await NotificationService.instance.initialize();
  pingBackendHealth();
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

/// Bottom-nav Citadel tab — Expert: full Citadel hub; Free/Premium: upgrade gate.
class _CitadelScreen extends StatefulWidget {
  final bool isActive;
  final CitadelPositionClosedCallback? onPositionClosed;

  const _CitadelScreen({
    required this.isActive,
    this.onPositionClosed,
  });

  @override
  State<_CitadelScreen> createState() => _CitadelScreenState();
}

class _CitadelScreenState extends State<_CitadelScreen> {
  bool _isExpert = false;
  final GlobalKey<_CitadelExpertViewState> _expertKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _CitadelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    final expert = SubscriptionPlanStore.hasCitadelAccess;
    setState(() => _isExpert = expert);
    if (expert) {
      _expertKey.currentState?.refreshHub();
    }
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_isExpert) {
      return _CitadelExpertView(
        key: _expertKey,
        isActive: widget.isActive,
        onPositionClosed: widget.onPositionClosed,
        onOpenSetup: () async {
          await showCitadelSetupDialog(context);
          await _expertKey.currentState?.refreshHub();
        },
      );
    }
    return _CitadelUpgradeView(onUpgrade: _openSubscription);
  }
}

/// Expert plan — full Citadel hub (BloFin status, leverage, setup).
class _CitadelExpertView extends StatefulWidget {
  final bool isActive;
  final Future<void> Function() onOpenSetup;
  final CitadelPositionClosedCallback? onPositionClosed;

  const _CitadelExpertView({
    super.key,
    required this.isActive,
    required this.onOpenSetup,
    this.onPositionClosed,
  });

  @override
  State<_CitadelExpertView> createState() => _CitadelExpertViewState();
}

class _CitadelExpertViewState extends State<_CitadelExpertView> {
  bool _loading = true;
  bool _serverLinked = false;
  String? _linkMessage;
  String _exchangeLabel = 'BloFin';
  DateTime? _lastConnected;
  double _leverage = 5;
  double _riskPercent = 1;

  @override
  void initState() {
    super.initState();
    refreshHub();
  }

  @override
  void didUpdateWidget(covariant _CitadelExpertView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      refreshHub();
    }
  }

  Future<void> refreshHub() async {
    setState(() => _loading = true);
    await OracleCitadelStore.load();
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString('citadel_last_connected_iso');
    final label = prefs.getString('citadel_connected_exchange_label');
    var linked = false;
    String? message;
    if (OracleCitadelStore.isConfigured) {
      final status = await OracleCitadelService.checkServerLinked();
      linked = status.linked;
      message = status.linked ? null : status.userMessage;
    } else {
      message = 'App credentials not saved — open setup to configure Citadel.';
    }
    if (!mounted) return;
    setState(() {
      _serverLinked = linked;
      _linkMessage = message;
      _exchangeLabel = (label != null && label.trim().isNotEmpty) ? label : 'BloFin';
      _lastConnected = iso != null ? DateTime.tryParse(iso) : null;
      _leverage = OracleCitadelStore.defaultLeverage;
      _riskPercent = OracleCitadelStore.defaultRiskPercent;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 22),
            SizedBox(width: 8),
            Text('Citadel', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(24, 12, 24, 20 + bottomInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Oracle Citadel',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                'MARKET & LIMIT execution via BloFin',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configure keys, leverage, and risk here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                    ),
                  ),
                )
              else if (_serverLinked)
                _CitadelConnectionStatusCard(
                  exchangeLabel: _exchangeLabel,
                  demoMode: OracleCitadelStore.useDemoMode,
                  lastConnected: _lastConnected ?? DateTime.now(),
                  leverage: _leverage.round(),
                )
              else
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB74D).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFB74D).withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.link_off_rounded, color: Color(0xFFFFB74D), size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _linkMessage ?? 'Not connected — open setup to link your BloFin API keys.',
                          style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[300]),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!_loading && _serverLinked) ...[
                const SizedBox(height: 20),
                CitadelLivePositionsPanel(
                  isActive: widget.isActive,
                  serverLinked: _serverLinked,
                  onPositionClosed: widget.onPositionClosed,
                ),
              ],
              if (!_loading) ...[
                const SizedBox(height: 18),
                _CitadelLeverageRiskPanel(
                  leverage: _leverage,
                  riskPercent: _riskPercent,
                  onLeverageChanged: (v) async {
                    await OracleCitadelStore.saveLeverage(v);
                    setState(() => _leverage = OracleCitadelStore.defaultLeverage);
                  },
                  onRiskPercentChanged: (v) async {
                    await OracleCitadelStore.saveRiskPercent(v);
                    setState(() => _riskPercent = OracleCitadelStore.defaultRiskPercent);
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'API & execution',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[500],
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'User ID: ${OracleCitadelStore.userId}',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        OracleCitadelStore.useDemoMode
                            ? 'Mode: BloFin Demo (recommended for testing)'
                            : 'Mode: BloFin Live',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        OracleCitadelStore.isConfigured
                            ? 'App API key: configured'
                            : 'App API key: not set',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => widget.onOpenSetup(),
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  label: const Text('Open Citadel Setup'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

/// Free / Premium — Citadel upgrade gate (mirrors Expert hero, locks execution).
class _CitadelUpgradeView extends StatelessWidget {
  final VoidCallback onUpgrade;

  const _CitadelUpgradeView({required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 22),
            SizedBox(width: 8),
            Text('Citadel', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28, 12, 28, 20 + bottomInset),
          child: Column(
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Oracle Citadel',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                'MARKET & LIMIT execution via BloFin',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configure keys, leverage, and risk here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onUpgrade,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 3,
                    shadowColor: const Color(0xFF00BFFF).withValues(alpha: 0.45),
                  ),
                  child: const Text(
                    '🔓 Upgrade to Expert',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Premium users get full AI analysis & Trade Setups. Citadel is Expert only.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-nav Oracle Vision — Premium+: live hub; Free: upgrade gate.
class _OracleVisionTabScreen extends StatefulWidget {
  final bool isActive;
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const _OracleVisionTabScreen({
    required this.isActive,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<_OracleVisionTabScreen> createState() => _OracleVisionTabScreenState();
}

class _OracleVisionTabScreenState extends State<_OracleVisionTabScreen> {
  bool _hasAccess = false;

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _OracleVisionTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() => _hasAccess = SubscriptionPlanStore.hasOracleVisionAccess);
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasAccess) {
      return OracleVisionScreen(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
        onTradeSetupGenerated: widget.onTradeSetupGenerated,
      );
    }
    return _TierGateUpgradeView(
      title: 'Oracle Vision',
      icon: Icons.visibility_outlined,
      headline: 'Oracle Vision',
      subtitle: 'Live High-Conviction Opportunities',
      detail: 'Real-time liquidation heatmaps, pulse signals, and confluence-driven setups.',
      buttonLabel: '🔓 Upgrade to Premium',
      footnote: 'Free users get Daily Analysis on BTC, ETH, and SOL. Oracle Vision is Premium+.',
      onUpgrade: _openSubscription,
    );
  }
}

/// Bottom-nav Oracle Desk — Expert only; Free/Premium: upgrade gate.
class _OracleDeskTabScreen extends StatefulWidget {
  final bool isActive;
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const _OracleDeskTabScreen({
    required this.isActive,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<_OracleDeskTabScreen> createState() => _OracleDeskTabScreenState();
}

class _OracleDeskTabScreenState extends State<_OracleDeskTabScreen> {
  bool _isExpert = false;

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _OracleDeskTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() => _isExpert = SubscriptionPlanStore.hasOracleDeskAccess);
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_isExpert) {
      return OracleDeskScreen(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
        onTradeSetupGenerated: widget.onTradeSetupGenerated,
      );
    }
    return _TierGateUpgradeView(
      title: 'Oracle Desk',
      icon: Icons.dashboard_customize_outlined,
      headline: 'Oracle Desk',
      subtitle: 'Advanced Performance + Personal Command Center',
      detail: 'Watchlist bias, trade performance, Oracle Pulse, and your personal trading hub.',
      buttonLabel: '🔓 Upgrade to Expert',
      footnote: 'Premium users get Oracle Vision and unlimited trade setups. Oracle Desk is Expert only.',
      onUpgrade: _openSubscription,
    );
  }
}

/// Reusable tier gate shell (Citadel / Vision / Desk upgrade screens).
class _TierGateUpgradeView extends StatelessWidget {
  final String title;
  final IconData icon;
  final String headline;
  final String subtitle;
  final String detail;
  final String buttonLabel;
  final String footnote;
  final VoidCallback onUpgrade;

  const _TierGateUpgradeView({
    required this.title,
    required this.icon,
    required this.headline,
    required this.subtitle,
    required this.detail,
    required this.buttonLabel,
    required this.footnote,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF00BFFF), size: 22),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28, 12, 28, 20 + bottomInset),
          child: Column(
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: const Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Text(
                headline,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onUpgrade,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 3,
                    shadowColor: const Color(0xFF00BFFF).withValues(alpha: 0.45),
                  ),
                  child: Text(
                    buttonLabel,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                footnote,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    _loadPersistedHistory();
    SubscriptionPlanStore.load();
    OracleCitadelStore.load();
    UserProfileStore.load();
    NotificationService.instance.registerDailyAnalysesNavigator(_openDailyAnalysesFromNotification);
    NotificationService.instance.onDailyAnalysisPayload = _ingestDailyAnalysisFromPush;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.dispatchPendingDailyAnalysesNavigation();
      _refreshDailyAnalysesForHome();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.registerDailyAnalysesNavigator(null);
    NotificationService.instance.onDailyAnalysisPayload = null;
    super.dispose();
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
      if (resolvedDirection == "Long Only") {
        if (price >= tp1 || price >= tp2) {
          nextStatus = "Win";
        } else if (price <= sl) {
          nextStatus = "Loss";
        }
      } else {
        if (price <= tp1 || price <= tp2) {
          nextStatus = "Win";
        } else if (price >= sl) {
          nextStatus = "Loss";
        }
      }

      if (nextStatus != null) {
        trade["status"] = nextStatus;
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

// ==================== HOME SCREEN ====================
//
// Premium layout (single vertical scroll):
//   AppBar → Win Rate → Watchlist (+) → Daily Oracle Bias → Latest Market News (Live)
//
// SingleChildScrollView + Column — ~4 list rows per section, scroll for more.

const int _kHomePreviewCount = 4;

// --- Daily Oracle Bias: live market snapshot (BTC/ETH/SOL/BNB via CoinGecko) ---

enum _OracleBiasKind { bullish, bearish, neutral }

class _OracleAssetBias {
  final String symbol;
  final double priceUsd;
  final double change24hPct;
  final double low24h;
  final double high24h;

  const _OracleAssetBias({
    required this.symbol,
    required this.priceUsd,
    required this.change24hPct,
    required this.low24h,
    required this.high24h,
  });

  _OracleBiasKind get microBias {
    if (change24hPct >= 0.6) return _OracleBiasKind.bullish;
    if (change24hPct <= -0.6) return _OracleBiasKind.bearish;
    return _OracleBiasKind.neutral;
  }
}

class _DailyOracleBiasSnapshot {
  final _OracleBiasKind overall;
  final int confidencePct;
  final String sentimentLine;
  final List<_OracleAssetBias> assets;
  final DateTime fetchedAt;

  const _DailyOracleBiasSnapshot({
    required this.overall,
    required this.confidencePct,
    required this.sentimentLine,
    required this.assets,
    required this.fetchedAt,
  });
}

_OracleBiasKind _overallBiasFromAssets(List<_OracleAssetBias> assets) {
  if (assets.isEmpty) return _OracleBiasKind.neutral;
  double score = 0;
  double weight = 0;
  const weights = {'BTC': 0.45, 'ETH': 0.35, 'SOL': 0.12, 'BNB': 0.08};
  for (final a in assets) {
    final w = weights[a.symbol] ?? 0.1;
    score += a.change24hPct * w;
    weight += w;
  }
  final avg = weight > 0 ? score / weight : 0;
  if (avg >= 0.35) return _OracleBiasKind.bullish;
  if (avg <= -0.35) return _OracleBiasKind.bearish;
  return _OracleBiasKind.neutral;
}

String _oracleBiasLabel(_OracleBiasKind kind) {
  switch (kind) {
    case _OracleBiasKind.bullish:
      return 'Bullish';
    case _OracleBiasKind.bearish:
      return 'Bearish';
    case _OracleBiasKind.neutral:
      return 'Neutral';
  }
}

Color _oracleBiasAccent(_OracleBiasKind kind) {
  switch (kind) {
    case _OracleBiasKind.bullish:
      return const Color(0xFF00E676);
    case _OracleBiasKind.bearish:
      return const Color(0xFFFF5252);
    case _OracleBiasKind.neutral:
      return const Color(0xFF00BFFF);
  }
}

String _formatOraclePrice(double price) {
  if (price >= 1000) return '\$${price.toStringAsFixed(0)}';
  if (price >= 1) return '\$${price.toStringAsFixed(2)}';
  return '\$${price.toStringAsFixed(4)}';
}

const List<String> _kDailyBiasSymbols = ['BTC', 'ETH', 'SOL', 'BNB'];

/// Builds snapshot from at least one asset row (bias fix: partial data beats total failure).
_DailyOracleBiasSnapshot? _buildDailyOracleBiasSnapshot(List<_OracleAssetBias> assets) {
  if (assets.isEmpty) return null;

  final overall = _overallBiasFromAssets(assets);
  final avgAbs = assets.map((a) => a.change24hPct.abs()).reduce((a, b) => a + b) / assets.length;
  final confidence = (28 + avgAbs * 9).round().clamp(32, 92);

  final btc = assets.where((a) => a.symbol == 'BTC').firstOrNull;
  final eth = assets.where((a) => a.symbol == 'ETH').firstOrNull;
  final String sentimentLine;
  if (btc != null && eth != null) {
    sentimentLine =
        'BTC ${btc.change24hPct >= 0 ? '+' : ''}${btc.change24hPct.toStringAsFixed(1)}% · '
        'ETH ${eth.change24hPct >= 0 ? '+' : ''}${eth.change24hPct.toStringAsFixed(1)}% · '
        '${_oracleBiasLabel(overall).toLowerCase()} structure';
  } else {
    sentimentLine = 'Multi-asset read · ${_oracleBiasLabel(overall).toLowerCase()} bias';
  }

  return _DailyOracleBiasSnapshot(
    overall: overall,
    confidencePct: confidence,
    sentimentLine: sentimentLine,
    assets: assets,
    fetchedAt: DateTime.now(),
  );
}

/// Primary bias source — Binance 24h tickers (no API key, mobile-friendly).
Future<List<_OracleAssetBias>> _fetchDailyBiasFromBinance() async {
  final response = await http
      .get(
        Uri.parse('https://api.binance.com/api/v3/ticker/24hr'),
        headers: const {'Accept': 'application/json'},
      )
      .timeout(const Duration(seconds: 15));

  if (response.statusCode != 200) {
    throw Exception('Binance HTTP ${response.statusCode}');
  }

  final list = jsonDecode(response.body) as List<dynamic>;
  final byPair = <String, Map<String, dynamic>>{};
  for (final raw in list) {
    if (raw is Map<String, dynamic>) {
      final sym = raw['symbol']?.toString();
      if (sym != null) byPair[sym] = raw;
    }
  }

  final out = <_OracleAssetBias>[];
  for (final base in _kDailyBiasSymbols) {
    final row = byPair['${base}USDT'];
    if (row == null) continue;
    final price = double.tryParse(row['lastPrice']?.toString() ?? '');
    if (price == null || price <= 0) continue;
    final change = double.tryParse(row['priceChangePercent']?.toString() ?? '') ?? 0;
    final low = double.tryParse(row['lowPrice']?.toString() ?? '') ?? price * 0.97;
    final high = double.tryParse(row['highPrice']?.toString() ?? '') ?? price * 1.03;
    out.add(
      _OracleAssetBias(
        symbol: base,
        priceUsd: price,
        change24hPct: change,
        low24h: low,
        high24h: high,
      ),
    );
  }
  return out;
}

/// Secondary source — CoinGecko markets (retries + cache-bust).
Future<List<_OracleAssetBias>> _fetchDailyBiasFromCoinGecko(Set<String> missing) async {
  if (missing.isEmpty) return [];

  const idMap = {
    'BTC': 'bitcoin',
    'ETH': 'ethereum',
    'SOL': 'solana',
    'BNB': 'binancecoin',
  };
  final ids = missing.map((s) => idMap[s]).whereType<String>().join(',');

  Object? lastError;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final uri = Uri.https(
        'api.coingecko.com',
        '/api/v3/coins/markets',
        {
          'vs_currency': 'usd',
          'ids': ids,
          'order': 'market_cap_desc',
          'sparkline': 'false',
          'price_change_percentage': '24h',
          '_': '${DateTime.now().millisecondsSinceEpoch}',
        },
      );
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 18));

      if (response.statusCode == 429) {
        lastError = 'CoinGecko rate limit';
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        continue;
      }
      if (response.statusCode != 200) {
        lastError = 'CoinGecko HTTP ${response.statusCode}';
        continue;
      }

      final list = jsonDecode(response.body) as List<dynamic>;
      final byId = <String, Map<String, dynamic>>{};
      for (final raw in list) {
        if (raw is Map<String, dynamic>) {
          final id = raw['id']?.toString();
          if (id != null) byId[id] = raw;
        }
      }

      final out = <_OracleAssetBias>[];
      for (final sym in missing) {
        final row = byId[idMap[sym]];
        if (row == null) continue;
        final price = (row['current_price'] as num?)?.toDouble();
        if (price == null || price <= 0) continue;
        out.add(
          _OracleAssetBias(
            symbol: sym,
            priceUsd: price,
            change24hPct: (row['price_change_percentage_24h'] as num?)?.toDouble() ?? 0,
            low24h: (row['low_24h'] as num?)?.toDouble() ?? price * 0.97,
            high24h: (row['high_24h'] as num?)?.toDouble() ?? price * 1.03,
          ),
        );
      }
      return out;
    } catch (e) {
      lastError = e;
      await Future.delayed(Duration(milliseconds: 350 * (attempt + 1)));
    }
  }
  throw Exception(lastError?.toString() ?? 'CoinGecko unavailable');
}

/// Bias fix: Binance first, CoinGecko fills gaps, retries — avoids empty CoinGecko-only failures.
Future<_DailyOracleBiasSnapshot?> _fetchDailyOracleBiasSnapshot() async {
  final merged = <String, _OracleAssetBias>{};
  final errors = <String>[];

  try {
    for (final a in await _fetchDailyBiasFromBinance()) {
      merged[a.symbol] = a;
    }
    debugPrint('[DailyOracleBias] Binance ok count=${merged.length}');
  } catch (e) {
    errors.add('Binance: $e');
    debugPrint('[DailyOracleBias] Binance failed: $e');
  }

  final missing = _kDailyBiasSymbols.where((s) => !merged.containsKey(s)).toSet();
  if (missing.isNotEmpty) {
    try {
      for (final a in await _fetchDailyBiasFromCoinGecko(missing)) {
        merged[a.symbol] = a;
      }
      debugPrint('[DailyOracleBias] CoinGecko filled ${missing.length} gap(s)');
    } catch (e) {
      errors.add('CoinGecko: $e');
      debugPrint('[DailyOracleBias] CoinGecko failed: $e');
    }
  }

  final assets = _kDailyBiasSymbols.map((s) => merged[s]).whereType<_OracleAssetBias>().toList();
  if (assets.isEmpty) {
    debugPrint('[DailyOracleBias] all sources failed: ${errors.join("; ")}');
    return null;
  }

  return _buildDailyOracleBiasSnapshot(assets);
}

/// Radial crystal-orb glow behind Daily Oracle Bias hero.
class _OracleOrbGlow extends StatelessWidget {
  final double size;
  final Color accent;

  const _OracleOrbGlow({required this.size, required this.accent});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accent.withValues(alpha: 0.35),
                  accent.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Container(
            width: size * 0.62,
            height: size * 0.62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.22),
                  accent.withValues(alpha: 0.45),
                  const Color(0xFF1A1A1A).withValues(alpha: 0.9),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.2),
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 24, spreadRadius: 2),
              ],
            ),
            child: Icon(Icons.auto_awesome, color: Colors.white.withValues(alpha: 0.85), size: size * 0.22),
          ),
        ],
      ),
    );
  }
}

/// Standard spacing between Home list cards (screenshot).
const EdgeInsets _kHomeCardGap = EdgeInsets.only(bottom: 10);

Widget? _homeScrollHint(int total) {
  if (total <= _kHomePreviewCount) return null;
  return Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 6),
    child: Text(
      'Showing $_kHomePreviewCount of $total — scroll down for more',
      style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.3),
    ),
  );
}

/// Section block: header + hint + cards (first 4, then remainder on page scroll).
class _HomeSection extends StatelessWidget {
  final Widget header;
  final int itemCount;
  final List<Widget> cards;

  const _HomeSection({
    required this.header,
    required this.itemCount,
    required this.cards,
  });

  @override
  Widget build(BuildContext context) {
    final first = cards.take(_kHomePreviewCount).toList();
    final rest = cards.length > _kHomePreviewCount ? cards.skip(_kHomePreviewCount).toList() : const <Widget>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        if (_homeScrollHint(itemCount) != null) _homeScrollHint(itemCount)!,
        ...first,
        ...rest,
        const SizedBox(height: 16),
      ],
    );
  }
}

// --- Home Watchlist upgrade: live CoinGecko icons, price, 24h % (horizontal carousel) ---

const Map<String, String> _kWatchlistGeckoIds = {
  'BTC': 'bitcoin',
  'ETH': 'ethereum',
  'SOL': 'solana',
  'BNB': 'binancecoin',
  'XRP': 'ripple',
  'ADA': 'cardano',
  'DOGE': 'dogecoin',
  'AVAX': 'avalanche-2',
  'DOT': 'polkadot',
  'LINK': 'chainlink',
  'MATIC': 'matic-network',
  'POL': 'matic-network',
  'LTC': 'litecoin',
  'UNI': 'uniswap',
  'ATOM': 'cosmos',
  'NEAR': 'near',
  'APT': 'aptos',
  'ARB': 'arbitrum',
  'OP': 'optimism',
  'SUI': 'sui',
  'INJ': 'injective-protocol',
  'TIA': 'celestia',
  'RENDER': 'render-token',
  'RNDR': 'render-token',
  'WIF': 'dogwifcoin',
  'PEPE': 'pepe',
  'TAO': 'bittensor',
  'HYPE': 'hyperliquid',
  'SHIB': 'shiba-inu',
  'TRX': 'tron',
  'BCH': 'bitcoin-cash',
  'FIL': 'filecoin',
};

class _WatchlistQuote {
  final String symbol;
  final double? priceUsd;
  final double? change24hPct;
  final String? imageUrl;

  const _WatchlistQuote({
    required this.symbol,
    this.priceUsd,
    this.change24hPct,
    this.imageUrl,
  });

  _WatchlistQuote copyWith({
    double? priceUsd,
    double? change24hPct,
    String? imageUrl,
  }) {
    return _WatchlistQuote(
      symbol: symbol,
      priceUsd: priceUsd ?? this.priceUsd,
      change24hPct: change24hPct ?? this.change24hPct,
      imageUrl: imageUrl ?? this.imageUrl,
    );
  }
}

Future<Map<String, _WatchlistQuote>> _fetchWatchlistQuotes(List<String> symbols) async {
  final idToSymbol = <String, String>{};
  for (final raw in symbols) {
    final sym = CoinAccessPolicy.normalizeCoinSymbol(raw) ?? raw.trim().toUpperCase();
    final id = _kWatchlistGeckoIds[sym];
    if (id != null && !idToSymbol.containsKey(id)) {
      idToSymbol[id] = sym;
    }
  }
  if (idToSymbol.isEmpty) return {};

  try {
    final uri = Uri.https(
      'api.coingecko.com',
      '/api/v3/coins/markets',
      {
        'vs_currency': 'usd',
        'ids': idToSymbol.keys.join(','),
        'order': 'market_cap_desc',
        'sparkline': 'false',
        'price_change_percentage': '24h',
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return {};

    final list = jsonDecode(response.body) as List<dynamic>;
    final out = <String, _WatchlistQuote>{};
    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id']?.toString();
      final sym = id != null ? idToSymbol[id] : null;
      if (sym == null) continue;
      out[sym] = _WatchlistQuote(
        symbol: sym,
        priceUsd: (raw['current_price'] as num?)?.toDouble(),
        change24hPct: (raw['price_change_percentage_24h'] as num?)?.toDouble(),
        imageUrl: raw['image']?.toString(),
      );
    }
    return out;
  } catch (_) {
    return {};
  }
}

// --- Home live prices: 7s backend poll (/live_price → Mobula → CoinGecko Pro) ---

/// Shared short-TTL cache so Watchlist + Daily Oracle Bias never double-fetch
/// the same coin inside one polling window (keeps backend load minimal).
abstract final class _HomeLivePriceCache {
  static const Duration _ttl = Duration(seconds: 5);
  static final Map<String, ({double price, double? change24hPct, DateTime at})> _cache = {};
  static final Map<String, Future<({double price, double? change24hPct})?>> _inflight = {};

  static Future<({double price, double? change24hPct})?> fetch(String coin) {
    final upper = CoinAccessPolicy.normalizeCoinSymbol(coin) ?? coin.trim().toUpperCase();
    final cached = _cache[upper];
    if (cached != null && DateTime.now().difference(cached.at) < _ttl) {
      return Future.value((price: cached.price, change24hPct: cached.change24hPct));
    }
    final pending = _inflight[upper];
    if (pending != null) return pending;

    final future = OracleLivePriceService.fetch(upper).then((data) {
      _inflight.remove(upper);
      final price = (data?['price'] as num?)?.toDouble();
      if (price == null || price <= 0) return null;
      final change = (data?['change_24h_pct'] as num?)?.toDouble();
      _cache[upper] = (price: price, change24hPct: change, at: DateTime.now());
      return (price: price, change24hPct: change);
    });
    _inflight[upper] = future;
    return future;
  }
}

/// Subtle pulsing "LIVE" dot — signals the 7s live price feed is active.
class _LivePulseDot extends StatefulWidget {
  const _LivePulseDot();

  @override
  State<_LivePulseDot> createState() => _LivePulseDotState();
}

class _LivePulseDotState extends State<_LivePulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = 0.45 + _pulse.value * 0.55;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00E676).withValues(alpha: t),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00E676).withValues(alpha: t * 0.5),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Text(
              'LIVE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: const Color(0xFF00E676).withValues(alpha: 0.55 + _pulse.value * 0.45),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Home Watchlist — horizontal scroll, live quotes, + add coin (unchanged behavior).
class _HomeWatchlistSection extends StatefulWidget {
  final List<String> watchlist;
  final void Function(String symbol) onCoinTap;
  final void Function(String symbol) onAddCoin;
  final void Function(String symbol) onRemoveCoin;

  const _HomeWatchlistSection({
    super.key,
    required this.watchlist,
    required this.onCoinTap,
    required this.onAddCoin,
    required this.onRemoveCoin,
  });

  @override
  State<_HomeWatchlistSection> createState() => _HomeWatchlistSectionState();
}

class _HomeWatchlistSectionState extends State<_HomeWatchlistSection> {
  Map<String, _WatchlistQuote> _quotes = {};
  bool _loadingQuotes = true;

  /// Binance WebSocket — real-time price / 24h % on watchlist cards.
  WatchlistBinanceWsService? _binanceWs;
  Timer? _wsUiThrottle;
  final Map<String, BinanceWatchlistTick> _pendingWsTicks = {};
  bool _binanceWsActive = false;

  /// Reactive fix: parent mutates the same [List] in place, so reference equality
  /// in [didUpdateWidget] is not enough — track content via signature string.
  String _watchlistSignature = '';

  String _signatureFor(List<String> symbols) =>
      symbols.map((s) => CoinAccessPolicy.normalizeCoinSymbol(s) ?? s.trim().toUpperCase()).join('\u0001');

  List<String> get _normalizedWatchlist =>
      widget.watchlist.map((s) => CoinAccessPolicy.normalizeCoinSymbol(s) ?? s.trim().toUpperCase()).toList();

  /// 7s live poll — backend /live_price (Mobula → CoinGecko Pro). Capped per tick.
  Timer? _livePollTimer;
  static const int _kMaxLivePollSymbols = 8;

  @override
  void initState() {
    super.initState();
    _watchlistSignature = _signatureFor(widget.watchlist);
    _loadQuotes(initial: true);
    _connectBinanceWs();
    _livePollTimer = Timer.periodic(const Duration(seconds: 7), (_) => _pollLivePrices());
  }

  @override
  void dispose() {
    _livePollTimer?.cancel();
    _wsUiThrottle?.cancel();
    _binanceWs?.disconnect();
    _binanceWs = null;
    super.dispose();
  }

  /// Updates price + 24h % only — icons, layout, and card UI untouched.
  Future<void> _pollLivePrices() async {
    if (!mounted) return;
    final symbols = _normalizedWatchlist.take(_kMaxLivePollSymbols).toList();
    if (symbols.isEmpty) return;
    final results = await Future.wait(symbols.map(_HomeLivePriceCache.fetch));
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < symbols.length; i++) {
        final r = results[i];
        if (r == null) continue;
        final prev = _quotes[symbols[i]];
        _quotes[symbols[i]] = (prev ?? _WatchlistQuote(symbol: symbols[i])).copyWith(
          priceUsd: r.price,
          change24hPct: r.change24hPct ?? prev?.change24hPct,
        );
      }
      _loadingQuotes = false;
    });
  }

  @override
  void didUpdateWidget(covariant _HomeWatchlistSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyWatchlistIfChanged(widget.watchlist);
  }

  /// Detect adds/removes even when [List] instance is shared (in-place .add on parent).
  void _applyWatchlistIfChanged(List<String> symbols) {
    final nextSig = _signatureFor(symbols);
    if (nextSig == _watchlistSignature) return;
    _watchlistSignature = nextSig;
    setState(() {}); // new coin visible in horizontal list immediately
    _loadQuotes(initial: false);
    _connectBinanceWs();
  }

  /// Connect Binance @ticker streams for current watchlist (disconnects previous socket).
  void _connectBinanceWs() {
    final symbols = _normalizedWatchlist;
    if (symbols.isEmpty) return;

    _binanceWs?.disconnect();
    _binanceWs = WatchlistBinanceWsService(
      onTick: _onBinanceTick,
      onConnected: () {
        if (mounted) setState(() => _binanceWsActive = true);
      },
      onFailed: (_) {
        _binanceWsActive = false;
        // CoinGecko REST from [_loadQuotes] remains the fallback.
      },
    );
    _binanceWs!.connect(symbols);
  }

  void _onBinanceTick(BinanceWatchlistTick tick) {
    _pendingWsTicks[tick.symbol] = tick;
    _wsUiThrottle ??= Timer(const Duration(milliseconds: 180), _flushWsTicks);
  }

  void _flushWsTicks() {
    _wsUiThrottle = null;
    if (!mounted || _pendingWsTicks.isEmpty) return;
    setState(() {
      for (final tick in _pendingWsTicks.values) {
        final prev = _quotes[tick.symbol];
        _quotes[tick.symbol] = (prev ?? _WatchlistQuote(symbol: tick.symbol)).copyWith(
          priceUsd: tick.priceUsd,
          change24hPct: tick.change24hPct,
        );
      }
      _pendingWsTicks.clear();
      _loadingQuotes = false;
    });
  }

  /// Home pull-to-refresh — reload REST quotes and reconnect Binance WS.
  Future<void> refreshFromPull() async {
    await _loadQuotes(initial: false);
    _connectBinanceWs();
  }

  /// CoinGecko REST — icons + initial prices; used when WS unavailable or non-Binance symbols.
  Future<void> _loadQuotes({required bool initial}) async {
    if (initial) {
      setState(() => _loadingQuotes = true);
    }
    final fetched = await _fetchWatchlistQuotes(widget.watchlist);
    if (!mounted) return;
    setState(() {
      _quotes = {..._quotes, ...fetched};
      _loadingQuotes = false;
    });
  }

  /// After + adds a coin: parent [setState] runs next frame — refresh then.
  void _handleAddCoin(String symbol) {
    widget.onAddCoin(symbol);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyWatchlistIfChanged(widget.watchlist);
    });
  }

  void _openWatchlistCoinSearch() {
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => WatchlistCoinSearchScreen(
          existingWatchlist: List<String>.from(widget.watchlist),
          onCoinSelected: _handleAddCoin,
        ),
      ),
    ).then((_) {
      if (mounted) _applyWatchlistIfChanged(widget.watchlist);
    });
  }

  /// Short price string for narrow watchlist cards (prevents horizontal overflow).
  String _formatWatchlistPrice(double price) {
    if (price >= 1000000) return '\$${(price / 1000000).toStringAsFixed(2)}M';
    if (price >= 10000) return '\$${(price / 1000).toStringAsFixed(1)}K';
    if (price >= 1000) return '\$${price.toStringAsFixed(0)}';
    if (price >= 1) return '\$${price.toStringAsFixed(2)}';
    return '\$${price.toStringAsFixed(4)}';
  }

  static const double _kWatchlistAvatarRadius = 18;

  Widget _watchlistCoinAvatar(String symbol, _WatchlistQuote? quote) {
    final imageUrl = quote?.imageUrl;
    final size = _kWatchlistAvatarRadius * 2;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return CircleAvatar(
        radius: _kWatchlistAvatarRadius,
        backgroundColor: const Color(0xFF252525),
        child: ClipOval(
          child: Image.network(
            imageUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _watchlistLetterAvatar(symbol),
          ),
        ),
      );
    }
    return _watchlistLetterAvatar(symbol);
  }

  Widget _watchlistLetterAvatar(String symbol) {
    return CircleAvatar(
      radius: _kWatchlistAvatarRadius,
      backgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.12),
      child: Text(
        symbol.substring(0, 1),
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF00BFFF)),
      ),
    );
  }

  Widget _watchlistChangeChip(double? change24h) {
    if (change24h == null) {
      return Text('—', style: TextStyle(fontSize: 10, color: Colors.grey[600]));
    }
    final up = change24h >= 0;
    final color = up ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final prefix = up ? '+' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          up ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
          color: color,
          size: 16,
        ),
        Flexible(
          child: Text(
            '$prefix${change24h.toStringAsFixed(1)}%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
          ),
        ),
      ],
    );
  }

  void _handleRemoveCoin(String symbol, String normalized) {
    widget.onRemoveCoin(symbol);
    setState(() => _quotes.remove(normalized));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyWatchlistIfChanged(widget.watchlist);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Removed $normalized from watchlist'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  /// Small X in top-right — removes coin without conflicting with horizontal scroll.
  Widget _watchlistRemoveButton({
    required String symbol,
    required String normalized,
  }) {
    return Positioned(
      top: 4,
      right: 4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _handleRemoveCoin(symbol, normalized),
          customBorder: const CircleBorder(),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Icon(Icons.close, size: 13, color: Colors.grey[400]),
          ),
        ),
      ),
    );
  }

  /// Watchlist card height fix: fixed [height], vertical stack — no Row overflow in ~¼-width tiles.
  Widget _watchlistCard({
    required String symbol,
    required String normalized,
    required double height,
    required double width,
    required _WatchlistQuote? quote,
  }) {
    final resolved = _quotes[normalized] ?? quote;
    final priceLabel = _loadingQuotes && !_binanceWsActive && resolved?.priceUsd == null
        ? '…'
        : (resolved?.priceUsd != null ? _formatWatchlistPrice(resolved!.priceUsd!) : '—');

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _ScaleTap(
            onTap: () => widget.onCoinTap(symbol),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    _watchlistCoinAvatar(normalized, resolved),
                    const SizedBox(height: 5),
                    Text(
                      normalized,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 0.15),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: width - 12,
                      child: Text(
                        priceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: width - 12,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: _watchlistChangeChip(resolved?.change24hPct),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _watchlistRemoveButton(symbol: symbol, normalized: normalized),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const itemGap = 10.0;
    // Watchlist card height fix: compact fixed row — icon + 3 text lines, no overflow.
    const listHeight = 118.0;
    final viewportWidth = MediaQuery.sizeOf(context).width - (_AppSpacing.screen * 2);
    final cardWidth = (viewportWidth - (itemGap * 3)) / _kHomePreviewCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: 'Watchlist',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _LivePulseDot(),
              const SizedBox(width: 12),
              _ScaleTap(
                onTap: _openWatchlistCoinSearch,
                child: Material(
                  color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.add, color: Color(0xFF00BFFF), size: 22),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.watchlist.length > _kHomePreviewCount)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 6),
            child: Text(
              'Showing $_kHomePreviewCount of ${widget.watchlist.length} — swipe for more',
              style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.3),
            ),
          ),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            key: ValueKey(_watchlistSignature),
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: widget.watchlist.length,
            separatorBuilder: (_, __) => const SizedBox(width: itemGap),
            itemBuilder: (context, index) {
              final symbol = widget.watchlist[index];
              final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
              return SizedBox(
                key: ValueKey(symbol),
                width: cardWidth,
                height: listHeight,
                child: _watchlistCard(
                  symbol: symbol,
                  normalized: normalized,
                  width: cardWidth,
                  height: listHeight,
                  quote: _quotes[normalized],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class HomeScreen extends StatefulWidget {
  final Function(String) onCoinTap;
  final List<String> watchlist;
  final Function(String) onAddWatchlistCoin;
  final Function(String) onRemoveWatchlistCoin;
  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> trades;
  final String winRateText;
  final Function(Map<String, dynamic>) onViewReport;
  final void Function(dynamic id) onDelete;
  final void Function(dynamic tradeId) onDeleteTrade;
  final Map<String, dynamic>? Function(Map<String, dynamic> trade) resolveTradeHistory;
  final VoidCallback repairTradeHistoryLinks;
  final VoidCallback onClearDailyAnalyses;
  final Future<void> Function() onRefreshDailyAnalyses;

  const HomeScreen({
    super.key,
    required this.onCoinTap,
    required this.watchlist,
    required this.onAddWatchlistCoin,
    required this.onRemoveWatchlistCoin,
    required this.history,
    required this.trades,
    required this.winRateText,
    required this.onViewReport,
    required this.onDelete,
    required this.onDeleteTrade,
    required this.resolveTradeHistory,
    required this.repairTradeHistoryLinks,
    required this.onClearDailyAnalyses,
    required this.onRefreshDailyAnalyses,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _chatFabHidden = false;
  List<Map<String, dynamic>> _dailyAnalysisItems = [];

  final GlobalKey<_DailyOracleBiasBlockState> _dailyBiasKey = GlobalKey<_DailyOracleBiasBlockState>();
  final GlobalKey<_HomeWatchlistSectionState> _watchlistKey = GlobalKey<_HomeWatchlistSectionState>();
  final GlobalKey<_MarketNewsFeedState> _homeNewsKey = GlobalKey<_MarketNewsFeedState>();

  /// Push notifications scroll target — Daily Analysis section on Home.
  final GlobalKey _dailyAnalysesSectionKey = GlobalKey();

  /// Reload today's BTC / ETH / SOL / XRP cards from local store (after push, pull-refresh, Quick Analyze).
  void reloadDailyAnalysesFromParent() {
    if (!mounted) return;
    unawaited(_reloadDailyAnalysisItems());
  }

  Future<void> _reloadDailyAnalysisItems() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() {
      _dailyAnalysisItems = CoinAccessPolicy.filterDailyAnalysesForPlan(
        DailyAnalysisStore.loadTodayOrdered(),
      );
    });
  }

  /// Called from MainScreen when user opens a daily-analysis notification.
  void scrollToDailyAnalysesSection() {
    final ctx = _dailyAnalysesSectionKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      alignment: 0.06,
    );
  }

  @override
  void initState() {
    super.initState();
    _reloadDailyAnalysisItems();
    _loadChatFabPreference();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.history, widget.history)) {
      _reloadDailyAnalysisItems();
    }
  }

  /// Pull-to-refresh — bias, watchlist, news, and persisted daily analyses.
  Future<void> _refreshHome() async {
    final tasks = <Future<void>>[widget.onRefreshDailyAnalyses()];
    final bias = _dailyBiasKey.currentState;
    if (bias != null) tasks.add(bias.reload());
    final watchlist = _watchlistKey.currentState;
    if (watchlist != null) tasks.add(watchlist.refreshFromPull());
    final news = _homeNewsKey.currentState;
    if (news != null) tasks.add(news.refreshFromPull());
    await Future.wait(tasks);
    if (mounted) _reloadDailyAnalysisItems();
  }

  Future<void> _loadChatFabPreference() async {
    final hidden = await SubscriptionPlanStore.isHomeChatFabHidden();
    if (mounted) setState(() => _chatFabHidden = hidden);
  }

  Future<void> _hideChatFab() async {
    await SubscriptionPlanStore.setHomeChatFabHidden(true);
    if (mounted) setState(() => _chatFabHidden = true);
  }

  Future<void> _showChatFab() async {
    await SubscriptionPlanStore.setHomeChatFabHidden(false);
    if (mounted) setState(() => _chatFabHidden = false);
  }

  void _confirmHideChatFab() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hide AI Chat?', style: TextStyle(fontWeight: FontWeight.w600)),
        content: Text(
          'Remove the chat button from Home. You can restore it anytime from the AppBar.',
          style: TextStyle(color: Colors.grey[400], height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _hideChatFab();
            },
            child: const Text('Hide', style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _confirmClearAllHistory() {
    if (_dailyAnalysisItems.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Clear all analyses?', style: TextStyle(fontWeight: FontWeight.w600)),
        content: Text(
          'This removes every saved analysis from Daily Analysis. Trade setups on Trade Performance are not affected.',
          style: TextStyle(color: Colors.grey[400], height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onClearDailyAnalyses();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Daily Analysis cleared'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text('Clear All', style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteHistoryItem(BuildContext context, Map<String, dynamic> item) {
    final coin = (item['coin'] ?? '—').toString();
    final label = '$coin Analysis';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete item?', style: TextStyle(fontWeight: FontWeight.w600)),
        content: Text(
          'Remove $label from Daily Analysis. This cannot be undone.',
          style: TextStyle(color: Colors.grey[400], height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: Colors.grey[500]))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete(item['id']);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$label deleted'), behavior: SnackBarBehavior.floating),
              );
            },
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// Daily Analysis card — per-item snapshot so every row gets correct Review/Open/Trash.
  Widget _analysisHistoryCard(BuildContext context, Map<String, dynamic> item) {
    final snap = Map<String, dynamic>.from(item);
    final subtitle = snap['time'].toString();
    final hasReport = !isPlaceholderStoredReport(snap['report']?.toString());

    return Padding(
      key: ValueKey('history_${snap['id']}_${snap['tradeId'] ?? ''}'),
      padding: _kHomeCardGap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${snap['coin']} Analysis',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                  ],
                ),
              ),
              _HistoryChipButton(
                label: 'Review',
                backgroundColor: const Color(0xFF455A64),
                foregroundColor: Colors.white,
                onPressed: () {
                  if (!hasReport) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No saved report for this item'), behavior: SnackBarBehavior.floating),
                    );
                    return;
                  }
                  Navigator.push(
                    context,
                    _premiumPageRoute((_) => ReviewReportScreen(historyItem: snap)),
                  );
                },
              ),
              const SizedBox(width: 6),
              _HistoryChipButton(
                label: 'Open',
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black87,
                onPressed: () {
                  if (!hasReport) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('No saved report for this item'), behavior: SnackBarBehavior.floating),
                    );
                    return;
                  }
                  widget.onViewReport(snap);
                },
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: Icon(Icons.delete_outline, color: Colors.red[400], size: 22),
                onPressed: () => _confirmDeleteHistoryItem(context, snap),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _recentAnalysisCards(BuildContext context) {
    final items = _dailyAnalysisItems;
    if (items.isEmpty) {
      return [
        Padding(
          padding: _kHomeCardGap,
          child: _AppEmptyState(
            icon: Icons.insights_outlined,
            title: 'No analysis yet',
            subtitle: 'BTC, ETH, SOL, and XRP post here daily at 7:30 AM CST. Pull to refresh.',
          ),
        ),
      ];
    }
    return items.map((item) => _analysisHistoryCard(context, item)).toList();
  }

  Widget _winRateBanner(BuildContext context) {
    return Padding(
      padding: _kHomeCardGap,
      child: _ScaleTap(
        onTap: () {
          widget.repairTradeHistoryLinks();
          Navigator.push(
            context,
            _premiumPageRoute(
              (_) => TradePerformanceScreen(
                trades: List<Map<String, dynamic>>.from(widget.trades),
                resolveHistoryForTrade: widget.resolveTradeHistory,
                onViewReport: widget.onViewReport,
                onDeleteTrade: widget.onDeleteTrade,
              ),
            ),
          );
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                const Color(0xFF00BFFF).withValues(alpha: 0.14),
                const Color(0xFF1A1A1A),
              ],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
          ),
          child: Row(
            children: [
              Icon(Icons.emoji_events_outlined, color: const Color(0xFF00BFFF).withValues(alpha: 0.9), size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.winRateText,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF00BFFF),
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[600], size: 22),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: const AppLogo(height: 38),
        titleSpacing: 12,
        actions: [
          IconButton(
            tooltip: 'YouTube',
            icon: const Icon(Icons.play_circle_outline, color: Color(0xFFFF5252)),
            onPressed: () => openYouTubePlaylist(context),
          ),
          IconButton(
            tooltip: 'Alerts',
            icon: const Icon(Icons.notifications),
            onPressed: () => Navigator.push(
              context,
              _premiumPageRoute((_) => const AlertsScreen()),
            ),
          ),
          if (_chatFabHidden)
            IconButton(
              tooltip: 'Show AI Chat',
              icon: const Icon(kOracleAiChatIcon),
              onPressed: _showChatFab,
            ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.account_circle_outlined, size: 28),
            onPressed: () => Navigator.push(
              context,
              _premiumPageRoute((_) => const ProfileScreen()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: _chatFabHidden
          ? null
          : GestureDetector(
              onLongPress: _confirmHideChatFab,
              child: FloatingActionButton(
                heroTag: 'home_ai_chat',
                tooltip: 'Oracle AI Chat (long-press to hide)',
                backgroundColor: const Color(0xFF00BFFF),
                foregroundColor: Colors.black,
                elevation: 4,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                onPressed: () => openAiChat(context),
                child: const Icon(kOracleAiChatIcon),
              ),
            ),
      body: RefreshIndicator(
        color: const Color(0xFF00BFFF),
        backgroundColor: const Color(0xFF1A1A1A),
        onRefresh: _refreshHome,
        child: SingleChildScrollView(
          primary: true,
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.fromLTRB(
            _AppSpacing.screen,
            4,
            _AppSpacing.screen,
            100 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _winRateBanner(context),
              _HomeWatchlistSection(
                key: _watchlistKey,
                watchlist: widget.watchlist,
                onCoinTap: widget.onCoinTap,
                onAddCoin: widget.onAddWatchlistCoin,
                onRemoveCoin: widget.onRemoveWatchlistCoin,
              ),
              // Daily Oracle Bias — crystal-orb hero, overall bias, BTC/ETH/SOL/BNB levels.
              const _SectionHeader(title: 'Daily Oracle Bias'),
              Padding(
                padding: _kHomeCardGap,
                child: _DailyOracleBiasBlock(
                  key: _dailyBiasKey,
                  onCoinTap: widget.onCoinTap,
                ),
              ),
            const SizedBox(height: 16),
            // Daily Analysis — Quick Analyze only (trade setups → Trade Performance).
            KeyedSubtree(
              key: _dailyAnalysesSectionKey,
              child: _HomeSection(
              header: _SectionHeader(
                title: 'Daily Analysis',
                trailing: _dailyAnalysisItems.isEmpty
                    ? null
                    : TextButton(
                        onPressed: _confirmClearAllHistory,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.grey[500],
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Clear All', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
              ),
              itemCount: _dailyAnalysisItems.length,
              cards: _recentAnalysisCards(context),
            ),
            ),
            _HomeSection(
              header: Padding(
                padding: const EdgeInsets.only(bottom: _AppSpacing.item),
                child: Row(
                  children: [
                    const Text(
                      'Latest Market News',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.circle, size: 7, color: Colors.greenAccent),
                          SizedBox(width: 5),
                          Text(
                            'Live',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              itemCount: 0,
              cards: [_HomeNewsBlock(feedKey: _homeNewsKey)],
            ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Daily Oracle Bias — premium hero + four asset bias cards (Binance + CoinGecko).
class _DailyOracleBiasBlock extends StatefulWidget {
  final void Function(String symbol) onCoinTap;

  const _DailyOracleBiasBlock({super.key, required this.onCoinTap});

  @override
  State<_DailyOracleBiasBlock> createState() => _DailyOracleBiasBlockState();
}

class _DailyOracleBiasBlockState extends State<_DailyOracleBiasBlock> {
  _DailyOracleBiasSnapshot? _snapshot;
  bool _loading = true;
  String? _error;

  /// 7s live poll — backend /live_price (Mobula → CoinGecko Pro), shared cache.
  Timer? _livePollTimer;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    _livePollTimer = Timer.periodic(const Duration(seconds: 7), (_) => _pollLivePrices());
  }

  @override
  void dispose() {
    _livePollTimer?.cancel();
    super.dispose();
  }

  /// Patches asset price + 24h % only — overall bias, confidence, and levels untouched.
  Future<void> _pollLivePrices() async {
    final snap = _snapshot;
    if (!mounted || snap == null) return;

    final symbols = snap.assets.map((a) => a.symbol).toList();
    final results = await Future.wait(symbols.map(_HomeLivePriceCache.fetch));
    if (!mounted) return;

    final bySymbol = <String, ({double price, double? change24hPct})>{};
    for (var i = 0; i < symbols.length; i++) {
      final r = results[i];
      if (r != null) bySymbol[symbols[i]] = r;
    }
    if (bySymbol.isEmpty) return;

    final current = _snapshot;
    if (current == null) return;

    var changed = false;
    final updatedAssets = current.assets.map((asset) {
      final r = bySymbol[asset.symbol];
      if (r == null) return asset;
      changed = true;
      return _OracleAssetBias(
        symbol: asset.symbol,
        priceUsd: r.price,
        change24hPct: r.change24hPct ?? asset.change24hPct,
        low24h: asset.low24h,
        high24h: asset.high24h,
      );
    }).toList();
    if (!changed) return;

    setState(() {
      _snapshot = _DailyOracleBiasSnapshot(
        overall: current.overall,
        confidencePct: current.confidencePct,
        sentimentLine: current.sentimentLine,
        assets: updatedAssets,
        fetchedAt: DateTime.now(),
      );
    });
  }

  /// Called from Home pull-to-refresh only.
  Future<void> reload() => _load(initial: false);

  /// Bias fix: reliable fetch on first paint; silent refresh keeps orb UI visible.
  Future<void> _load({required bool initial}) async {
    final showFullLoader = initial || _snapshot == null;
    if (showFullLoader) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final snap = await _fetchDailyOracleBiasSnapshot();
    if (!mounted) return;

    setState(() {
      _loading = false;
      if (snap != null) {
        _snapshot = snap;
        _error = null;
      } else if (_snapshot == null) {
        _error = 'Market data is temporarily unavailable. Pull down on Home to refresh.';
      }
      // Keep last good snapshot on failed refresh so the section does not flash empty.
    });
  }

  String _updatedLabel(DateTime? at) {
    if (at == null) return 'Updating…';
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'Just updated';
    if (diff.inMinutes < 60) return 'Updated ${diff.inMinutes}m ago';
    return 'Updated ${diff.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: 220,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF00BFFF)),
        ),
      );
    }

    if (_error != null && _snapshot == null) {
      return Container(
        height: 220,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.blur_on_rounded, size: 40, color: const Color(0xFF00BFFF).withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            const Text(
              'Oracle bias unavailable',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'No market data',
              style: TextStyle(fontSize: 13, color: Colors.grey[500], height: 1.35),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final snap = _snapshot!;
    final accent = _oracleBiasAccent(snap.overall);
    final previewAssets = snap.assets.take(_kHomePreviewCount).toList();
    final restAssets = snap.assets.length > _kHomePreviewCount
        ? snap.assets.skip(_kHomePreviewCount).toList()
        : const <_OracleAssetBias>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero: orb backdrop + overall bias + confidence
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: 0.12),
                    const Color(0xFF141414),
                    const Color(0xFF0F0F0F),
                  ],
                ),
                border: Border.all(color: accent.withValues(alpha: 0.28)),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MARKET BIAS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _oracleBiasLabel(snap.overall),
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.8,
                            color: accent,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _OracleBiasPill(
                          label: 'Confidence ${snap.confidencePct}%',
                          color: accent,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          snap.sentimentLine,
                          style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[400]),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _LivePulseDot(),
                            const SizedBox(width: 8),
                            Text(
                              _updatedLabel(snap.fetchedAt),
                              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _OracleOrbGlow(size: 96, accent: accent),
                ],
              ),
            ),
          ],
        ),
        if (_homeScrollHint(snap.assets.length) != null) ...[
          const SizedBox(height: 8),
          _homeScrollHint(snap.assets.length)!,
        ],
        const SizedBox(height: 10),
        // Per-asset cards: bias chip, price, 24h %, session low/high levels
        for (final asset in previewAssets) _OracleAssetBiasCard(
          asset: asset,
          onTap: () => widget.onCoinTap(asset.symbol),
        ),
        for (final asset in restAssets) _OracleAssetBiasCard(
          asset: asset,
          onTap: () => widget.onCoinTap(asset.symbol),
        ),
      ],
    );
  }
}

class _OracleBiasPill extends StatelessWidget {
  final String label;
  final Color color;

  const _OracleBiasPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.2),
      ),
    );
  }
}

class _OracleAssetBiasCard extends StatelessWidget {
  final _OracleAssetBias asset;
  final VoidCallback onTap;

  const _OracleAssetBiasCard({required this.asset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = _oracleBiasAccent(asset.microBias);
    final changeColor = asset.change24hPct >= 0 ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final changePrefix = asset.change24hPct >= 0 ? '+' : '';

    return Padding(
      padding: _kHomeCardGap,
      child: _ScaleTap(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    asset.symbol,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.3),
                  ),
                  const SizedBox(width: 8),
                  _OracleBiasPill(label: _oracleBiasLabel(asset.microBias), color: accent),
                  const Spacer(),
                  Text(
                    _formatOraclePrice(asset.priceUsd),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$changePrefix${asset.change24hPct.toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: changeColor),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _OracleLevelChip(
                      label: 'Support',
                      value: _formatOraclePrice(asset.low24h),
                      color: const Color(0xFF00BFFF),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _OracleLevelChip(
                      label: 'Resistance',
                      value: _formatOraclePrice(asset.high24h),
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OracleLevelChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _OracleLevelChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey[600])),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

/// Compact rounded action chip (Trade Performance & legacy trade rows).
class _HistoryChipButton extends StatelessWidget {
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;

  const _HistoryChipButton({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return _ScaleTap(
      onTap: onPressed,
      child: SizedBox(
        height: 30,
        child: Material(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: foregroundColor,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// News list embedded in Home scroll (thumbnail + headline + source).
class _HomeNewsBlock extends StatelessWidget {
  final GlobalKey<_MarketNewsFeedState> feedKey;

  const _HomeNewsBlock({required this.feedKey});

  @override
  Widget build(BuildContext context) {
    return _MarketNewsFeed(key: feedKey, nestedInParentScroll: true);
  }
}

class _MarketNewsFeed extends StatefulWidget {
  /// When true, headline cards are plain Column children (Home page scroll only).
  final bool nestedInParentScroll;

  const _MarketNewsFeed({super.key, this.nestedInParentScroll = false});

  @override
  State<_MarketNewsFeed> createState() => _MarketNewsFeedState();
}

class _MarketNewsFeedState extends State<_MarketNewsFeed> {
  List<Map<String, dynamic>> _articles = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchNews();
  }

  /// Home pull-to-refresh — reload headlines.
  Future<void> refreshFromPull() => _fetchNews();

  Future<void> _fetchNews() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    if (kNewsApiKey.isEmpty || kNewsApiKey == 'YOUR_NEWS_API_KEY_HERE') {
      setState(() {
        _loading = false;
        _error = 'Add your NewsAPI key via --dart-define=NEWS_API_KEY=your_key';
      });
      return;
    }

    try {
      final uri = Uri.https(
        'newsapi.org',
        '/v2/everything',
        {
          'q': 'cryptocurrency OR bitcoin OR ethereum OR solana OR ripple',
          'sortBy': 'publishedAt',
          'language': 'en',
          'pageSize': '10',
          'apiKey': kNewsApiKey,
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('NewsAPI returned ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'ok') {
        throw Exception(data['message']?.toString() ?? 'Failed to load news');
      }

      final rawArticles = (data['articles'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .where((article) => (article['title'] ?? '').toString().trim().isNotEmpty)
          .toList();

      if (mounted) {
        setState(() {
          _articles = rawArticles;
          _loading = false;
          if (_articles.isEmpty) {
            _error = 'No crypto headlines found right now.';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load news. Check connection and API key.';
        });
      }
    }
  }

  Future<void> _openArticle(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open article link')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final listPhysics = widget.nestedInParentScroll
        ? const NeverScrollableScrollPhysics()
        : const BouncingScrollPhysics();
    final shrinkWrap = widget.nestedInParentScroll;

    if (_loading) {
      return SizedBox(
        height: widget.nestedInParentScroll ? 120 : null,
        child: const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF))),
      );
    }

    if (_error != null) {
      final isEmptyFeed = _error == 'No crypto headlines found right now.';
      return _AppEmptyState(
        icon: isEmptyFeed ? Icons.newspaper_outlined : Icons.cloud_off_outlined,
        title: isEmptyFeed ? 'No headlines right now' : 'News unavailable',
        subtitle: _error!,
        action: TextButton.icon(
          onPressed: _fetchNews,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry'),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFF00BFFF)),
        ),
      );
    }

    if (widget.nestedInParentScroll) {
      final total = _articles.length;
      final hint = _homeScrollHint(total);
      final previewEnd = total < _kHomePreviewCount ? total : _kHomePreviewCount;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null) hint,
          for (int i = 0; i < previewEnd; i++) _newsItemBuilder(context, i),
          for (int i = _kHomePreviewCount; i < total; i++) _newsItemBuilder(context, i),
        ],
      );
    }

    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: listPhysics,
      itemCount: _articles.length,
      itemBuilder: _newsItemBuilder,
    );
  }

  Widget _newsItemBuilder(BuildContext context, int index) {
    final article = _articles[index];
    final title = (article['title'] ?? '').toString();
    final source = (article['source'] as Map<String, dynamic>?)?['name']?.toString() ?? 'Unknown';
    final url = (article['url'] ?? '').toString();
    final imageUrl = (article['urlToImage'] ?? '').toString();
    final publishedAt = DateTime.tryParse((article['publishedAt'] ?? '').toString());

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 300 + (index * 50).clamp(0, 250)),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(offset: Offset(0, (1 - value) * 8), child: child),
      ),
      child: _LiveNewsCard(
        title: title,
        source: source,
        timeAgo: _formatTimeAgo(publishedAt),
        imageUrl: imageUrl.isNotEmpty ? imageUrl : null,
        onTap: url.isNotEmpty ? () => _openArticle(url) : null,
      ),
    );
  }

  String _formatTimeAgo(DateTime? published) {
    if (published == null) return 'Recently';
    final diff = DateTime.now().difference(published.toLocal());
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${published.month}/${published.day}/${published.year}';
  }
}

class _LiveNewsCard extends StatelessWidget {
  final String title;
  final String source;
  final String timeAgo;
  final String? imageUrl;
  final VoidCallback? onTap;

  const _LiveNewsCard({
    required this.title,
    required this.source,
    required this.timeAgo,
    this.imageUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _ScaleTap(
        onTap: onTap,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: imageUrl != null
                      ? Image.network(
                          imageUrl!,
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _newsPlaceholder(),
                        )
                      : _newsPlaceholder(),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, height: 1.35),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              source,
                              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.access_time, size: 12, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(timeAgo, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                          if (onTap != null) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.open_in_new, size: 13, color: Colors.grey[600]),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _newsPlaceholder() {
    return Container(
      width: 60,
      height: 60,
      color: const Color(0xFF2A2A2A),
      child: const Icon(Icons.auto_awesome, color: Color(0xFF00BFFF), size: 26),
    );
  }
}

// ==================== PROFILE & SETTINGS ====================

/// Shared scaffold for Profile sub-screens with consistent styling.
class _ProfileDetailScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final bool showOracleBackdrop;

  const _ProfileDetailScaffold({
    required this.title,
    required this.body,
    this.showOracleBackdrop = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showOracleBackdrop)
            const OracleProfileBackdrop(
              centeredOrb: true,
              orbHeight: kProfileBackgroundOrbHeight,
              orbOpacity: kProfileBackgroundOrbOpacity,
            ),
          Positioned.fill(
            child: SafeArea(
              child: _FadeIn(child: body),
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _planLabel = 'Free Plan';
  bool _isExpert = false;
  String _displayName = UserProfileStore.defaultDisplayName;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    await Future.wait([
      SubscriptionPlanStore.load(),
      UserProfileStore.load(),
    ]);
    if (mounted) {
      setState(() {
        _planLabel = '${SubscriptionPlanStore.currentPlan} Plan';
        _isExpert = SubscriptionPlanStore.isExpert;
        _displayName = UserProfileStore.displayName;
      });
    }
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.push(context, _premiumPageRoute((_) => screen)).then((_) {
      _loadProfileData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const OracleProfileBackdrop(
            centeredOrb: true,
            orbHeight: kProfileBackgroundOrbHeight,
            orbOpacity: kProfileBackgroundOrbOpacity,
          ),
          Positioned.fill(
            child: SafeArea(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  _AppSpacing.screen,
                  12,
                  _AppSpacing.screen,
                  _AppSpacing.screen + MediaQuery.paddingOf(context).bottom + 24,
                ),
                children: [
                  OracleOrbHeroCard(
                    displayName: _displayName,
                    subtitle: _planLabel,
                    onTap: () => _open(context, const AccountScreen()),
                    trailing: Icon(Icons.chevron_right, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: _AppSpacing.section),
                  const _SectionHeader(title: 'Account'),
                  _ProfileMenuTile(
                    icon: Icons.edit_outlined,
                    title: 'Edit Profile',
                    subtitle: 'Display name, email, and timezone',
                    onTap: () async {
                      final saved = await Navigator.push<bool>(
                        context,
                        _premiumPageRoute((_) => const EditProfileScreen()),
                      );
                      if (saved == true) _loadProfileData();
                    },
                  ),
                  _ProfileMenuTile(
                    icon: Icons.person_outline,
                    title: 'Account',
                    subtitle: 'Manage profile and preferences',
                    onTap: () => _open(context, const AccountScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.workspace_premium_outlined,
                    title: 'Subscription Plan',
                    subtitle: 'View or upgrade your plan',
                    onTap: () => _open(context, const SubscriptionPlanScreen()),
                  ),
                  const SizedBox(height: _AppSpacing.item),
                  const _SectionHeader(title: 'Community'),
                  const CommunityLinksSection(),
                  const SizedBox(height: _AppSpacing.item),
                  const _SectionHeader(title: 'App'),
                  _ProfileMenuTile(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    subtitle: 'Notifications, theme, and more',
                    onTap: () => _open(context, const SettingsScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.security_outlined,
                    title: 'Privacy & Security',
                    subtitle: 'Data and account security',
                    onTap: () => _open(context, const PrivacySecurityScreen()),
                  ),
                  if (_isExpert)
                    _ProfileMenuTile(
                      icon: Icons.shield_outlined,
                      title: 'Oracle Citadel',
                      subtitle: 'Configure secure automated trading',
                      onTap: () => showCitadelSetupDialog(context),
                    ),
                  _ProfileMenuTile(
                    icon: Icons.help_outline,
                    title: 'Help & Support',
                    subtitle: 'FAQs and contact support',
                    onTap: () => _open(context, const HelpSupportScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.info_outline,
                    title: 'About',
                    subtitle: 'On-Chain Oracle AI v1.0.1',
                    onTap: () => _open(context, const AboutScreen()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ProfileMenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _ScaleTap(
        onTap: onTap,
        child: Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF00BFFF), size: 22),
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            trailing: Icon(Icons.chevron_right, color: Colors.grey[600]),
          ),
        ),
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  @override
  void initState() {
    super.initState();
    UserProfileStore.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _openEditProfile() async {
    final saved = await Navigator.push<bool>(
      context,
      _premiumPageRoute((_) => const EditProfileScreen()),
    );
    if (saved == true && mounted) {
      await UserProfileStore.load();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Account',
      showOracleBackdrop: true,
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          _AppSpacing.screen,
          _AppSpacing.screen,
          _AppSpacing.screen,
          _AppSpacing.screen + MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          OracleOrbHeroCard(
            displayName: UserProfileStore.displayName,
            subtitle: UserProfileStore.email,
            profileImagePath: UserProfileStore.avatarPath,
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Profile Details'),
          _AccountField(label: 'Display Name', value: UserProfileStore.displayName),
          _AccountField(label: 'Email', value: UserProfileStore.email),
          _AccountField(label: 'Plan Tier', value: UserProfileStore.tier),
          _AccountField(label: 'Member Since', value: UserProfileStore.memberSince),
          _AccountField(label: 'Timezone', value: UserProfileStore.timezone),
          const SizedBox(height: _AppSpacing.section),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _openEditProfile,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFFF),
                foregroundColor: Colors.black,
              ),
              child: const Text('Edit Profile'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: () async {
                await AuthService.signOut();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  PageRouteBuilder<void>(
                    pageBuilder: (_, __, ___) => LoginScreen(
                      onSuccess: (ctx) {
                        Navigator.of(ctx).pushReplacement(
                          MaterialPageRoute<void>(builder: (_) => const MainScreen()),
                        );
                      },
                    ),
                    transitionsBuilder: (_, animation, __, child) =>
                        FadeTransition(opacity: animation, child: child),
                  ),
                  (_) => false,
                );
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF5252),
                side: BorderSide(color: const Color(0xFFFF5252).withValues(alpha: 0.45)),
              ),
              child: const Text('Sign Out'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountField extends StatelessWidget {
  final String label;
  final String value;

  const _AccountField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          subtitle: Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white)),
        ),
      ),
    );
  }
}

class SubscriptionPlanScreen extends StatefulWidget {
  const SubscriptionPlanScreen({super.key});

  @override
  State<SubscriptionPlanScreen> createState() => _SubscriptionPlanScreenState();
}

class _SubscriptionPlanScreenState extends State<SubscriptionPlanScreen> {
  String _currentPlan = 'Free';

  @override
  void initState() {
    super.initState();
    SubscriptionPlanStore.load().then((_) {
      if (mounted) setState(() => _currentPlan = SubscriptionPlanStore.currentPlan);
    });
  }

  void _upgrade(String plan) {
    if (plan == _currentPlan) return;
    setState(() => _currentPlan = plan);
    SubscriptionPlanStore.setPlan(plan);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Upgraded to $plan — payment integration coming soon')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Subscription',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          _FadeIn(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF00BFFF).withValues(alpha: 0.2),
                    const Color(0xFF1A1A1A),
                    const Color(0xFF0F0F0F),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.workspace_premium, color: Color(0xFF00BFFF), size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Upgrade Your Edge',
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Current plan: $_currentPlan',
                              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Unlock deeper analysis, unlimited setups, Oracle Trader AI Chat, and institutional-grade tools.',
                    style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Choose Your Plan'),
          _PricingTierCard(
            name: 'Free',
            tagline: 'Get started with core markets',
            price: '\$0',
            period: '/month',
            icon: Icons.lock_open_outlined,
            accentColor: Colors.grey,
            features: const [
              'Daily Analysis (BTC, ETH, SOL only)',
              'Basic Watchlist (max 5 coins)',
              'Limited Trade Setups (3 per day)',
            ],
            isCurrent: _currentPlan == 'Free',
            badge: null,
            showUpgradeButton: false,
            onUpgrade: () {},
          ),
          _PricingTierCard(
            name: 'Premium',
            tagline: 'Full market coverage for active traders',
            price: '\$39',
            period: '/month',
            icon: Icons.diamond_outlined,
            accentColor: const Color(0xFF00BFFF),
            features: const [
              'Full coin coverage (Top 150)',
              'Unlimited Trade Setups',
              'AI Chat (limited)',
              'All timeframes',
              'Advanced custom alerts',
            ],
            isCurrent: _currentPlan == 'Premium',
            badge: null,
            showUpgradeButton: true,
            onUpgrade: () => _upgrade('Premium'),
          ),
          _PricingTierCard(
            name: 'Expert',
            tagline: 'Top Tier — maximum Oracle power',
            price: '\$79',
            period: '/month',
            icon: Icons.auto_awesome,
            accentColor: const Color(0xFFFFB74D),
            features: const [
              'Everything in Premium',
              'Full Oracle Citadel (Automated Live Execution)',
              'Unlimited Oracle Trader AI Chat',
              'Oracle Vision (Live High-Conviction Opportunities)',
              'Oracle Desk (Advanced Performance + Personal Command Center)',
            ],
            isCurrent: _currentPlan == 'Expert',
            badge: 'MOST POPULAR',
            showUpgradeButton: true,
            onUpgrade: () => _upgrade('Expert'),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Cancel anytime · Secure checkout coming soon',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }
}

class _PricingTierCard extends StatelessWidget {
  final String name;
  final String tagline;
  final String price;
  final String period;
  final IconData icon;
  final Color accentColor;
  final List<String> features;
  final bool isCurrent;
  final String? badge;
  final bool showUpgradeButton;
  final VoidCallback onUpgrade;

  const _PricingTierCard({
    required this.name,
    required this.tagline,
    required this.price,
    required this.period,
    required this.icon,
    required this.accentColor,
    required this.features,
    required this.isCurrent,
    required this.badge,
    required this.showUpgradeButton,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final isHighlighted = badge != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isCurrent
                ? const Color(0xFF00E676).withValues(alpha: 0.45)
                : isHighlighted
                    ? accentColor.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.06),
            width: isCurrent || isHighlighted ? 1.5 : 1,
          ),
        ),
        child: Container(
          decoration: isHighlighted && !isCurrent
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accentColor.withValues(alpha: 0.06),
                      Colors.transparent,
                    ],
                  ),
                )
              : null,
          padding: const EdgeInsets.all(_AppSpacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accentColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            if (badge != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                                ),
                                child: Text(
                                  badge!,
                                  style: TextStyle(fontSize: 10, color: accentColor, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(tagline, style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.3)),
                      ],
                    ),
                  ),
                  if (isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Current',
                        style: TextStyle(fontSize: 11, color: Color(0xFF00E676), fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: name == 'Free' ? Colors.white : accentColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(period, style: TextStyle(fontSize: 14, color: Colors.grey[500])),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
              const SizedBox(height: 14),
              ...features.map(
                (f) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_rounded, size: 18, color: accentColor.withValues(alpha: 0.85)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          f,
                          style: TextStyle(fontSize: 14, color: Colors.grey[300], height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showUpgradeButton) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: _ScaleTap(
                    onTap: isCurrent ? null : onUpgrade,
                    child: ElevatedButton(
                      onPressed: isCurrent ? null : onUpgrade,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isCurrent ? Colors.grey[800] : accentColor,
                        foregroundColor: isCurrent ? Colors.grey[500] : Colors.black,
                        disabledBackgroundColor: Colors.grey[800],
                        minimumSize: const Size.fromHeight(50),
                        elevation: isCurrent ? 0 : 2,
                      ),
                      child: Text(
                        isCurrent ? 'Current Plan' : 'Upgrade to $name',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                  ),
                ),
              ] else if (isCurrent) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: const Text(
                    'Current Plan',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotifications = true;
  bool _emailAlerts = false;
  bool _analysisComplete = true;
  bool _darkMode = true;
  bool _hapticFeedback = true;

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Settings',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          const _SectionHeader(title: 'Notifications'),
          _SettingsSwitchTile(
            icon: Icons.notifications_active_outlined,
            title: 'Push Notifications',
            subtitle: 'Receive alerts on your device',
            value: _pushNotifications,
            onChanged: (v) => setState(() => _pushNotifications = v),
          ),
          _SettingsSwitchTile(
            icon: Icons.email_outlined,
            title: 'Email Alerts',
            subtitle: 'Get updates via email',
            value: _emailAlerts,
            onChanged: (v) => setState(() => _emailAlerts = v),
          ),
          _SettingsSwitchTile(
            icon: Icons.analytics_outlined,
            title: 'Analysis Complete',
            subtitle: 'Notify when AI analysis finishes',
            value: _analysisComplete,
            onChanged: (v) => setState(() => _analysisComplete = v),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'Appearance'),
          _SettingsSwitchTile(
            icon: Icons.dark_mode_outlined,
            title: 'Dark Mode',
            subtitle: 'Always on (app default)',
            value: _darkMode,
            onChanged: (v) => setState(() => _darkMode = v),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'General'),
          _SettingsSwitchTile(
            icon: Icons.vibration,
            title: 'Haptic Feedback',
            subtitle: 'Vibrate on button taps',
            value: _hapticFeedback,
            onChanged: (v) => setState(() => _hapticFeedback = v),
          ),
          _ProfileMenuTile(
            icon: Icons.language,
            title: 'Language',
            subtitle: 'English (US)',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Language selection — coming soon')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          secondary: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00BFFF), size: 22),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          value: value,
          activeThumbColor: const Color(0xFF00BFFF),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class PrivacySecurityScreen extends StatelessWidget {
  const PrivacySecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Privacy & Security',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(_AppSpacing.card),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: const Color(0xFF00BFFF).withValues(alpha: 0.9)),
                      const SizedBox(width: 10),
                      const Text('Your Data', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'On-Chain Oracle AI processes market data and your analysis requests to generate reports. '
                    'We do not sell your personal information to third parties.',
                    style: TextStyle(fontSize: 14, height: 1.55, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.item),
          _PrivacySection(
            title: 'Data Collection',
            body: 'We collect usage analytics and coin symbols you analyze to improve AI accuracy. '
                'Trade setup history is stored locally on your device.',
          ),
          _PrivacySection(
            title: 'Account Security',
            body: 'Enable two-factor authentication when available. Never share your API keys or '
                'account credentials with anyone.',
          ),
          _PrivacySection(
            title: 'Third-Party Services',
            body: 'Charts powered by TradingView. Price data from Binance and CoinGecko. '
                'News from NewsAPI. Each service has its own privacy policy.',
          ),
          const SizedBox(height: _AppSpacing.section),
          _ProfileMenuTile(
            icon: Icons.policy_outlined,
            title: 'Privacy Policy',
            subtitle: 'Read our full privacy policy',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Privacy Policy — coming soon')),
              );
            },
          ),
          _ProfileMenuTile(
            icon: Icons.delete_outline,
            title: 'Delete Account',
            subtitle: 'Permanently remove your data',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Account deletion — contact support')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  final String title;
  final String body;

  const _PrivacySection({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(_AppSpacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(body, style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400])),
            ],
          ),
        ),
      ),
    );
  }
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const _faqs = [
    (
      'How do I run an analysis?',
      'Tap the Analyze tab, enter a coin symbol (e.g. BTC), and press Get Analysis. '
          'Results appear with a live chart and AI report.',
    ),
    (
      'What is Trade Setup?',
      'Trade Setup generates execution-ready levels (Entry, SL, TP1, TP2) with a minimum 2.1:1 risk-reward ratio.',
    ),
    (
      'How does the watchlist work?',
      'On Home, tap + to add coins. Tap any watchlist coin to open its chart instantly.',
    ),
    (
      'How is win rate calculated?',
      'Win rate tracks closed trade setups marked Win or Loss based on live price vs your levels.',
    ),
    (
      'Can I upgrade my plan?',
      'Go to Profile → Subscription Plan to compare Free, Premium, and Expert tiers.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Help & Support',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.mail_outline, color: Color(0xFF00BFFF)),
              ),
              title: const Text('Contact Support', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('support@onchainoracle.ai', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              trailing: Icon(Icons.open_in_new, size: 18, color: Colors.grey[600]),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Opening email client — coming soon')),
                );
              },
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Frequently Asked Questions'),
          ..._faqs.map(
            (faq) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    title: Text(faq.$1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    iconColor: const Color(0xFF00BFFF),
                    collapsedIconColor: Colors.grey[600],
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          faq.$2,
                          style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _appVersion = '1.0.1';
  static const _buildNumber = '2';

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'About',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              child: Column(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF00BFFF).withValues(alpha: 0.3),
                          const Color(0xFF1A1A1A),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.3)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        kAppLogoAsset,
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, __, ___) => Image.asset(
                          'assets/images/app_icon.png',
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'On-Chain Oracle AI',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Version $_appVersion (Build $_buildNumber)',
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          _AboutInfoRow(label: 'Developer', value: 'On-Chain Oracle Team'),
          _AboutInfoRow(label: 'Platform', value: 'Flutter'),
          _AboutInfoRow(label: 'Release', value: 'May 2026'),
          const SizedBox(height: _AppSpacing.item),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(_AppSpacing.card),
              child: Text(
                'On-Chain Oracle AI delivers institutional-grade crypto market analysis and trade setups '
                'powered by AI. Charts, watchlists, alerts, and portfolio tools — all in one professional app.',
                style: TextStyle(fontSize: 14, height: 1.55, color: Colors.grey[400]),
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          Center(
            child: Text(
              '© 2026 On-Chain Oracle AI. All rights reserved.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

// Analysis Report
class AnalysisReportScreen extends StatefulWidget {
  final String? coin;
  final Map<String, dynamic>? historyItem;
  final void Function(String coin, String report)? onNewAnalysis;

  const AnalysisReportScreen({super.key, this.coin, this.historyItem, this.onNewAnalysis});
  factory AnalysisReportScreen.fromHistory(Map<String, dynamic> item) => AnalysisReportScreen(coin: item['coin'], historyItem: item);
  @override
  State<AnalysisReportScreen> createState() => _AnalysisReportScreenState();
}

class _AnalysisReportScreenState extends State<AnalysisReportScreen> {
  String report = "Loading...";
  bool loading = true;
  late final String resolvedCoin;
  WebViewController? _chartController;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(
          (widget.coin ?? widget.historyItem?['coin'] ?? 'BTC').toString(),
        ) ??
        'BTC';
    if (widget.historyItem != null) {
      report = widget.historyItem!['report'];
      loading = false;
      _chartController = createTradingViewController(resolvedCoin);
    } else {
      _fetchFromBackend();
    }
  }

  void _ensureChartController() {
    _chartController ??= createTradingViewController(resolvedCoin);
  }

  Future<void> _fetchFromBackend() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final response = await _postAnalyzeWithRetry(
        payload: {
          "coin": resolvedCoin,
          "mode": "analysis",
          "timeframe": "1h",
          "direction": "Smart Direction",
          "report_style": "professional",
          "system_prompt": grokSystemPrompt(mode: "analysis"),
          "refresh_price": true,
          "request_ts": DateTime.now().millisecondsSinceEpoch,
          ..._analyzeCitadelContext(),
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          report = data['report'] ?? "No report";
          loading = false;
          _ensureChartController();
        });
        if (widget.onNewAnalysis != null) {
          widget.onNewAnalysis!(resolvedCoin, report);
        }
      } else {
        debugPrint('[Analysis] HTTP ${response.statusCode}: ${response.body}');
        setState(() {
          errorMessage = "Unable to generate analysis right now. Please try again.";
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('[Analysis] Request failed: $e');
      setState(() {
        errorMessage = "Cannot connect to backend. Check API server and retry.";
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(resolvedCoin)),
      floatingActionButton: loading || errorMessage != null
          ? null
          : CompactChatFab(
              heroTag: 'analysis_chat_$resolvedCoin',
              onPressed: () => openAiChat(context),
            ),
      body: loading
          ? const _PremiumAiLoadingPanel(
              title: 'Generating Analysis',
              subtitle: 'Fetching live price and building your Oracle report…',
            )
          : errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _fetchFromBackend,
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen + reportScrollBottomInset(context),
              ),
              child: Column(
                children: [
                  if (_chartController != null)
                    TradingViewChartPanel(
                      symbol: resolvedCoin,
                      controller: _chartController!,
                    ),
                  const SizedBox(height: _AppSpacing.section),
                  Text(report, style: const TextStyle(fontSize: 16, height: 1.65)),
                  const SizedBox(height: _AppSpacing.section),
                  SendToCitadelButton(
                    coin: resolvedCoin,
                    directionLabel: 'Smart Direction',
                    reportText: report,
                  ),
                ],
              ),
            ),
    );
  }
}

// Review Report — Telegram-bot style review via POST /review
class ReviewReportScreen extends StatefulWidget {
  final Map<String, dynamic> historyItem;

  const ReviewReportScreen({super.key, required this.historyItem});

  @override
  State<ReviewReportScreen> createState() => _ReviewReportScreenState();
}

class _ReviewReportScreenState extends State<ReviewReportScreen> {
  String? reviewText;
  bool loading = true;
  String? errorMessage;
  late final String resolvedCoin;
  late final String storedReport;
  late final bool isTradeSetup;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(widget.historyItem['coin']?.toString() ?? 'BTC') ?? 'BTC';
    storedReport = (widget.historyItem['report'] ?? '').toString();
    isTradeSetup = widget.historyItem['source'] == 'trade_setup';
    _fetchReview();
  }

  Future<void> _fetchReview() async {
    setState(() {
      loading = true;
      errorMessage = null;
      reviewText = null;
    });

    if (isPlaceholderStoredReport(storedReport)) {
      setState(() {
        errorMessage = isTradeSetup
            ? 'No saved report for this trade — run Trade Setup again to generate a fresh report.'
            : 'No stored report found for this item.';
        loading = false;
      });
      return;
    }

    try {
      final response = await _postReviewWithRetry(
        coin: resolvedCoin,
        previousReport: storedReport,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          reviewText = (data['review'] ?? data['report'] ?? '').toString();
          if (reviewText!.trim().isEmpty) {
            errorMessage = "Backend returned an empty review.";
            reviewText = null;
          }
          loading = false;
        });
      } else {
        setState(() {
          errorMessage = "Unable to generate review (${response.statusCode}). Please try again.";
          loading = false;
        });
      }
    } catch (_) {
      setState(() {
        errorMessage = "Cannot connect to backend. Check API server and retry.";
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = isTradeSetup
        ? "Review of $resolvedCoin Trade"
        : "Review of $resolvedCoin Analysis";

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text("Review"),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      floatingActionButton: CompactChatFab(
        heroTag: 'review_chat_$resolvedCoin',
        onPressed: () => openAiChat(context),
      ),
      body: loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00BFFF)),
                  SizedBox(height: 16),
                  Text("Generating review...", style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : errorMessage != null
              ? _AppEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Something went wrong',
                  subtitle: errorMessage!,
                  action: ElevatedButton(
                    onPressed: _fetchReview,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BFFF),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Retry'),
                  ),
                )
              : SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.all(_AppSpacing.screen),
                  child: _FadeIn(
                    child: _ReviewFormattedContent(
                      title: title,
                      reviewText: reviewText!,
                    ),
                  ),
                ),
    );
  }
}

/// Parses Telegram-style review text into structured sections for display.
class _ParsedReview {
  final String? score;
  final String? whatGotRight;
  final String? whatDidnt;
  final String? currentStatus;
  final String fallbackBody;

  const _ParsedReview({
    this.score,
    this.whatGotRight,
    this.whatDidnt,
    this.currentStatus,
    required this.fallbackBody,
  });

  factory _ParsedReview.fromText(String text) {
    final scoreMatch = RegExp(r'Score:\s*([\d.]+)\s*/\s*10', caseSensitive: false).firstMatch(text);
    final score = scoreMatch?.group(1);

    String? extractSection(String source, List<String> headers) {
      for (final header in headers) {
        final pattern = RegExp(
          r'(?:^|\n)\s*[*#\-]*\s*' +
              RegExp.escape(header) +
              r'\s*[*#:\-]*\s*\n([\s\S]*?)(?=\n\s*[*#\-]*\s*(?:What|Current|Score|$)|$)',
          caseSensitive: false,
        );
        final match = pattern.firstMatch(source);
        if (match != null) {
          final body = match.group(1)?.trim();
          if (body != null && body.isNotEmpty) return body;
        }
      }
      return null;
    }

    return _ParsedReview(
      score: score,
      whatGotRight: extractSection(text, ['What got right', 'What went right', 'What was right']),
      whatDidnt: extractSection(text, ["What didn't", "What did not", "What went wrong", "What was wrong"]),
      currentStatus: extractSection(text, ['Current Status', 'Current status', 'Status']),
      fallbackBody: text.trim(),
    );
  }

  bool get hasStructuredSections =>
      whatGotRight != null || whatDidnt != null || currentStatus != null;
}

class _ReviewFormattedContent extends StatelessWidget {
  final String title;
  final String reviewText;

  const _ReviewFormattedContent({
    required this.title,
    required this.reviewText,
  });

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedReview.fromText(reviewText);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1A1A1A),
                const Color(0xFF00BFFF).withValues(alpha: 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              if (parsed.score != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    "Score: ${parsed.score}/10",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00BFFF),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (parsed.hasStructuredSections) ...[
          if (parsed.whatGotRight != null)
            _ReviewSectionCard(
              title: "What Got Right",
              body: parsed.whatGotRight!,
              icon: Icons.check_circle_outline,
              accentColor: const Color(0xFF00E676),
            ),
          if (parsed.whatDidnt != null)
            _ReviewSectionCard(
              title: "What Didn't",
              body: parsed.whatDidnt!,
              icon: Icons.cancel_outlined,
              accentColor: const Color(0xFFFF5252),
            ),
          if (parsed.currentStatus != null)
            _ReviewSectionCard(
              title: "Current Status",
              body: parsed.currentStatus!,
              icon: Icons.insights_outlined,
              accentColor: const Color(0xFF00BFFF),
            ),
        ] else
          _ReviewSectionCard(
            title: "Review",
            body: parsed.fallbackBody,
            icon: Icons.rate_review_outlined,
            accentColor: const Color(0xFF00BFFF),
          ),
      ],
    );
  }
}

class _ReviewSectionCard extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  final Color accentColor;

  const _ReviewSectionCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.accentColor,
  });

  List<String> _bulletLines(String text) {
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.replaceFirst(RegExp(r'^[-•*]\s*'), ''))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final bullets = _bulletLines(body);
    final useBullets = bullets.length > 1 || body.contains(RegExp(r'^\s*[-•*]', multiLine: true));

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (useBullets)
            ...bullets.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        line,
                        style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[300]),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Text(
              body,
              style: TextStyle(fontSize: 14, height: 1.6, color: Colors.grey[300]),
            ),
        ],
      ),
    );
  }
}

Future<http.Response> _postReviewWithRetry({
  required String coin,
  required String previousReport,
  int attempts = 3,
}) async {
  Object? lastError;
  final payload = {
    "coin": coin,
    "previous_report": previousReport,
  };

  for (int i = 0; i < attempts; i++) {
    try {
      final uri = Uri.parse('$kBackendBaseUrl/review');
      debugPrint('[HTTP POST] $uri coin=$coin (attempt ${i + 1}/$attempts)');
      final response = await http
          .post(
            uri,
            headers: {
              "Content-Type": "application/json",
              "Cache-Control": "no-cache, no-store, must-revalidate",
              "Pragma": "no-cache",
              "Expires": "0",
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 90));
      debugPrint('[HTTP POST] $uri → ${response.statusCode}');
      if (response.statusCode >= 500 && i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        continue;
      }
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] review attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception("Unknown review request error");
}

// Trade Setup result screen with chart + full report
class TradeSetupResultScreen extends StatefulWidget {
  final String coin;
  final String timeframe;
  final String direction;
  final Function(Map<String, dynamic>) onTradeSetupGenerated;
  /// Oracle Vision prefill — passed to backend for confluence-aware levels.
  final int? convictionPct;

  const TradeSetupResultScreen({
    super.key,
    required this.coin,
    required this.timeframe,
    required this.direction,
    required this.onTradeSetupGenerated,
    this.convictionPct,
  });

  @override
  State<TradeSetupResultScreen> createState() => _TradeSetupResultScreenState();
}

class _TradeSetupResultScreenState extends State<TradeSetupResultScreen> {
  String report = "Loading...";
  bool loading = true;
  bool _saved = false;
  late final String resolvedCoin;
  WebViewController? _chartController;
  String? errorMessage;
  double? _entry;
  double? _tp1;
  double? _tp2;
  double? _sl;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(widget.coin) ?? widget.coin.trim().toUpperCase();
    // Clear stale Citadel error snackbars from prior sends (e.g. IP whitelist) on this scaffold.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
    });
    _fetchTradeSetup();
  }

  void _ensureChartController() {
    _chartController ??= createTradeSetupTradingViewController(
      resolvedCoin,
      timeframe: widget.timeframe,
    );
  }

  Future<void> _fetchTradeSetup() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final visionHint = widget.convictionPct != null
          ? '\n\nOracle Vision pulse: ${widget.convictionPct}% ${widget.direction} confluence on ${widget.timeframe}. '
              'Honor bias when grading Daily VWAP, structure, and Entry/SL/TP1 (40%)/TP2 (60%).'
          : '';
      final response = await _postAnalyzeWithRetry(
        payload: {
          "coin": resolvedCoin,
          "mode": "tradesetup",
          "timeframe": widget.timeframe,
          "direction": widget.direction,
          "report_style": "professional",
          "system_prompt": grokSystemPrompt(mode: "tradesetup") + visionHint,
          "refresh_price": true,
          "request_ts": DateTime.now().millisecondsSinceEpoch,
          if (widget.convictionPct != null) "vision_confluence_pct": widget.convictionPct,
          ..._analyzeCitadelContext(),
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final fetchedReport = (data['report'] ?? 'No report').toString();
        setState(() {
          report = fetchedReport;
          loading = false;
          _ensureChartController();
        });
        _saveTradeSetupIfNeeded(fetchedReport);
      } else {
        debugPrint('[TradeSetup] HTTP ${response.statusCode}: ${response.body}');
        setState(() {
          errorMessage = "Failed to generate trade setup (${response.statusCode}). Please try again.";
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('[TradeSetup] Request failed: $e');
      setState(() {
        errorMessage = "Cannot connect to backend. Please retry in a moment.";
        loading = false;
      });
    }
  }

  void _saveTradeSetupIfNeeded(String reportText) {
    if (_saved) return;
    if (isPlaceholderStoredReport(reportText)) return;
    _saved = true;
    final parsed = parseCitadelTradeLevels(reportText);
    _entry = parsed.entry;
    _tp1 = parsed.tp1;
    _tp2 = parsed.tp2;
    _sl = parsed.sl;
    widget.onTradeSetupGenerated({
      "coin": resolvedCoin,
      "report": reportText,
      "timeframe": widget.timeframe,
      "direction": widget.direction,
      "entry": _entry,
      "tp1": _tp1,
      "tp2": _tp2,
      "sl": _sl,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("$resolvedCoin Trade Setup")),
      floatingActionButton: loading || errorMessage != null
          ? null
          : CompactChatFab(
              heroTag: 'tradesetup_chat_$resolvedCoin',
              onPressed: () => openAiChat(context),
            ),
      body: loading
          ? const _PremiumAiLoadingPanel(
              title: 'Generating Trade Setup',
              subtitle: 'Building levels, R:R, and confluence for your plan…',
            )
          : errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _fetchTradeSetup,
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen + reportScrollBottomInset(context),
              ),
              child: Column(
                children: [
                  if (_chartController != null)
                    TradingViewChartPanel(
                      symbol: resolvedCoin,
                      controller: _chartController!,
                      tradeSetupTimeframe: widget.timeframe,
                      premiumFrame: true,
                    ),
                  const SizedBox(height: _AppSpacing.section),
                  Text(report, style: const TextStyle(fontSize: 16, height: 1.65)),
                  const SizedBox(height: _AppSpacing.section),
                  SendToCitadelButton(
                    coin: resolvedCoin,
                    directionLabel: widget.direction,
                    reportText: report,
                    entry: _entry,
                    stopLoss: _sl,
                    tp1: _tp1,
                    tp2: _tp2,
                  ),
                ],
              ),
            ),
    );
  }
}

Future<http.Response> _postAnalyzeWithRetry({
  required Map<String, dynamic> payload,
  int attempts = 3,
}) async {
  Object? lastError;
  final uri = Uri.parse('$kBackendBaseUrl/analyze');
  final body = jsonEncode(payload);
  final authHeaders = await AppApiKeyService.backendHeaders();
  debugPrint('[HTTP POST] $uri mode=${payload['mode']} coin=${payload['coin']}');

  for (int i = 0; i < attempts; i++) {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              ...authHeaders,
              "Cache-Control": "no-cache, no-store, must-revalidate",
              "Pragma": "no-cache",
              "Expires": "0",
            },
            body: body,
          )
          // Grok can take up to ~90s — 15s timeout caused false "Cannot connect" errors.
          .timeout(const Duration(seconds: 90));
      debugPrint('[HTTP POST] $uri → ${response.statusCode} (attempt ${i + 1}/$attempts)');
      if (response.statusCode >= 500 && i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        continue;
      }
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] $uri attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception("Unknown analyze request error");
}

Future<http.Response> _postChatWithRetry({
  required String message,
  required List<Map<String, String>> history,
  required String systemPrompt,
  int attempts = 3,
}) async {
  Object? lastError;
  final uri = Uri.parse('$kBackendBaseUrl/chat');
  final payload = {
    'message': message,
    'history': history,
    'system_prompt': systemPrompt,
    'request_ts': DateTime.now().millisecondsSinceEpoch,
  };
  final body = jsonEncode(payload);
  debugPrint('[HTTP POST] $uri chat message length=${message.length}');

  for (int i = 0; i < attempts; i++) {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 90));
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] $uri attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception('Unknown chat request error');
}

// Charts Screen (Full Interactive)
class ChartsScreen extends StatefulWidget {
  final String initialSymbol;
  final bool isTabActive;

  const ChartsScreen({
    super.key,
    required this.initialSymbol,
    this.isTabActive = true,
  });

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  static const _watchlistSymbols = ['BTC', 'ETH', 'SOL', 'BNB'];
  late String selectedSymbol;
  WebViewController? _webController;

  @override
  void initState() {
    super.initState();
    selectedSymbol = CoinAccessPolicy.normalizeCoinSymbol(widget.initialSymbol) ??
        widget.initialSymbol.trim().toUpperCase();
    if (widget.isTabActive) _initWebViewIfNeeded();
  }

  @override
  void didUpdateWidget(ChartsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isTabActive && !oldWidget.isTabActive) {
      _initWebViewIfNeeded();
    }
    if (oldWidget.initialSymbol != widget.initialSymbol) {
      selectedSymbol = CoinAccessPolicy.normalizeCoinSymbol(widget.initialSymbol) ??
          widget.initialSymbol.trim().toUpperCase();
      if (_webController != null) {
        _webController!.loadHtmlString(_getTradingViewHTML(selectedSymbol));
        debugPrint('[Charts] Updated symbol from watchlist: $selectedSymbol');
      }
    }
  }

  void _initWebViewIfNeeded() {
    if (_webController != null) return;
    _webController = createTradingViewController(selectedSymbol);
    debugPrint('[Charts] Loaded symbol: $selectedSymbol → ${CoinAccessPolicy.resolveTradingViewSymbol(selectedSymbol)}');
  }

  void _onSymbolChanged(String? value) {
    if (value == null) return;
    setState(() {
      selectedSymbol = CoinAccessPolicy.normalizeCoinSymbol(value) ?? value.toUpperCase();
      _initWebViewIfNeeded();
      _webController!.loadHtmlString(_getTradingViewHTML(selectedSymbol));
      debugPrint('[Charts] Dropdown changed to: $selectedSymbol');
    });
  }

  void _openSymbolSearch() {
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => WatchlistCoinSearchScreen(
          existingWatchlist: [selectedSymbol, ..._watchlistSymbols],
          onCoinSelected: (coin) {
            _onSymbolChanged(coin);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Charts"),
        actions: [
          IconButton(
            tooltip: 'Search symbol',
            icon: const Icon(Icons.search),
            onPressed: _openSymbolSearch,
          ),
          DropdownButton<String>(
            value: selectedSymbol,
            dropdownColor: Colors.black87,
            items: [
              if (!_watchlistSymbols.contains(selectedSymbol))
                DropdownMenuItem(value: selectedSymbol, child: Text(selectedSymbol)),
              ..._watchlistSymbols.map((s) => DropdownMenuItem(value: s, child: Text(s))),
            ],
            onChanged: _onSymbolChanged,
          ),
        ],
      ),
      body: widget.isTabActive && _webController != null
          ? Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: WebViewWidget(
                      controller: _webController!,
                      gestureRecognizers: kTradingViewGestureRecognizers,
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _FullScreenChartButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (_) => FullScreenChartScreen(symbol: selectedSymbol),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          : const ColoredBox(color: Color(0xFF0F0F0F)),
    );
  }

  String _getTradingViewHTML(String symbol) {
    final sym = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
    return buildTradingViewHTML(sym, tvSymbol: CoinAccessPolicy.resolveTradingViewSymbol(sym));
  }
}

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

  String get directionSymbol => isAbove ? '↑' : '↓';

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

/// In-memory alert store — list updates instantly; persists via [AlertsRepository].
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

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _bannerMessage;
  late final AnimationController _bannerController;

  List<AlertRecord> get _alerts => AlertsStore.instance.alerts;

  static const _coinColors = {
    'BTC': Color(0xFFF7931A),
    'ETH': Color(0xFF627EEA),
    'SOL': Color(0xFF14F195),
    'XRP': Color(0xFF00BFFF),
    'BNB': Color(0xFFFFB74D),
  };

  @override
  void initState() {
    super.initState();
    _bannerController = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
    _loadAlerts();
  }

  @override
  void dispose() {
    _bannerController.dispose();
    super.dispose();
  }

  Future<void> _loadAlerts() async {
    await AlertsStore.instance.ensureLoaded();
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteAlert(String id) async {
    setState(() => AlertsStore.instance.remove(id));
  }

  void _showAdvancedAlertUpgradePrompt() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Premium Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
        content: Text(
          'Advanced custom alerts (RSI, MACD, Volume, VWAP Cross, News) are available on Premium and Expert plans. '
          'Free plan includes basic Price alerts only.',
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

  Future<void> _openEditor({AlertRecord? existing}) async {
    await SubscriptionPlanStore.load();
    if (existing != null && !SubscriptionPlanStore.canUseAlertType(existing.alertType)) {
      if (!mounted) return;
      _showAdvancedAlertUpgradePrompt();
      return;
    }
    final result = await showModalBottomSheet<AlertRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _AlertEditorSheet(initial: existing),
    );
    if (!mounted || result == null) return;

    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.canUseAlertType(result.alertType)) {
      if (mounted) _showAdvancedAlertUpgradePrompt();
      return;
    }

    setState(() {
      if (existing != null) {
        AlertsStore.instance.update(result);
      } else {
        AlertsStore.instance.add(result);
      }
    });

    _showBanner(
      existing == null
          ? '${result.coin} alert created: ${result.conditionLabel}'
          : '${result.coin} alert updated',
    );
  }

  void _openCreateSheet() => _openEditor();

  void _openEditSheet(AlertRecord alert) => _openEditor(existing: alert);

  Future<void> _simulateTriggerCheck() async {
    final active = _alerts.where((a) => a.status == 'Active').toList();
    if (active.isEmpty) {
      _showBanner('No active alerts to check.');
      return;
    }

    final random = Random();
    final target = active[random.nextInt(active.length)];
    final index = _alerts.indexWhere((a) => a.id == target.id);
    if (index == -1) return;

    setState(() {
      AlertsStore.instance.replaceAt(index, target.copyWith(status: 'Triggered'));
    });
    _showBanner('${target.coin} alert triggered: ${target.conditionLabel}');
  }

  void _showBanner(String message) {
    setState(() => _bannerMessage = message);
    _bannerController.forward(from: 0);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _bannerMessage == message) {
        _bannerController.reverse().then((_) {
          if (mounted) setState(() => _bannerMessage = null);
        });
      }
    });
  }

  int get _activeCount => _alerts.where((a) => a.status == 'Active').length;

  Color _coinColor(String coin) => _coinColors[coin.toUpperCase()] ?? const Color(0xFF00BFFF);

  IconData _typeIcon(String type) {
    switch (type) {
      case 'Price':
        return Icons.attach_money;
      case 'RSI':
        return Icons.speed;
      case 'MACD':
        return Icons.multiline_chart;
      case 'Volume':
        return Icons.bar_chart;
      case 'VWAP Cross':
        return Icons.timeline;
      case 'News':
        return Icons.newspaper;
      default:
        return Icons.notifications;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF0F0F0F),
        title: const Text('Smart Alerts'),
        actions: [
          IconButton(
            tooltip: 'Check alerts',
            onPressed: _simulateTriggerCheck,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00BFFF)),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.35)),
                ),
                child: Text(
                  '$_activeCount Active',
                  style: const TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00BFFF),
        foregroundColor: Colors.black,
        elevation: 6,
        onPressed: _openCreateSheet,
        icon: const Icon(Icons.add_alert_rounded),
        label: const Text('Create New Alert', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF)))
          : Column(
              children: [
                SizeTransition(
                  sizeFactor: CurvedAnimation(parent: _bannerController, curve: Curves.easeOutCubic),
                  alignment: Alignment.topCenter,
                  child: FadeTransition(
                    opacity: CurvedAnimation(parent: _bannerController, curve: Curves.easeOut),
                    child: _bannerMessage == null
                        ? const SizedBox.shrink()
                        : Container(
                            width: double.infinity,
                            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(0xFF00BFFF).withValues(alpha: 0.25),
                                  const Color(0xFF006994).withValues(alpha: 0.35),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.5)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.notifications_active, color: Color(0xFF00BFFF), size: 22),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _bannerMessage!,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    _bannerController.reverse().then((_) {
                                      if (mounted) setState(() => _bannerMessage = null);
                                    });
                                  },
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              const Color(0xFF1A1A1A),
                              const Color(0xFF121212),
                              const Color(0xFF00BFFF).withValues(alpha: 0.08),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00BFFF).withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 28),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Pro Alert Engine',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Price, technicals, and news — never miss a move.',
                                    style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Active Alerts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          Text(
                            '${_alerts.length} total',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_alerts.isEmpty)
                        _AppEmptyState(
                          icon: Icons.notifications_active_outlined,
                          title: 'No alerts yet',
                          subtitle: 'Create price, RSI, MACD, or news alerts to stay ahead of the market.',
                        )
                      else
                        ...List.generate(_alerts.length, (index) {
                          final alert = _alerts[index];
                          return TweenAnimationBuilder<double>(
                            key: ValueKey(alert.id),
                            tween: Tween(begin: 0, end: 1),
                            duration: Duration(milliseconds: 280 + (index * 40).clamp(0, 200)),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, child) => Opacity(
                              opacity: value,
                              child: Transform.translate(
                                offset: Offset(0, (1 - value) * 12),
                                child: child,
                              ),
                            ),
                            child: _AlertCard(
                              alert: alert,
                              coinColor: _coinColor(alert.coin),
                              typeIcon: _typeIcon(alert.alertType),
                              onTap: () => _openEditSheet(alert),
                              onDelete: () => _deleteAlert(alert.id),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlertRecord alert;
  final Color coinColor;
  final IconData typeIcon;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AlertCard({
    required this.alert,
    required this.coinColor,
    required this.typeIcon,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isTriggered = alert.status == 'Triggered';
    final statusColor = isTriggered ? const Color(0xFFFFB74D) : const Color(0xFF00E676);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isTriggered
                  ? const Color(0xFFFFB74D).withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: coinColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(typeIcon, color: coinColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            alert.coin,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            alert.directionSymbol,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: alert.directionColor,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              alert.alertType,
                              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        alert.conditionLabel,
                        style: TextStyle(fontSize: 13, color: Colors.grey[300], height: 1.3),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: statusColor.withValues(alpha: 0.4)),
                            ),
                            child: Text(
                              alert.status,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: statusColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.schedule, size: 12, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(alert.timeframe, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                          const Spacer(),
                          Icon(Icons.edit_outlined, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text('Edit', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Delete alert',
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, color: Colors.red[300], size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AlertEditorSheet extends StatefulWidget {
  final AlertRecord? initial;

  const _AlertEditorSheet({this.initial});

  bool get isEditing => initial != null;

  @override
  State<_AlertEditorSheet> createState() => _AlertEditorSheetState();
}

class _AlertEditorSheetState extends State<_AlertEditorSheet> {
  static const _coins = ['BTC', 'ETH', 'SOL', 'XRP', 'BNB'];
  static const _types = ['Price', 'RSI', 'MACD', 'Volume', 'VWAP Cross', 'News'];
  static const _timeframes = ['5m', '15m', '1h', '4h', '1d'];

  List<String> get _allowedTypes =>
      SubscriptionPlanStore.isFree ? const ['Price'] : _types;

  late String selectedCoin;
  late bool useCustomCoin;
  late String alertType;
  late String condition;
  late String timeframe;
  final TextEditingController _customCoinController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(SubscriptionPlanStore.load());
    final existing = widget.initial;
    if (existing != null) {
      final coinUpper = existing.coin.toUpperCase();
      if (_coins.contains(coinUpper)) {
        selectedCoin = coinUpper;
        useCustomCoin = false;
      } else {
        selectedCoin = 'BTC';
        useCustomCoin = true;
        _customCoinController.text = coinUpper;
      }
      alertType = _allowedTypes.contains(existing.alertType) ? existing.alertType : 'Price';
      condition = existing.condition == 'Below' ? 'Below' : 'Above';
      timeframe = _timeframes.contains(existing.timeframe) ? existing.timeframe : '1h';
      if (existing.value != '0') {
        _valueController.text = existing.value;
      }
    } else {
      selectedCoin = 'BTC';
      useCustomCoin = false;
      alertType = 'Price';
      condition = 'Above';
      timeframe = '1h';
    }
  }

  @override
  void dispose() {
    _customCoinController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  String get _resolvedCoin =>
      (useCustomCoin ? _customCoinController.text : selectedCoin).trim().toUpperCase();

  String _categoryForType(String type) {
    if (type == 'Price') return 'price';
    if (type == 'News') return 'news';
    return 'technical';
  }

  Future<void> _save() async {
    await SubscriptionPlanStore.load();
    final coin = _resolvedCoin;
    if (coin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a coin symbol')),
      );
      return;
    }

    if (!SubscriptionPlanStore.canUseAlertType(alertType)) {
      if (!mounted) return;
      Navigator.pop(context);
      return;
    }

    final resolvedCoin = await resolveCoinForCurrentPlan(context, coin, showDialogs: true);
    if (resolvedCoin == null || !mounted) return;

    if (alertType != 'MACD' && alertType != 'News' && _valueController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a trigger value')),
      );
      return;
    }

    final alert = AlertRecord(
      id: widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      coin: resolvedCoin,
      alertType: alertType,
      condition: condition,
      value: _valueController.text.trim().isEmpty ? '0' : _valueController.text.trim(),
      timeframe: timeframe,
      status: widget.initial?.status ?? 'Active',
      category: _categoryForType(alertType),
    );

    Navigator.pop(context, alert);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final needsValue = alertType != 'MACD' && alertType != 'News';
    final isEditing = widget.isEditing;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomInset + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              isEditing ? 'Edit Alert' : 'Create New Alert',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              isEditing
                  ? 'Update your trigger settings and save changes.'
                  : 'Set precise triggers and get notified instantly.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 22),
            _sheetLabel('Coin'),
            DropdownButtonFormField<String>(
              key: ValueKey('coin-${useCustomCoin ? 'custom' : selectedCoin}'),
              initialValue: useCustomCoin ? 'Custom' : selectedCoin,
              dropdownColor: const Color(0xFF1E1E1E),
              decoration: _inputDecoration(),
              items: [
                ..._coins.map((c) => DropdownMenuItem(value: c, child: Text(c))),
                const DropdownMenuItem(value: 'Custom', child: Text('Custom')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  if (v == 'Custom') {
                    useCustomCoin = true;
                  } else {
                    useCustomCoin = false;
                    selectedCoin = v;
                  }
                });
              },
            ),
            if (useCustomCoin) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _customCoinController,
                textCapitalization: TextCapitalization.characters,
                decoration: _inputDecoration(hint: 'e.g. AVAX'),
              ),
            ],
            const SizedBox(height: 16),
            _sheetLabel('Alert Type'),
            DropdownButtonFormField<String>(
              key: ValueKey('type-$alertType'),
              initialValue: alertType,
              dropdownColor: const Color(0xFF1E1E1E),
              decoration: _inputDecoration(),
              items: _allowedTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => alertType = v ?? 'Price'),
            ),
            const SizedBox(height: 16),
            _sheetLabel('Condition'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Above', label: Text('Above ↑')),
                ButtonSegment(value: 'Below', label: Text('Below ↓')),
              ],
              selected: {condition},
              onSelectionChanged: (s) => setState(() => condition = s.first),
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return const Color(0xFF00BFFF).withValues(alpha: 0.25);
                  }
                  return const Color(0xFF252525);
                }),
              ),
            ),
            if (needsValue) ...[
              const SizedBox(height: 16),
              _sheetLabel('Value'),
              TextField(
                controller: _valueController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: _inputDecoration(
                  hint: alertType == 'Price'
                      ? '76500'
                      : alertType == 'RSI'
                          ? '30'
                          : alertType == 'Volume'
                              ? '25'
                              : 'Enter value',
                ),
              ),
            ],
            const SizedBox(height: 16),
            _sheetLabel('Timeframe'),
            DropdownButtonFormField<String>(
              key: ValueKey('tf-$timeframe'),
              initialValue: timeframe,
              dropdownColor: const Color(0xFF1E1E1E),
              decoration: _inputDecoration(),
              items: _timeframes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => timeframe = v ?? '1h'),
            ),
            if (isEditing) ...[
              const SizedBox(height: 16),
              _sheetLabel('Status'),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Text(
                  widget.initial!.status,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00BFFF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  isEditing ? 'Save Changes' : 'Save Alert',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      );

  InputDecoration _inputDecoration({String? hint}) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFF1E1E1E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00BFFF)),
        ),
      );
}