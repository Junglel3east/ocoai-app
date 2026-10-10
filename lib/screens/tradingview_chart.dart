// TradingView chart embedding, chart panels, full-screen chart.

part of '../main.dart';

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

/// Base URL so TradingView scripts load reliably inside Android/iOS WebView.
const String kTradingViewChartBaseUrl = 'https://www.tradingview.com';

/// Bridges TradingView WebView lifecycle → Flutter (page finished + chartReady).
final Expando<OcoChartWebBridge> _ocoChartBridges = Expando<OcoChartWebBridge>();

class OcoChartWebBridge {
  Completer<void>? _pageFinished;
  Completer<String>? _chartReady;

  /// Reset waiters before a new HTML load (Flux reload path).
  void beginLoad() {
    _pageFinished = Completer<void>();
    _chartReady = Completer<String>();
    debugPrint('[Chart] OcoChartWebBridge: beginLoad — waiting for page + chartReady');
  }

  void attachOnce(WebViewController controller) {
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (url) => debugPrint('[Chart] onPageStarted: $url'),
        onPageFinished: (url) {
          debugPrint('[Chart] onPageFinished: $url');
          final c = _pageFinished;
          if (c != null && !c.isCompleted) c.complete();
        },
        onWebResourceError: (WebResourceError error) {
          debugPrint(
            '[Chart] WebResourceError: ${error.description} (code ${error.errorCode})',
          );
        },
      ),
    );

    controller.addJavaScriptChannel(
      'OcoChartBridge',
      onMessageReceived: (JavaScriptMessage message) {
        final payload = message.message;
        debugPrint('[Chart] OcoChartBridge received: $payload');
        if (payload.startsWith('chartReady')) {
          final c = _chartReady;
          if (c != null && !c.isCompleted) c.complete(payload);
        }
      },
    );

    if (controller.platform is AndroidWebViewController) {
      (controller.platform as AndroidWebViewController).setOnConsoleMessage(
        (JavaScriptConsoleMessage message) {
          debugPrint('[Chart JS ${message.level.name}] ${message.message}');
        },
      );
    }
  }

  Future<bool> waitForChartReady({
    Duration pageTimeout = const Duration(seconds: 15),
    Duration chartTimeout = const Duration(seconds: 25),
  }) async {
    try {
      await _pageFinished!.future.timeout(pageTimeout);
      debugPrint('[Chart] onPageFinished confirmed — awaiting OcoChartBridge chartReady');
    } on TimeoutException {
      debugPrint(
        '[Chart] TIMEOUT: onPageFinished not received within ${pageTimeout.inSeconds}s',
      );
      return false;
    } catch (e) {
      debugPrint('[Chart] error waiting for onPageFinished: $e');
      return false;
    }

    try {
      final signal = await _chartReady!.future.timeout(chartTimeout);
      debugPrint('[Chart] chartReady confirmed: $signal');
      return true;
    } on TimeoutException {
      debugPrint(
        '[Chart] TIMEOUT: chartReady not received within ${chartTimeout.inSeconds}s',
      );
      return false;
    } catch (e) {
      debugPrint('[Chart] error waiting for chartReady: $e');
      return false;
    }
  }
}

OcoChartWebBridge _bridgeFor(WebViewController controller) {
  var bridge = _ocoChartBridges[controller];
  if (bridge == null) {
    bridge = OcoChartWebBridge();
    bridge.attachOnce(controller);
    _ocoChartBridges[controller] = bridge;
    debugPrint('[Chart] OcoChartWebBridge attached to WebViewController');
  }
  return bridge;
}

/// Trade Setup / Analysis chart — Heikin Ashi. Flux studies are not loaded in-app
/// (widget cannot read Pine values). Live Flux comes from /flux_read webhooks.
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
        var ocoTvWidget = new TradingView.widget({
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
            "use_localstorage_for_settings",
            "create_volume_indicator_by_default",
            "create_volume_indicator_by_default_once",
            "volume_force_overlay"
          ],
          "studies": [],
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
            "mainSeriesProperties.haStyle.wickDownColor": "#EF5350"
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
        ocoTvWidget.onChartReady(function() {
          try {
            if (typeof OcoChartBridge !== 'undefined') {
              OcoChartBridge.postMessage('chartReady');
            }
          } catch (err) {
            try {
              OcoChartBridge.postMessage('chartError:' + (err && err.message ? err.message : 'unknown'));
            } catch (ignore) {}
          }
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

  _bridgeFor(controller);

  controller.loadHtmlString(
    buildTradeSetupTradingViewHTML(
      sym,
      tvSymbol: tvSymbol,
      timeframe: timeframe,
    ),
    baseUrl: kTradingViewChartBaseUrl,
  );
  return controller;
}

/// Embedded chart with expand-to-fullscreen control (Analysis, Trade Setup, etc.).
class TradingViewChartPanel extends StatefulWidget {
  final String symbol;
  final WebViewController controller;
  final double height;
  final bool mountWebView;
  /// When set, fullscreen opens the same Analysis/Trade Setup chart (Heikin Ashi).
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
        child: Stack(
          children: [
            WebViewWidget(
              controller: _controller,
              gestureRecognizers: kTradingViewGestureRecognizers,
            ),
          ],
        ),
      ),
    );
  }
}
