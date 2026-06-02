/*
- Subscription tiers: Free (BTC/ETH/SOL), Premium (Top 150), Expert (any symbol)
- FCM push notifications + daily 7:30 AM CST local alerts (NotificationService)
- TradingView charts: VWAP + EMA 5/20 + RSI + MACD + Auto Fib; full pinch/pan/zoom
- Watchlist coin search screen (TradingView-style symbol picker)
- UI polish: spacing, empty states, fade-ins, scale-on-tap, premium page transitions
- Dynamic Watchlist with + button (session memory) → Charts navigation
- Bottom nav: Home, Analyze, Trade Setup, Charts, Portfolio (Alerts via Home AppBar bell)
- Expert-plan AI Chat FAB on Home + report screens
- Expert-plan Oracle Citadel: Send trade setups to secure /execute_trade backend
- App logo: splash screen, Home AppBar, Profile header (assets/images/app_logo.png)
- Professional Portfolio screen with mock holdings data
*/
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'services/market_movers_service.dart';
import 'services/notification_service.dart';
import 'services/portfolio_service.dart';
import 'services/user_profile_store.dart';
import 'screens/edit_profile_screen.dart';
import 'screens/profile_screen.dart' show kProfileBackgroundOrbHeight, kProfileBackgroundOrbOpacity;
import 'widgets/ai_chat_entry.dart';
import 'widgets/background_illustration.dart';

part 'screens/quick_analyze_screen.dart';
part 'screens/trade_setup_screen.dart';
part 'screens/trade_performance_screen.dart';
part 'screens/market_movers_screen.dart';
part 'screens/citadel_setup_dialog.dart';

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

/// Placeholder YouTube channel — replace with your channel URL when ready.
const String kYouTubeChannelUrl = 'https://www.youtube.com/@OnChainOracleAI';

/// App branding asset (full logo with icon + wordmark).
const String kAppLogoAsset = 'assets/images/app_logo.png';

Future<void> openYouTubeChannel(BuildContext context) async {
  final uri = Uri.parse(kYouTubeChannelUrl);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open YouTube')),
      );
    }
  }
}

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

/// Embedded chart with expand-to-fullscreen control (Analysis, Trade Setup, etc.).
class TradingViewChartPanel extends StatefulWidget {
  final String symbol;
  final WebViewController controller;
  final double height;
  final bool mountWebView;

  const TradingViewChartPanel({
    super.key,
    required this.symbol,
    required this.controller,
    this.height = 420,
    this.mountWebView = true,
  });

  @override
  State<TradingViewChartPanel> createState() => _TradingViewChartPanelState();
}

class _TradingViewChartPanelState extends State<TradingViewChartPanel> {
  void _openFullScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FullScreenChartScreen(symbol: widget.symbol),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
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
      ),
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

  const FullScreenChartScreen({super.key, required this.symbol});

  @override
  State<FullScreenChartScreen> createState() => _FullScreenChartScreenState();
}

