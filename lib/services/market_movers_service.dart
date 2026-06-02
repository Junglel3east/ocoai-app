import 'dart:convert';

import 'package:http/http.dart' as http;

class MarketMoverRow {
  final String symbol;
  final double priceUsd;
  final double change24hPct;

  const MarketMoverRow({
    required this.symbol,
    required this.priceUsd,
    required this.change24hPct,
  });
}

class MarketMoversSnapshot {
  final List<MarketMoverRow> gainers;
  final List<MarketMoverRow> losers;
  final List<MarketMoverRow> newCoins;
  final bool usedLiveData;

  const MarketMoversSnapshot({
    required this.gainers,
    required this.losers,
    required this.newCoins,
    required this.usedLiveData,
  });
}

abstract final class MarketMoversService {
  static const _stableBases = {'USDC', 'USDT', 'BUSD', 'FDUSD', 'TUSD', 'DAI', 'USDP'};

  static const expertNewCoins = {
    'BONK', 'WIF', 'PEPE', 'NOT', 'EIGEN', 'BRETT', 'POPCAT', 'MEW', 'DOGS', 'HMSTR',
    'TURBO', 'CATI', 'BOME', 'ENA', 'W', 'ETHFI', 'SAGA', 'TAO', 'JUP',
  };

  static const _fallbackPrices = {
    'BTC': 76500.0,
    'ETH': 3420.0,
    'SOL': 142.5,
    'BNB': 585.0,
    'XRP': 0.68,
    'DOGE': 0.14,
    'ADA': 0.52,
    'AVAX': 28.4,
    'LINK': 14.2,
    'DOT': 6.8,
    'PEPE': 0.000012,
    'WIF': 2.4,
    'BONK': 0.000022,
    'NOT': 0.008,
    'TAO': 380.0,
    'JUP': 0.95,
  };

  static Future<MarketMoversSnapshot> fetch({
    required Set<String> allowedSymbols,
    bool includeNewCoins = false,
    int listLimit = 12,
  }) async {
    var rows = await _fetchUsdtTickers();
    var usedLive = rows.isNotEmpty;

    if (rows.isEmpty) {
      rows = _buildFallbackRows(allowedSymbols);
      usedLive = false;
    }

    final filtered = rows.where((r) => allowedSymbols.contains(r.symbol)).toList();
    if (filtered.isEmpty) {
      final fallbackFiltered = _buildFallbackRows(allowedSymbols);
      return _snapshotFromRows(
        fallbackFiltered,
        allowedSymbols: allowedSymbols,
        includeNewCoins: includeNewCoins,
        listLimit: listLimit,
        usedLiveData: false,
      );
    }

    return _snapshotFromRows(
      filtered,
      allowedSymbols: allowedSymbols,
      includeNewCoins: includeNewCoins,
      listLimit: listLimit,
      usedLiveData: usedLive,
      allRows: rows,
    );
  }

  static MarketMoversSnapshot _snapshotFromRows(
    List<MarketMoverRow> filtered, {
    required Set<String> allowedSymbols,
    required bool includeNewCoins,
    required int listLimit,
    required bool usedLiveData,
    List<MarketMoverRow>? allRows,
  }) {
    final gainers = [...filtered]..sort((a, b) => b.change24hPct.compareTo(a.change24hPct));
    final losers = [...filtered]..sort((a, b) => a.change24hPct.compareTo(b.change24hPct));

    final source = allRows ?? filtered;
    List<MarketMoverRow> newCoins = [];
    if (includeNewCoins) {
      newCoins = source.where((r) => expertNewCoins.contains(r.symbol)).toList()
        ..sort((a, b) => b.change24hPct.compareTo(a.change24hPct));
      if (newCoins.isEmpty) {
        newCoins = _buildFallbackRows(expertNewCoins).take(listLimit).toList();
      }
    }

    return MarketMoversSnapshot(
      gainers: gainers.take(listLimit).toList(),
      losers: losers.take(listLimit).toList(),
      newCoins: newCoins.take(listLimit).toList(),
      usedLiveData: usedLiveData,
    );
  }

  static List<MarketMoverRow> _buildFallbackRows(Set<String> symbols) {
    final list = symbols.toList()..sort();
    return List.generate(list.length, (i) {
      final sym = list[i];
      final seed = sym.hashCode.abs();
      final change = ((seed % 240) - 120) / 10.0;
      final price = _fallbackPrices[sym] ?? (1.0 + (seed % 500) / 10.0);
      return MarketMoverRow(symbol: sym, priceUsd: price, change24hPct: change);
    });
  }

  static Future<List<MarketMoverRow>> _fetchUsdtTickers() async {
    try {
      final response = await http
          .get(Uri.parse('https://api.binance.com/api/v3/ticker/24hr'))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return [];

      final list = jsonDecode(response.body) as List<dynamic>;
      final out = <MarketMoverRow>[];

      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final pair = item['symbol']?.toString();
        if (pair == null || !pair.endsWith('USDT')) continue;
        final base = pair.substring(0, pair.length - 4);
        if (_stableBases.contains(base)) continue;

        final price = double.tryParse(item['lastPrice']?.toString() ?? '');
        final change = double.tryParse(item['priceChangePercent']?.toString() ?? '');
        if (price == null || price <= 0) continue;

        out.add(
          MarketMoverRow(
            symbol: base,
            priceUsd: price,
            change24hPct: change ?? 0,
          ),
        );
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
