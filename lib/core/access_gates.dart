// Coin access policy, symbol search, and Free-tier upgrade gates.

part of '../main.dart';

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

    if (SubscriptionPlanStore.isExpert || ProPreviewStore.isActive) {
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
  bool offerPreview = false,
}) async {
  await SubscriptionPlanStore.load();
  final result = CoinAccessPolicy.evaluate(raw);
  if (result.allowed) return result.coin;

  if (!showDialogs || !context.mounted) return null;

  if (offerPreview &&
      result.coin != null &&
      result.denial != CoinAccessDenial.invalidSymbol &&
      await offerProPreview(context, feature: result.coin!)) {
    return result.coin;
  }
  if (!context.mounted) return null;

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
      title: const Text('Oracle Pro Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Your Free plan includes BTC, ETH, and SOL only.\n\n'
        '$normalized is outside the Free tier. Unlock Oracle Pro (${GooglePlayBillingService.fallbackProPrice}/mo) to analyze any symbol.',
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
            'View Oracle Pro',
            style: TextStyle(color: Color(0xFFFFB74D), fontWeight: FontWeight.w600),
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
      title: const Text('Oracle Pro Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        '$normalized is not included with your current plan.\n\n'
        'Unlock Oracle Pro (${GooglePlayBillingService.fallbackProPrice}/mo) to analyze any symbol — including new and emerging coins like HYPE.',
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
            'Unlock Oracle Pro',
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
        'Unlock Oracle Pro for an unlimited watchlist across every symbol.',
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
    if (!context.mounted) return false;
    if (await offerProPreview(context, feature: 'The ${timeframe.toUpperCase()} timeframe')) return true;
    if (context.mounted) showTradeSetupTimeframeUpgradePrompt(context);
    return false;
  }

  final coinResult = CoinAccessPolicy.evaluate(coin);
  if (!coinResult.allowed) {
    if (context.mounted) {
      return await resolveCoinForCurrentPlan(context, coin, offerPreview: true) != null;
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
      title: const Text('Oracle Pro Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        'Free plan trade setups are limited to the Daily (1D) timeframe on BTC, ETH, and SOL.\n\n'
        'Unlock Oracle Pro for every timeframe, every symbol, and unlimited setups.',
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
        'Unlock Oracle Pro for unlimited setups on every timeframe.',
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
      title: const Text('Oracle Pro Required', style: TextStyle(fontWeight: FontWeight.w600)),
      content: Text(
        premiumGate
            ? 'Oracle AI Chat is included with Oracle Pro. '
                'Unlock real-time AI assistance for your analyses and trade setups.'
            : 'Unlimited Oracle AI Chat is included with Oracle Pro.',
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
        'Your plan includes ${SubscriptionPlanStore.premiumChatMessagesPerDay} AI chat messages per day. '
        'Oracle Pro includes unlimited Oracle Trader AI Chat.',
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