class _FullScreenChartScreenState extends State<FullScreenChartScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = createTradingViewController(widget.symbol);
  }

  @override
  Widget build(BuildContext context) {
    final sym = widget.symbol.trim().toUpperCase();
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('$sym/USDT'),
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
You are On-Chain Oracle AI — an elite crypto desk analyst writing premium, high-conviction reports for active traders. Voice: decisive, institutional, trader-native. Write like a senior PM briefing a desk — not a generic chatbot.

═══════════════════════════════════════
NON-NEGOTIABLE RULES (never violate)
═══════════════════════════════════════

1. RISK:REWARD (HARD FLOOR)
   • Every actionable level set MUST achieve minimum 2.1:1 R:R on TP1 vs stop distance.
   • TARGET 2.3:1 or better on TP1 whenever structure allows — do not settle for the bare minimum if a cleaner level exists.
   • NEVER publish setups below 2:1 under any circumstance.
   • In TRADE LEVELS, state "Risk:Reward: X.X:1" and show explicit math:
     Reward = |TP1 − Entry|, Risk = |Entry − SL|, R:R = Reward ÷ Risk.
   • If you cannot construct a valid ≥2.1:1 TP1 setup, say so clearly and omit TRADE LEVELS rather than forcing a bad R:R.

2. DISCLAIMER (EXACT — FINAL LINE ONLY)
   End EVERY report with this EXACT line and NOTHING after it (no punctuation, questions, or extra text):
$kReportDisclaimer

3. NO TRAILING CHATBOT BEHAVIOR
   • No questions, upsells, or follow-ups ("Would you like...", "Let me know if...", "I can also...").
   • No hedging filler ("it might perhaps...", "could potentially maybe...").
   • End cleanly: last content section → disclaimer. Period.

4. CONVICTION & TONE
   • State bias boldly with a confidence % (e.g. "Confidence: 72%").
   • Use trader language: "edge", "invalidation", "acceptance/rejection", "premium/discount", "liquidity sweep", "structure break".
   • Be specific with prices — round appropriately but stay precise to the data provided.
   • Separate WHAT the market is doing from WHAT to do about it.

═══════════════════════════════════════
ANALYTICAL FRAMEWORK (apply every report)
═══════════════════════════════════════

MULTI-TIMEFRAME (MTF) — synthesize, do not list in isolation:
• HTF (Daily / 4h): dominant trend, major swing structure, key macro S/R, trend exhaustion or continuation.
• MTF (1h / requested timeframe): bias confirmation, momentum shift, range vs trend state.
• LTF (15m–5m): entry timing context, micro structure, stop placement logic.
• Conclude with MTF alignment: aligned (high conviction) vs conflicted (lower conviction / wait).

VWAP STACK — mandatory context (reference ALL in narrative even if chart shows subset):
• Session VWAP (daily anchor) — bull/bear line; acceptance above = bullish control, rejection = bearish.
• Previous Session VWAP — mean-reversion magnet; note if price is gravitating toward or repelling from it.
• Weekly VWAP — intermediate trend filter; breaks and retests here define swing bias.
• Monthly VWAP — macro fair value; premium above / discount below shapes bigger-picture edge.
• Call out CONFLUENCE when 2+ VWAPs cluster within ~0.3–0.8% — these are high-probability reaction zones.

INDICATORS & STRUCTURE:
• EMA 5 / EMA 20: momentum vs trend; crossovers, compression, dynamic S/R.
• RSI: regime (>50 bull / <50 bear), divergences, overbought/oversold only WITH structure — never alone.
• MACD: momentum confirmation, histogram expansion/contraction, signal-line crosses aligned with bias.
• Volume: participation on breaks vs fakeouts; note if move lacks volume conviction.
• Market structure: HH/HL vs LH/LL, BOS/CHoCH, range highs/lows, obvious liquidity pools.

CONFLUENCE SCORING (state explicitly in Confluence Summary):
• Grade edge: STRONG / MODERATE / WEAK based on how many independent factors align (VWAP + EMA + RSI/MACD + structure + MTF).
• One punchy sentence: "Edge is [long/short/neutral] because [top 2–3 confluent reasons]."

═══════════════════════════════════════
REPORT FORMAT (use these sections)
═══════════════════════════════════════

**Asset**: [COIN] | \$[PRICE] | [24h %]

**Overall Bias**: [Strongly Bullish / Mildly Bullish / Neutral / Mildly Bearish / Strongly Bearish] (Confidence: XX%)

**Key Drivers**:
• Multi-Timeframe Read — HTF / MTF / LTF synthesis in 2–4 bullets
• VWAP Stack Analysis — daily, prev session, weekly, monthly positioning
• Momentum & Structure — EMA 5/20, RSI, MACD, volume, market structure
• Liquidity & Sentiment — funding/OI context if relevant; where stops likely sit

**Confluence Summary**: One decisive, high-conviction sentence grading the edge.

**If I Were to Trade Today...**: Actionable trader commentary — direction, trigger, invalidation, what would change your mind.

**Risks & Watchlist**: 2–4 sharp bullets — what kills the thesis, key upcoming levels/events.

**TRADE LEVELS** (when applicable — see mode rules):
Entry at \$XXXXX, TP1 at \$XXXXX, TP2 at \$XXXXX, SL at \$XXXXX (Risk:Reward: X.X:1)
Show R:R math inline immediately after this line.
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

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    currentPlan = prefs.getString(_planKey) ?? 'Free';
  }

  static Future<void> setPlan(String plan) async {
    currentPlan = plan;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_planKey, plan);
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

  static String userId = 'demo_user';
  static String apiKey = '';
  static double defaultRiskPercent = 1.0;

  static bool get isConfigured => userId.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    userId = prefs.getString(_userIdKey) ?? 'demo_user';
    apiKey = prefs.getString(_apiKeyKey) ?? '';
    defaultRiskPercent = prefs.getDouble(_riskPercentKey) ?? 1.0;
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
  }
}

class OracleCitadelException implements Exception {
  final String userMessage;
  final String? errorCode;

  const OracleCitadelException(this.userMessage, {this.errorCode});

  @override
  String toString() => userMessage;
}

