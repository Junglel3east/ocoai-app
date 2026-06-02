import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Live portfolio quotes + persisted holding amounts.
class PortfolioHolding {
  final String symbol;
  final double amount;
  final double priceUsd;
  final double change24hPct;
  final double valueUsd;
  /// Estimated 24h unrealized P&L (USD) from price change × position value.
  final double pnl24hUsd;
  final double allocationPct;

  const PortfolioHolding({
    required this.symbol,
    required this.amount,
    required this.priceUsd,
    required this.change24hPct,
    required this.valueUsd,
    required this.pnl24hUsd,
    required this.allocationPct,
  });
}

class PortfolioSnapshot {
  final List<PortfolioHolding> holdings;
  final double totalValueUsd;
  final double change24hPct;
  final double change24hUsd;
  final bool usedLivePrices;
  final DateTime fetchedAt;

  const PortfolioSnapshot({
    required this.holdings,
    required this.totalValueUsd,
    required this.change24hPct,
    required this.change24hUsd,
    required this.usedLivePrices,
    required this.fetchedAt,
  });
}

abstract final class PortfolioStore {
  static const _holdingsKey = 'portfolio_holdings_json';

  /// Core demo holdings — BTC, ETH, SOL highlighted; extras from watchlist.
  static const Map<String, double> defaultAmounts = {
    'BTC': 0.42,
    'ETH': 3.15,
    'SOL': 28.5,
    'BNB': 4.2,
    'XRP': 1250,
    'LINK': 95,
  };

  static Future<Map<String, double>> loadAmounts({
    List<String> watchlist = const [],
    Set<String> defaultWatchlist = const {},
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_holdingsKey);
    Map<String, double> amounts = Map<String, double>.from(defaultAmounts);

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final sym = entry.key.toUpperCase();
          final val = entry.value;
          if (val is num) amounts[sym] = val.toDouble();
        }
      } catch (_) {
        // Keep defaults on corrupt data.
      }
    }

    final symbols = <String>{'BTC', 'ETH', 'SOL'};
    for (final coin in watchlist) {
      if (!defaultWatchlist.contains(coin)) symbols.add(coin.toUpperCase());
    }
    for (final sym in symbols) {
      amounts.putIfAbsent(sym, () {
        if (sym == 'BTC') return 0.42;
        if (sym == 'ETH') return 3.15;
        if (sym == 'SOL') return 28.5;
        return 50 + sym.hashCode.abs() % 150 / 10.0;
      });
    }
    return amounts;
  }

  static Future<void> saveAmounts(Map<String, double> amounts) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      amounts.map((k, v) => MapEntry(k.toUpperCase(), v)),
    );
    await prefs.setString(_holdingsKey, encoded);
  }
}

abstract final class PortfolioService {
  static Future<PortfolioSnapshot> fetchSnapshot({
    List<String> watchlist = const [],
    Set<String> defaultWatchlist = const {},
  }) async {
    final amounts = await PortfolioStore.loadAmounts(
      watchlist: watchlist,
      defaultWatchlist: defaultWatchlist,
    );

    final quotes = await _fetchBinance24hQuotes(amounts.keys.toList());
    var usedLive = quotes.isNotEmpty;

    final rows = <({String symbol, double amount, double price, double change, double value})>[];
    for (final entry in amounts.entries) {
      final symbol = entry.key;
      final amount = entry.value;
      final quote = quotes[symbol];
      final price = quote?.price ?? _fallbackPrice(symbol);
      final change = quote?.change24hPct ?? _fallbackChange(symbol);
      if (quote == null) usedLive = false;
      final value = amount * price;
      rows.add((symbol: symbol, amount: amount, price: price, change: change, value: value));
    }

    rows.sort((a, b) {
      const coreOrder = {'BTC': 0, 'ETH': 1, 'SOL': 2};
      final aCore = coreOrder[a.symbol] ?? 99;
      final bCore = coreOrder[b.symbol] ?? 99;
      if (aCore != bCore) return aCore.compareTo(bCore);
      return b.value.compareTo(a.value);
    });

    final total = rows.fold<double>(0, (s, r) => s + r.value);
    final holdings = rows.map((r) {
      final pnl = r.value * (r.change / 100);
      final alloc = total > 0 ? (r.value / total) * 100 : 0.0;
      return PortfolioHolding(
        symbol: r.symbol,
        amount: r.amount,
        priceUsd: r.price,
        change24hPct: r.change,
        valueUsd: r.value,
        pnl24hUsd: pnl,
        allocationPct: alloc,
      );
    }).toList();

    final weightedChange = total <= 0
        ? 0.0
        : holdings.fold<double>(0, (s, h) => s + h.change24hPct * h.valueUsd) / total;
    final changeUsd = holdings.fold<double>(0, (s, h) => s + h.pnl24hUsd);

    return PortfolioSnapshot(
      holdings: holdings,
      totalValueUsd: total,
      change24hPct: weightedChange,
      change24hUsd: changeUsd,
      usedLivePrices: usedLive,
      fetchedAt: DateTime.now(),
    );
  }

  static Future<Map<String, _Quote>> _fetchBinance24hQuotes(List<String> symbols) async {
    final wanted = symbols.map((s) => '${s.toUpperCase()}USDT').toSet();
    if (wanted.isEmpty) return {};

    try {
      final response = await http
          .get(Uri.parse('https://api.binance.com/api/v3/ticker/24hr'))
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return {};

      final list = jsonDecode(response.body) as List<dynamic>;
      final out = <String, _Quote>{};

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final sym = item['symbol']?.toString();
        if (sym == null || !wanted.contains(sym)) continue;

        final base = sym.replaceAll('USDT', '');
        final price = double.tryParse(item['lastPrice']?.toString() ?? '');
        final change = double.tryParse(item['priceChangePercent']?.toString() ?? '');
        if (price == null || price <= 0) continue;

        out[base] = _Quote(price: price, change24hPct: change ?? 0);
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static double _fallbackPrice(String symbol) {
    const seed = {
      'BTC': 76500.0,
      'ETH': 3420.0,
      'SOL': 142.5,
      'BNB': 585.0,
      'XRP': 0.68,
      'ADA': 0.52,
      'DOGE': 0.14,
      'AVAX': 28.4,
      'DOT': 6.8,
      'LINK': 14.2,
    };
    return seed[symbol] ?? (1.0 + symbol.hashCode.abs() % 500 / 10.0);
  }

  static double _fallbackChange(String symbol) {
    return ((symbol.hashCode % 21) - 10) / 2.0;
  }
}

class _Quote {
  final double price;
  final double change24hPct;

  const _Quote({required this.price, required this.change24hPct});
}
