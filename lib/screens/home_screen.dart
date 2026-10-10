// Home: daily bias, watchlist, news.

part of '../main.dart';

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
  final void Function({
    required dynamic tradeId,
    required String status,
    required double exitPrice,
    double feesUsd,
  }) onCloseTrade;

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
    required this.onCloseTrade,
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
              if (hasReport)
                PushToXButton(
                  iconOnly: true,
                  tooltip: 'Push to X',
                  initialText: XShareService.formatAnalysisPost(
                    coin: snap['coin']?.toString() ?? 'BTC',
                    report: snap['report']?.toString() ?? '',
                  ),
                  sheetTitle: 'Share ${snap['coin']} Analysis',
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
                onCloseTrade: widget.onCloseTrade,
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
            tooltip: 'Learn',
            icon: const Icon(Icons.menu_book_outlined, color: Color(0xFF00BFFF)),
            onPressed: () => Navigator.push(
              context,
              _premiumPageRoute((_) => const OracleAcademyScreen()),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: OracleAlertStore.triggeredCount,
            builder: (context, count, _) {
              return IconButton(
                tooltip: 'Alerts',
                onPressed: () => Navigator.push(
                  context,
                  _premiumPageRoute(
                    (_) => AlertsScreen(
                      trades: widget.trades,
                      onCloseTrade: widget.onCloseTrade,
                    ),
                  ),
                ),
                icon: Badge(
                  isLabelVisible: count > 0 && !OracleAlertStore.muteAll,
                  label: Text(count > 9 ? '9+' : '$count'),
                  backgroundColor: const Color(0xFF00BFFF),
                  textColor: Colors.black,
                  child: const Icon(Icons.notifications),
                ),
              );
            },
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
              Padding(
                padding: _kHomeCardGap,
                child: const _PersonalBankrollBrief(),
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

/// Personalized sizing line under Daily Oracle Bias — uses bankroll + Citadel defaults.
class _PersonalBankrollBrief extends StatelessWidget {
  const _PersonalBankrollBrief();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: StartingCapitalStore.notifier,
      builder: (context, capital, _) {
        final risk = OracleCitadelStore.defaultRiskPercent;
        final lev = OracleCitadelStore.defaultLeverage;
        final riskLabel = risk == risk.roundToDouble() ? '${risk.round()}' : risk.toStringAsFixed(1);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: const Color(0xFF141414),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YOUR DESK',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.3,
                  color: Colors.grey[500],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'With your ${PositionSizing.formatUsd(capital)} bankroll and $riskLabel% risk at ${lev.round()}x, '
                'a typical setup uses ${PositionSizing.formatUsd(PositionSizing.marginUsd(capital, risk))} margin '
                '(${PositionSizing.formatUsd(PositionSizing.notionalUsd(capital, risk, lev))} notional).',
                style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[300]),
              ),
            ],
          ),
        );
      },
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
        unawaited(OracleAlertEngine.instance.noteBias(_oracleBiasLabel(snap.overall)));
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
        onShareToX: () => XShareService.showComposeSheet(
          context,
          initialText: XShareService.formatNewsPost(headline: title, url: url),
          title: 'Share headline',
        ),
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
  final VoidCallback? onShareToX;

  const _LiveNewsCard({
    required this.title,
    required this.source,
    required this.timeAgo,
    this.imageUrl,
    this.onTap,
    this.onShareToX,
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
                if (onShareToX != null)
                  IconButton(
                    tooltip: 'Push to X',
                    icon: Icon(Icons.north_east, size: 20, color: Colors.grey[400]),
                    onPressed: onShareToX,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