abstract final class OracleCitadelService {
  static Map<String, String> _authHeaders() => {
        'Content-Type': 'application/json',
        'X-API-Key': OracleCitadelStore.apiKey,
      };

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
          headers: _authHeaders(),
          body: jsonEncode({
            'user_id': userId,
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

  static Future<Map<String, dynamic>> executeTrade({
    required String userId,
    required String coin,
    required String direction,
    required double entryPrice,
    required double stopLoss,
    required double tp1,
    required double tp2,
    required double riskPercent,
  }) async {
    final uri = Uri.parse('$kCitadelBaseUrl/execute_trade');
    final payload = {
      'user_id': userId,
      'coin': coin.toUpperCase(),
      'direction': direction,
      'entry_price': entryPrice,
      'stop_loss': stopLoss,
      'tp1': tp1,
      'tp2': tp2,
      'risk_percent': riskPercent,
    };

    debugPrint('[Citadel] POST $uri coin=$coin direction=$direction');

    final response = await http
        .post(uri, headers: _authHeaders(), body: jsonEncode(payload))
        .timeout(const Duration(seconds: 90));

    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}

    if (response.statusCode == 200) return body;

    final friendly = _parseUserMessage(response) ??
        body['user_message']?.toString() ??
        'Trade could not be sent (${response.statusCode}).';
    throw OracleCitadelException(
      friendly,
      errorCode: body['error_code']?.toString(),
    );
  }
}

double? extractTradeLevel(String input, List<String> keys) {
  for (final key in keys) {
    final escapedKey = RegExp.escape(key);
    final regex = RegExp(
      '$escapedKey\\s*[:=-]?\\s*\\\$?\\s*([0-9]+(?:[.,][0-9]+)?)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(input);
    if (match != null) {
      final value = match.group(1)?.replaceAll(',', '').trim();
      if (value != null && value.isNotEmpty) {
        return double.tryParse(value);
      }
    }
  }
  return null;
}

String citadelDirectionFromSetup(String selectedDirection, double entry, double sl) {
  final lower = selectedDirection.toLowerCase();
  if (lower.contains('long')) return 'long';
  if (lower.contains('short')) return 'short';
  return sl < entry ? 'long' : 'short';
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
  bool _sending = false;
  bool _isExpert = false;

  @override
  void initState() {
    super.initState();
    _loadTier();
  }

  Future<void> _loadTier() async {
    await SubscriptionPlanStore.load();
    if (mounted) setState(() => _isExpert = SubscriptionPlanStore.isExpert);
  }

  Future<void> _onPressed() async {
    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.isExpert) {
      if (mounted) showCitadelUpgradePrompt(context);
      return;
    }

    await OracleCitadelStore.load();
    if (!OracleCitadelStore.isConfigured) {
      if (mounted) await showCitadelSetupDialog(context);
      await OracleCitadelStore.load();
      if (!OracleCitadelStore.isConfigured) return;
    }

    final entry = widget.entry ??
        extractTradeLevel(widget.reportText, ['entry', 'entry price']);
    final sl = widget.stopLoss ??
        extractTradeLevel(widget.reportText, ['sl', 'stop loss', 'stop-loss']);
    final tp1 = widget.tp1 ??
        extractTradeLevel(widget.reportText, ['tp1', 'take profit 1', 'target 1']);
    final tp2 = widget.tp2 ??
        extractTradeLevel(widget.reportText, ['tp2', 'take profit 2', 'target 2']);

    if (entry == null || sl == null || tp1 == null || tp2 == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not find Entry, SL, TP1, and TP2 in this report. '
              'Generate a complete trade setup first.',
            ),
          ),
        );
      }
      return;
    }

    setState(() => _sending = true);

    try {
      final direction = citadelDirectionFromSetup(widget.directionLabel, entry, sl);
      final result = await OracleCitadelService.executeTrade(
        userId: OracleCitadelStore.userId,
        coin: widget.coin,
        direction: direction,
        entryPrice: entry,
        stopLoss: sl,
        tp1: tp1,
        tp2: tp2,
        riskPercent: OracleCitadelStore.defaultRiskPercent,
      );

      final userMessage = result['user_message']?.toString() ??
          result['message']?.toString() ??
          'Trade sent to Oracle Citadel successfully.';
      final status = result['status']?.toString() ?? '';

      if (mounted) {
        final isSuccess = status == 'success';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userMessage),
            backgroundColor: isSuccess ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } on OracleCitadelException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.userMessage),
            backgroundColor: const Color(0xFFB71C1C),
            duration: const Duration(seconds: 5),
            action: e.errorCode == 'credentials_missing'
                ? SnackBarAction(
                    label: 'Setup',
                    textColor: Colors.white,
                    onPressed: () => showCitadelSetupDialog(context),
                  )
                : null,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot reach Oracle Citadel. Check your connection and try again.'),
            backgroundColor: Color(0xFFB71C1C),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _sending ? null : _onPressed,
        icon: _sending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
              )
            : const Icon(Icons.shield_outlined, size: 22),
        label: Text(
          _sending ? 'Sending to Citadel…' : 'Send to Oracle Citadel',
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

/// TradingView-style symbol search for adding coins to the Home watchlist.
class WatchlistCoinSearchScreen extends StatefulWidget {
  final List<String> existingWatchlist;
  final ValueChanged<String> onCoinSelected;

  const WatchlistCoinSearchScreen({
    super.key,
    required this.existingWatchlist,
    required this.onCoinSelected,
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
    if (widget.existingWatchlist.contains(coin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$coin is already in your watchlist')),
      );
      return;
    }
    widget.onCoinSelected(coin);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final customSymbol = _customExpertSymbol;
    final query = _searchController.text.trim();

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: const Text('Add Symbol'),
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
                    onPressed: inList ? null : () => _selectCoin(symbol),
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
                            onTap: inList ? null : () => _selectCoin(symbol),
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

Future<void> openAiChat(BuildContext context) async {
  await SubscriptionPlanStore.load();
  if (!SubscriptionPlanStore.hasExpertChatAccess) {
    if (context.mounted) _showChatUpgradePrompt(context);
    return;
  }
  if (context.mounted) {
    Navigator.push(context, _premiumPageRoute((_) => const ChatScreen()));
  }
}

void _showChatUpgradePrompt(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Expert Plan Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Oracle AI Chat is available on the Expert (Top Tier) plan. '
        'Upgrade to unlock real-time AI assistance for your analyses and trade setups.',
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

  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const MainScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 450),
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

class _MainScreenState extends State<MainScreen> {
  static const int _tabHome = 0;
  static const int _tabCharts = 3;

  int _selectedIndex = _tabHome;
  String _chartsSymbol = 'BTC';
  final List<Map<String, dynamic>> history = [];
  final List<Map<String, dynamic>> trades = [];
  DateTime? _lastTradeRefreshAt;

  /// Default watchlist coins; user-added coins append for the session.
  final List<String> _watchlist = ['BTC', 'ETH', 'SOL', 'BNB'];
  static const Set<String> _defaultWatchlist = {'BTC', 'ETH', 'SOL', 'BNB'};

  void addToWatchlist(String symbol) {
    final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol);
    if (normalized == null || _watchlist.contains(normalized)) return;
    setState(() => _watchlist.add(normalized));
    debugPrint('[Watchlist] Added coin: $normalized');
  }

  /// FIX: Pass tapped watchlist coin to ChartsScreen, not just switch tabs.
  void goToCharts(String symbol) {
    final normalized = CoinAccessPolicy.normalizeCoinSymbol(symbol) ?? symbol.trim().toUpperCase();
    debugPrint('[Navigation] Watchlist → Charts: $normalized');
    setState(() {
      _chartsSymbol = normalized;
      _selectedIndex = _tabCharts;
    });
  }

  @override
  void initState() {
    super.initState();
    _refreshOpenTrades();
    SubscriptionPlanStore.load();
    OracleCitadelStore.load();
    UserProfileStore.load();
  }

  void addToHistory(String coin, String report) {
    setState(() {
      history.insert(0, {
        "id": DateTime.now().millisecondsSinceEpoch,
        "coin": coin,
        "report": report,
        "time": "${DateTime.now().month}/${DateTime.now().day} ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}",
        "source": "analysis",
      });
      if (history.length > 20) history.removeLast();
    });
  }

  void addTradeSetupResult(Map<String, dynamic> payload) {
    final now = DateTime.now();
    final tradeId = now.microsecondsSinceEpoch;
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
    };

    setState(() {
      trades.insert(0, trade);
      history.insert(0, {
        "id": now.millisecondsSinceEpoch,
        "coin": payload["coin"],
        "report": payload["report"],
        "time": "${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}",
        "source": "trade_setup",
        "tradeId": tradeId,
        "tradeStatus": "Open",
      });
      if (history.length > 20) history.removeLast();
    });
  }

  void deleteFromHistory(int id) {
    setState(() {
      history.removeWhere((item) => item["id"] == id);
    });
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
    if (mounted) setState(() {});
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
      final trade = trades.where((t) => t["id"] == tradeId).cast<Map<String, dynamic>?>().firstWhere(
            (t) => t != null,
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
            onCoinTap: goToCharts,
            watchlist: _watchlist,
            onAddWatchlistCoin: addToWatchlist,
            history: history,
            trades: trades,
            winRateText: winRateText,
            onViewReport: (item) {
              Navigator.push(context, _premiumPageRoute((_) => AnalysisReportScreen.fromHistory(item)));
            },
            onDelete: deleteFromHistory,
          ),
          QuickAnalyzeScreen(addToHistory: addToHistory),
          TradeSetupScreen(
            coin: 'BTC',
            onTradeSetupGenerated: addTradeSetupResult,
          ),
          ChartsScreen(
            key: ValueKey(_chartsSymbol),
            initialSymbol: _chartsSymbol,
            isTabActive: _selectedIndex == _tabCharts,
          ),
          PortfolioScreen(
            watchlist: _watchlist,
            defaultWatchlist: _defaultWatchlist,
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
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.insert_chart_outlined), activeIcon: Icon(Icons.insert_chart), label: 'Analyze'),
          BottomNavigationBarItem(icon: Icon(Icons.gps_fixed), activeIcon: Icon(Icons.gps_fixed), label: 'Trade Setup'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), activeIcon: Icon(Icons.bar_chart), label: 'Charts'),
          BottomNavigationBarItem(icon: Icon(Icons.pie_chart_outline), activeIcon: Icon(Icons.pie_chart), label: 'Portfolio'),
        ],
      ),
    );
  }
}

