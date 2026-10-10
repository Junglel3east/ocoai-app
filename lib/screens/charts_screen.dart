// Charts tab.

part of '../main.dart';

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