// ==================== HOME SCREEN ====================
//
// Full-page vertical scroll: SingleChildScrollView → Column (no horizontal scroll).
// Each section shows exactly 4 fixed-height rows in the viewport, then more rows below
// on the same page scroll (items 5+ appear when the user scrolls down).

/// Section block inside Home's main Column (watchlist / analyses / news).
class _HomeVerticalSection extends StatelessWidget {
  final Widget header;
  final List<Widget> itemTiles;
  final double listRowExtent;
  final bool showScrollHint;

  const _HomeVerticalSection({
    required this.header,
    required this.itemTiles,
    required this.listRowExtent,
    this.showScrollHint = true,
  });

  /// Exactly four rows visible per section before the user scrolls the page.
  static const int defaultVisibleItemCount = 4;

  List<Widget> _fixedHeightTiles(List<Widget> tiles) {
    return tiles
        .map(
          (tile) => SizedBox(
            height: listRowExtent,
            child: tile,
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final total = itemTiles.length;
    final firstBlock = itemTiles.take(defaultVisibleItemCount).toList();
    final overflowBlock = total > defaultVisibleItemCount
        ? itemTiles.skip(defaultVisibleItemCount).toList()
        : const <Widget>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        if (showScrollHint && total > defaultVisibleItemCount)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Showing $defaultVisibleItemCount of $total — scroll down for more',
              style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.3),
            ),
          ),
        const SizedBox(height: 10),
        // Default viewport: first 4 items (fixed row height for consistent layout).
        ..._fixedHeightTiles(firstBlock),
        if (overflowBlock.isNotEmpty) ...[
          const SizedBox(height: 6),
          ..._fixedHeightTiles(overflowBlock),
        ],
        const SizedBox(height: _AppSpacing.section),
      ],
    );
  }
}

class HomeScreen extends StatefulWidget {
  final Function(String) onCoinTap;
  final List<String> watchlist;
  final Function(String) onAddWatchlistCoin;
  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> trades;
  final String winRateText;
  final Function(Map<String, dynamic>) onViewReport;
  final Function(int) onDelete;

  const HomeScreen({
    super.key,
    required this.onCoinTap,
    required this.watchlist,
    required this.onAddWatchlistCoin,
    required this.history,
    required this.trades,
    required this.winRateText,
    required this.onViewReport,
    required this.onDelete,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _chatFabHidden = false;

  @override
  void initState() {
    super.initState();
    _loadChatFabPreference();
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

  void _openWatchlistCoinSearch(BuildContext context) {
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => WatchlistCoinSearchScreen(
          existingWatchlist: widget.watchlist,
          onCoinSelected: widget.onAddWatchlistCoin,
        ),
      ),
    );
  }

  Widget _winRateBanner(BuildContext context) {
    return _FadeIn(
      child: _ScaleTap(
        onTap: () => Navigator.push(
          context,
          _premiumPageRoute(
            (_) => TradePerformanceScreen(
              trades: List<Map<String, dynamic>>.from(widget.trades),
              history: widget.history,
              onViewReport: widget.onViewReport,
            ),
          ),
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
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

  List<Widget> _watchlistTiles() {
    return List.generate(widget.watchlist.length, (index) {
      final symbol = widget.watchlist[index];
      return TweenAnimationBuilder<double>(
        key: ValueKey(symbol),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 280 + (index * 35).clamp(0, 180)),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 10), child: child),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _ScaleTap(
            onTap: () => widget.onCoinTap(symbol),
            child: Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                  child: Text(
                    symbol.substring(0, 1),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF00BFFF)),
                  ),
                ),
                title: Text(symbol, style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Icon(Icons.chevron_right, color: Colors.grey[600]),
              ),
            ),
          ),
        ),
      );
    });
  }

  List<Widget> _recentAnalysisTiles(BuildContext context) {
    if (widget.history.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _AppEmptyState(
            icon: Icons.insights_outlined,
            title: 'No analyses yet',
            subtitle: 'Tap the analytics button to run your first market analysis.',
          ),
        ),
      ];
    }
    return List.generate(widget.history.length, (index) {
      final item = widget.history[index];
      final isTradeSetup = item["source"] == "trade_setup";
      return TweenAnimationBuilder<double>(
        key: ValueKey(item['id']),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 260 + (index * 40).clamp(0, 200)),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 10), child: child),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              title: Text(
                isTradeSetup ? "${item['coin']} Trade Setup" : "${item['coin']} Analysis",
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  isTradeSetup
                      ? "${item['time']} • ${item['tradeStatus'] ?? "Open"}"
                      : item['time'],
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _HistoryChipButton(
                    label: 'Review',
                    backgroundColor: const Color(0xFF455A64),
                    foregroundColor: Colors.white,
                    onPressed: () => Navigator.push(
                      context,
                      _premiumPageRoute(
                        (_) => ReviewReportScreen(historyItem: item),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _HistoryChipButton(
                    label: 'Open',
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black87,
                    onPressed: () => widget.onViewReport(item),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: Colors.red[400]),
                    onPressed: () => widget.onDelete(item['id']),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AppLogo(height: 38),
        titleSpacing: 12,
        actions: [
          IconButton(
            tooltip: 'Market Movers',
            icon: const Icon(Icons.local_fire_department, color: Color(0xFF00BFFF)),
            onPressed: () => Navigator.push(
              context,
              _premiumPageRoute((_) => const MarketMoversScreen()),
            ),
          ),
          IconButton(
            tooltip: 'YouTube',
            icon: const Icon(Icons.play_circle_outline, color: Color(0xFFFF5252)),
            onPressed: () => openYouTubeChannel(context),
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
                onPressed: () => openAiChat(context),
                child: const Icon(kOracleAiChatIcon),
              ),
            ),
      // Full-page vertical scroll; each section shows 4 fixed-height rows, then more below.
      body: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        clipBehavior: Clip.none,
        padding: EdgeInsets.fromLTRB(
          _AppSpacing.screen,
          12,
          _AppSpacing.screen,
          88 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _winRateBanner(context),
            const SizedBox(height: 20),
            _HomeVerticalSection(
              header: _FadeIn(
                delay: const Duration(milliseconds: 60),
                child: _SectionHeader(
                  title: "Watchlist",
                  trailing: _ScaleTap(
                    onTap: () => _openWatchlistCoinSearch(context),
                    child: Material(
                      color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.add, color: Color(0xFF00BFFF), size: 22),
                      ),
                    ),
                  ),
                ),
              ),
              listRowExtent: 72,
              itemTiles: _watchlistTiles(),
            ),
            _HomeVerticalSection(
              header: _FadeIn(
                delay: const Duration(milliseconds: 100),
                child: const _SectionHeader(title: "Recent Analyses"),
              ),
              listRowExtent: 96,
              itemTiles: _recentAnalysisTiles(context),
            ),
            _FadeIn(
              delay: const Duration(milliseconds: 140),
              child: Row(
                children: [
                  const Text("Latest Market News", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                        Text("Live", style: TextStyle(fontSize: 11, color: Colors.greenAccent, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const _MarketNewsFeed(
              nestedInParentScroll: true,
              maxVisibleInViewport: _HomeVerticalSection.defaultVisibleItemCount,
              listRowExtent: 108,
            ),
            const SizedBox(height: _AppSpacing.section),
          ],
        ),
      ),
    );
  }
}

/// Compact rounded action chip used on Recent Analyses / Trades rows.
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

class _MarketNewsFeed extends StatefulWidget {
  /// When true, cards stack in Home's SingleChildScrollView (no nested vertical scroll).
  final bool nestedInParentScroll;
  final int maxVisibleInViewport;
  final double listRowExtent;

  const _MarketNewsFeed({
    this.nestedInParentScroll = false,
    this.maxVisibleInViewport = 4,
    this.listRowExtent = 108,
  });

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
      final visibleCount = widget.maxVisibleInViewport;
      final firstCount = total < visibleCount ? total : visibleCount;
      final overflowCount = total > visibleCount ? total - visibleCount : 0;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (total > visibleCount)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Showing $visibleCount of $total — scroll down for more',
                style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.3),
              ),
            ),
          for (int i = 0; i < firstCount; i++)
            SizedBox(
              height: widget.listRowExtent,
              child: _newsItemBuilder(context, i),
            ),
          if (overflowCount > 0) const SizedBox(height: 6),
          for (int i = visibleCount; i < total; i++)
            SizedBox(
              height: widget.listRowExtent,
              child: _newsItemBuilder(context, i),
            ),
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
                    subtitle: 'On-Chain Oracle AI v1.0.0',
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
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Profile Details'),
          _AccountField(label: 'Display Name', value: UserProfileStore.displayName),
          _AccountField(label: 'Email', value: UserProfileStore.email),
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
              'Daily analysis on BTC, ETH, SOL only',
              'Basic charts',
              'Limited trade setups',
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
              'All timeframes',
              'Unlimited Trade Setups',
              'AI Chat (limited)',
              'Push Notifications',
              'Full Portfolio Tracking',
              'Export reports',
            ],
            isCurrent: _currentPlan == 'Premium',
            badge: 'Most Popular',
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
              'Analyze any coin (unlimited symbols)',
              'Unlimited Oracle Trader AI Chat',
              'Full On-Chain Data',
              'Advanced Custom Alerts',
              'Automated Trading via Oracle Citadel',
              'Priority Support',
              'Detailed Win Rate Analytics',
            ],
            isCurrent: _currentPlan == 'Expert',
            badge: 'Top Tier',
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

  static const _appVersion = '1.0.0';
  static const _buildNumber = '1';

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
                    child: const Icon(Icons.auto_graph, size: 42, color: Color(0xFF00BFFF)),
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

    if (storedReport.trim().isEmpty) {
      setState(() {
        errorMessage = "No stored report found for this item.";
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

  const TradeSetupResultScreen({
    super.key,
    required this.coin,
    required this.timeframe,
    required this.direction,
    required this.onTradeSetupGenerated,
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
    _fetchTradeSetup();
  }

  void _ensureChartController() {
    _chartController ??= createTradingViewController(resolvedCoin);
  }

  Future<void> _fetchTradeSetup() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final response = await _postAnalyzeWithRetry(
        payload: {
          "coin": resolvedCoin,
          "mode": "tradesetup",
          "timeframe": widget.timeframe,
          "direction": widget.direction,
          "report_style": "professional",
          "system_prompt": grokSystemPrompt(mode: "tradesetup"),
          "refresh_price": true,
          "request_ts": DateTime.now().millisecondsSinceEpoch,
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          report = data['report'] ?? "No report";
          loading = false;
          _ensureChartController();
        });
        _saveTradeSetupIfNeeded();
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

  void _saveTradeSetupIfNeeded() {
    if (_saved) return;
    _saved = true;
    _entry = extractTradeLevel(report, ["entry", "entry price"]);
    _tp1 = extractTradeLevel(report, ["tp1", "take profit 1", "target 1"]);
    _tp2 = extractTradeLevel(report, ["tp2", "take profit 2", "target 2"]);
    _sl = extractTradeLevel(report, ["sl", "stop loss", "stop-loss"]);
    widget.onTradeSetupGenerated({
      "coin": resolvedCoin,
      "report": report,
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
  debugPrint('[HTTP POST] $uri mode=${payload['mode']} coin=${payload['coin']}');

  for (int i = 0; i < attempts; i++) {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              "Content-Type": "application/json",
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

// Portfolio screen — live Binance quotes + persisted holdings
class PortfolioScreen extends StatefulWidget {
  final List<String> watchlist;
  final Set<String> defaultWatchlist;

  const PortfolioScreen({
    super.key,
    required this.watchlist,
    required this.defaultWatchlist,
  });

  @override
  State<PortfolioScreen> createState() => _PortfolioScreenState();
}

class _PortfolioScreenState extends State<PortfolioScreen> {
  PortfolioSnapshot? _snapshot;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPortfolio();
  }

  Future<void> _loadPortfolio() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await PortfolioService.fetchSnapshot(
        watchlist: widget.watchlist,
        defaultWatchlist: widget.defaultWatchlist,
      );
      if (mounted) {
        setState(() {
          _snapshot = snap;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not refresh portfolio';
          _loading = false;
        });
      }
    }
  }

  String _formatUsd(double value) {
    if (value >= 1000000) return '\$${(value / 1000000).toStringAsFixed(2)}M';
    if (value >= 1000) {
      return '\$${value.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';
    }
    return '\$${value.toStringAsFixed(2)}';
  }

  String _formatPortfolioTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snapshot;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text('Portfolio'),
        backgroundColor: const Color(0xFF0F0F0F),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadPortfolio,
          ),
        ],
      ),
      body: AppScreenBody(
        includeBottomNav: true,
        child: _loading && snap == null
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF)))
            : RefreshIndicator(
                color: const Color(0xFF00BFFF),
                onRefresh: _loadPortfolio,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: EdgeInsets.zero,
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF5252), fontSize: 13)),
                      const SizedBox(height: 12),
                    ],
                    if (snap != null) ...[
                      _FadeIn(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(22),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                const Color(0xFF1A1A1A),
                                const Color(0xFF00BFFF).withValues(alpha: 0.1),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Total Portfolio Value',
                                    style: TextStyle(fontSize: 13, color: Colors.grey[500], letterSpacing: 0.2),
                                  ),
                                  const Spacer(),
                                  Text(
                                    snap.usedLivePrices ? 'Live · Binance' : 'Estimated',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: snap.usedLivePrices
                                          ? const Color(0xFF00BFFF)
                                          : Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _formatUsd(snap.totalValueUsd),
                                style: const TextStyle(
                                  fontSize: 34,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Icon(
                                    snap.change24hPct >= 0 ? Icons.trending_up : Icons.trending_down,
                                    size: 18,
                                    color: snap.change24hPct >= 0
                                        ? const Color(0xFF00E676)
                                        : const Color(0xFFFF5252),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${snap.change24hPct >= 0 ? '+' : ''}${snap.change24hPct.toStringAsFixed(2)}% (24h)',
                                    style: TextStyle(
                                      color: snap.change24hPct >= 0
                                          ? const Color(0xFF00E676)
                                          : const Color(0xFFFF5252),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Text(
                                    '${snap.change24hUsd >= 0 ? '+' : ''}${_formatUsd(snap.change24hUsd.abs())}',
                                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Updated ${_formatPortfolioTime(snap.fetchedAt)}',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: _AppSpacing.section),
                      _FadeIn(
                        delay: const Duration(milliseconds: 80),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Holdings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            Text(
                              '${snap.holdings.length} assets',
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: _AppSpacing.item),
                      ...List.generate(snap.holdings.length, (index) {
                        final h = snap.holdings[index];
                        return TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: Duration(milliseconds: 300 + (index * 45).clamp(0, 220)),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) => Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, (1 - value) * 10),
                              child: child,
                            ),
                          ),
                          child: _PortfolioHoldingCard(
                            holding: h,
                            formatUsd: _formatUsd,
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _PortfolioHoldingCard extends StatelessWidget {
  final PortfolioHolding holding;
  final String Function(double) formatUsd;

  const _PortfolioHoldingCard({required this.holding, required this.formatUsd});

  static Color _accentFor(String symbol) {
    switch (symbol) {
      case 'BTC':
        return const Color(0xFFF7931A);
      case 'ETH':
        return const Color(0xFF627EEA);
      case 'SOL':
        return const Color(0xFF14F195);
      default:
        return const Color(0xFF00BFFF);
    }
  }

  String _formatPrice(double price) {
    if (price >= 1000) return '\$${price.toStringAsFixed(0)}';
    if (price >= 1) return '\$${price.toStringAsFixed(2)}';
    return '\$${price.toStringAsFixed(4)}';
  }

  @override
  Widget build(BuildContext context) {
    final isUp = holding.change24hPct >= 0;
    final changeColor = isUp ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final accent = _accentFor(holding.symbol);
    final pnlPrefix = holding.pnl24hUsd >= 0 ? '+' : '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _ScaleTap(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: accent.withValues(alpha: 0.18),
                      child: Text(
                        holding.symbol.length >= 2
                            ? holding.symbol.substring(0, 2)
                            : holding.symbol,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                          color: accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                holding.symbol,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${holding.allocationPct.toStringAsFixed(1)}%',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${holding.amount >= 1 ? holding.amount.toStringAsFixed(2) : holding.amount.toStringAsFixed(4)} · ${_formatPrice(holding.priceUsd)}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatUsd(holding.valueUsd),
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${isUp ? '+' : ''}${holding.change24hPct.toStringAsFixed(2)}%',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: changeColor),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('24h P&L', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    const Spacer(),
                    Text(
                      '$pnlPrefix${formatUsd(holding.pnl24hUsd.abs())}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: changeColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (holding.allocationPct / 100).clamp(0.02, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    color: accent.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

  Future<void> _openEditor({AlertRecord? existing}) async {
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
      alertType = _types.contains(existing.alertType) ? existing.alertType : 'Price';
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

  void _save() {
    final coin = _resolvedCoin;
    if (coin.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a coin symbol')),
      );
      return;
    }

    if (alertType != 'MACD' && alertType != 'News' && _valueController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a trigger value')),
      );
      return;
    }

    final alert = AlertRecord(
      id: widget.initial?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      coin: coin,
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
              items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
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