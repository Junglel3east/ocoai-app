import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'daily_analysis_store.dart';

/// Aggregates watchlist, trade history, and market data for Oracle Desk.
abstract final class OracleDeskService {
  static const double _fallbackRiskPercent = 1.0;
  static const double _fallbackLeverage = 5.0;

  static OracleDeskPerformance computePerformance({
    required List<Map<String, dynamic>> trades,
    required List<String> watchlist,
    double startingCapitalUsd = 10000,
    double defaultRiskPercent = _fallbackRiskPercent,
    double defaultLeverage = _fallbackLeverage,
  }) {
    final capital = startingCapitalUsd.clamp(0.0, 1000000.0);
    final riskFallback = defaultRiskPercent.clamp(0.1, 100.0);
    final levFallback = defaultLeverage.clamp(1.0, 100.0);
    final closed = trades.where((t) {
      final s = (t['status'] ?? '').toString();
      return s == 'Win' || s == 'Loss';
    }).toList();

    final wins = closed.where((t) => t['status'] == 'Win').length;
    final winRate = closed.isEmpty ? 0.0 : wins / closed.length;

    final rrs = closed.map(_realizedR).whereType<double>().toList();
    final avgRr = rrs.isEmpty ? 0.0 : rrs.reduce((a, b) => a + b) / rrs.length;

    final winR = rrs.where((r) => r > 0).fold<double>(0, (a, b) => a + b);
    final lossR = rrs.where((r) => r <= 0).map((r) => r.abs()).fold<double>(0, (a, b) => a + b);
    final profitFactor = lossR <= 0 ? (winR > 0 ? 99.0 : 0.0) : winR / lossR;

    final totalAiAlpha = closed.fold<double>(
      0,
      (sum, t) => sum + _dollarPnl(t, capital, riskFallback: riskFallback, levFallback: levFallback),
    );

    final now = DateTime.now();
    final equity7 = _buildEquityCurve(
      trades,
      now.subtract(const Duration(days: 7)),
      capital,
      riskFallback: riskFallback,
      levFallback: levFallback,
    );
    final equity30 = _buildEquityCurve(
      trades,
      now.subtract(const Duration(days: 30)),
      capital,
      riskFallback: riskFallback,
      levFallback: levFallback,
    );
    final paperWeek = _paperPnlForWindow(
      trades,
      now.subtract(const Duration(days: 7)),
      capital,
      riskFallback: riskFallback,
      levFallback: levFallback,
    );
    final streak = _computeStreak(trades);
    final edge = _buildEdgeBreakdown(trades, watchlist);

    return OracleDeskPerformance(
      equity7d: equity7,
      equity30d: equity30,
      winRatePct: winRate * 100,
      avgRiskReward: avgRr,
      profitFactor: profitFactor,
      totalAiAlphaUsd: totalAiAlpha,
      paperPnlThisWeekUsd: paperWeek,
      closedCount: closed.length,
      winCount: wins,
      streak: streak,
      edge: edge,
      startingCapitalUsd: capital,
    );
  }

  /// Live bias + 24h quotes (quotes power Oracle Pulse without re-fetching).
  static Future<({OracleDeskBias bias, Map<String, double> change24h})> fetchDeskBundle({
    required List<String> watchlist,
    required List<Map<String, dynamic>> trades,
    required List<Map<String, dynamic>> history,
  }) async {
    final symbols = _biasSymbols(watchlist, trades);
    final quotes = await _fetch24hQuotes(symbols);
    final bias = _buildBias(symbols, quotes, trades, history);
    return (bias: bias, change24h: quotes);
  }

  static Future<OracleDeskBias> fetchPersonalBias({
    required List<String> watchlist,
    required List<Map<String, dynamic>> trades,
    required List<Map<String, dynamic>> history,
  }) async {
    final bundle = await fetchDeskBundle(
      watchlist: watchlist,
      trades: trades,
      history: history,
    );
    return bundle.bias;
  }

  /// High-confluence radar cards for Oracle Pulse (3–4 top movers).
  static List<OraclePulseOpportunity> buildOraclePulse({
    required OracleDeskBias bias,
    required Map<String, double> change24h,
    required List<String> watchlist,
    required List<Map<String, dynamic>> history,
    String signalTimeframe = '1h',
  }) {
    final daily = DailyAnalysisStore.loadTodayByCoin();
    final candidates = <String>{
      ...bias.recommendedCoins,
      ...watchlist.map((c) => c.trim().toUpperCase()).where((c) => c.isNotEmpty),
      ...change24h.keys,
    };

    final scored = <_PulseScore>[];
    for (final coin in candidates) {
      final ch = change24h[coin];
      if (ch == null) continue;
      final aligned = (bias.kind == OracleDeskBiasKind.bullish && ch > 0) ||
          (bias.kind == OracleDeskBiasKind.bearish && ch < 0) ||
          (bias.kind == OracleDeskBiasKind.neutral && ch.abs() > 0.8);
      final hasDaily = daily.containsKey(coin);
      final score = ch.abs() * 3.2 + (aligned ? 12.0 : 0.0) + (hasDaily ? 8.0 : 0.0) + bias.confidencePct * 0.05;
      scored.add(_PulseScore(coin: coin, change24h: ch, score: score, aligned: aligned, hasDaily: hasDaily));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final top = scored.take(4).toList();
    if (top.isEmpty) {
      return [
        OraclePulseOpportunity(
          coin: 'BTC',
          direction: OraclePulseDirection.long,
          convictionPct: 72,
          whyNow: 'BTC on radar — watching Daily VWAP reclaim + liquidity sweep setup.',
          signalTimeframe: signalTimeframe,
        ),
        OraclePulseOpportunity(
          coin: 'ETH',
          direction: OraclePulseDirection.long,
          convictionPct: 68,
          whyNow: 'ETH buyers stepping in — sweep below equal lows possible.',
          signalTimeframe: signalTimeframe,
        ),
      ];
    }

    return top.map((s) {
      final read = _pulseRead(s.coin, s.change24h, bias.kind);
      var conviction = (58 + s.change24h.abs() * 4.5 + (s.aligned ? 14 : 0) + (s.hasDaily ? 6 : 0))
          .round()
          .clamp(50, 96);
      if (read.play != OraclePulsePlay.trend) {
        conviction = conviction.clamp(50, 72);
      }
      return OraclePulseOpportunity(
        coin: s.coin,
        direction: read.direction,
        convictionPct: conviction,
        whyNow: _pulseWhyNow(
          s.coin,
          s.change24h,
          read.direction,
          s.aligned,
          s.hasDaily,
          history,
          play: read.play,
        ),
        signalTimeframe: signalTimeframe,
        play: read.play,
      );
    }).toList();
  }

  @Deprecated('Use buildOraclePulse')
  static List<OraclePulseOpportunity> buildAlphaPulse({
    required OracleDeskBias bias,
    required Map<String, double> change24h,
    required List<String> watchlist,
    required List<Map<String, dynamic>> history,
  }) =>
      buildOraclePulse(
        bias: bias,
        change24h: change24h,
        watchlist: watchlist,
        history: history,
      );

  /// BTC/ETH ~5% 24h, alts ~7.5% — treated as extended, not a fresh breakout chase.
  static const double btcEthExtendedPct = 5.0;
  static const double altExtendedPct = 7.5;

  static bool isExtendedMove(String coin, double change24h) {
    final abs = change24h.abs();
    if (coin == 'BTC' || coin == 'ETH') return abs >= btcEthExtendedPct;
    return abs >= altExtendedPct;
  }

  static String structureAnchor(String coin) {
    final row = DailyAnalysisStore.loadTodayByCoin()[coin];
    final report = (row?['report'] ?? '').toString();
    if (report.isEmpty) return 'Daily VWAP / prior-day level';
    final sl = RegExp(
      r'(?:SL|Invalidation)\s*(?:at|:)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(report);
    final entry = RegExp(
      r'Entry(?:\s*:|\s+at)?[^\n$]{0,48}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(report);
    if (sl != null) return 'support / invalidation near \$${sl.group(1)}';
    if (entry != null) return 'daily entry zone \$${entry.group(1)}';
    return 'Daily VWAP / prior-day level';
  }

  static ({OraclePulseDirection direction, OraclePulsePlay play}) _pulseRead(
    String coin,
    double change24h,
    OracleDeskBiasKind bias,
  ) {
    final extended = isExtendedMove(coin, change24h);
    if (extended && change24h > 0) {
      if (bias == OracleDeskBiasKind.bearish) {
        return (direction: OraclePulseDirection.short, play: OraclePulsePlay.bounceToResistance);
      }
      return (direction: OraclePulseDirection.long, play: OraclePulsePlay.pullbackToSupport);
    }
    if (extended && change24h < 0) {
      if (bias == OracleDeskBiasKind.bullish) {
        return (direction: OraclePulseDirection.long, play: OraclePulsePlay.pullbackToSupport);
      }
      return (direction: OraclePulseDirection.short, play: OraclePulsePlay.bounceToResistance);
    }
    if (bias == OracleDeskBiasKind.bullish && change24h >= 0.15) {
      return (direction: OraclePulseDirection.long, play: OraclePulsePlay.trend);
    }
    if (bias == OracleDeskBiasKind.bearish && change24h <= -0.15) {
      return (direction: OraclePulseDirection.short, play: OraclePulsePlay.trend);
    }
    return (
      direction: change24h >= 0 ? OraclePulseDirection.long : OraclePulseDirection.short,
      play: OraclePulsePlay.trend,
    );
  }

  static String _pulseWhyNow(
    String coin,
    double change24h,
    OraclePulseDirection dir,
    bool aligned,
    bool hasDaily,
    List<Map<String, dynamic>> history, {
    OraclePulsePlay play = OraclePulsePlay.trend,
  }) {
    final move = '${change24h >= 0 ? '+' : ''}${change24h.toStringAsFixed(1)}% 24h';
    final anchor = structureAnchor(coin);
    if (play == OraclePulsePlay.pullbackToSupport) {
      if (change24h > 0) {
        return '$coin $move — extended. Do not chase. Longs wait for pullback to $anchor.';
      }
      return '$coin $move on a bullish Daily — flush, not a new short. Wait for sweep + reclaim of $anchor.';
    }
    if (play == OraclePulsePlay.bounceToResistance) {
      if (change24h > 0) {
        return '$coin $move into a bearish Daily — bounce, not a squeeze. Wait for rejection at $anchor.';
      }
      return '$coin $move — extended dump. Do not panic-short the low. Shorts wait for bounce into $anchor.';
    }
    final setupToday = history.any((h) =>
        h['source'] == 'trade_setup' && (h['coin'] ?? '').toString().toUpperCase() == coin);
    if (hasDaily && aligned) {
      return '$coin reclaiming Daily VWAP + $move — MTF lining up ${dir.label}.';
    }
    if (setupToday) {
      return 'Fresh setup zone — $move with active OB/FVG levels on $coin.';
    }
    if (aligned) {
      return 'Structure aligns ${dir.label} — $move with buyers/sellers actually showing up.';
    }
    return 'Liquidity sweep setup $move — radar flagged tactical ${dir.label} on $coin.';
  }

  static List<String> _biasSymbols(List<String> watchlist, List<Map<String, dynamic>> trades) {
    final set = <String>{'BTC', 'ETH'};
    for (final w in watchlist) {
      final c = w.trim().toUpperCase();
      if (c.isNotEmpty) set.add(c);
    }
    for (final t in trades.take(12)) {
      final c = (t['coin'] ?? '').toString().trim().toUpperCase();
      if (c.isNotEmpty) set.add(c);
    }
    final list = set.toList()..sort();
    return list.take(8).toList();
  }

  static Future<Map<String, double>> _fetch24hQuotes(List<String> symbols) async {
    final out = <String, double>{};
    if (symbols.isEmpty) return out;
    try {
      final response = await http
          .get(
            Uri.parse('https://api.binance.com/api/v3/ticker/24hr'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return out;
      final list = jsonDecode(response.body) as List<dynamic>;
      final byPair = <String, Map<String, dynamic>>{};
      for (final raw in list) {
        if (raw is Map<String, dynamic>) {
          final sym = raw['symbol']?.toString();
          if (sym != null) byPair[sym] = raw;
        }
      }
      for (final base in symbols) {
        final row = byPair['${base}USDT'];
        if (row == null) continue;
        final change = double.tryParse(row['priceChangePercent']?.toString() ?? '');
        if (change != null) out[base] = change;
      }
    } catch (_) {}
    return out;
  }

  static OracleDeskBias _buildBias(
    List<String> symbols,
    Map<String, double> change24h,
    List<Map<String, dynamic>> trades,
    List<Map<String, dynamic>> history,
  ) {
    final perfByCoin = _winRateByCoin(trades);
    double score = 0;
    double weightSum = 0;
    final movers = <MapEntry<String, double>>[];

    for (final sym in symbols) {
      final ch = change24h[sym];
      if (ch == null) continue;
      movers.add(MapEntry(sym, ch));
      final userEdge = perfByCoin[sym] ?? 0.5;
      final w = 0.6 + userEdge * 0.8;
      score += ch * w;
      weightSum += w;
    }

    final avg = weightSum > 0 ? score / weightSum : 0.0;
    final kind = avg >= 0.35
        ? OracleDeskBiasKind.bullish
        : avg <= -0.35
            ? OracleDeskBiasKind.bearish
            : OracleDeskBiasKind.neutral;

    final confidence = (32 + movers.map((e) => e.value.abs()).fold<double>(0, (a, b) => a + b) / math.max(1, movers.length) * 11)
        .round()
        .clamp(34, 94);

    final title = _sentimentTitle(kind, avg);
    final reasoning = _reasoningParagraph(
      symbols: symbols,
      change24h: change24h,
      perfByCoin: perfByCoin,
      trades: trades,
      history: history,
      avg: avg,
      kind: kind,
    );

    movers.sort((a, b) => b.value.compareTo(a.value));
    final chips = <String>[];
    for (final e in movers) {
      if (chips.length >= 4) break;
      chips.add(e.key);
    }
    if (chips.length < 2) {
      for (final s in symbols) {
        if (chips.contains(s)) continue;
        chips.add(s);
        if (chips.length >= 4) break;
      }
    }

    return OracleDeskBias(
      kind: kind,
      confidencePct: confidence,
      title: title,
      reasoning: reasoning,
      recommendedCoins: chips,
      avgMomentum: avg,
    );
  }

  static String _sentimentTitle(OracleDeskBiasKind kind, double avg) {
    switch (kind) {
      case OracleDeskBiasKind.bullish:
        if (avg >= 1.2) return 'Strongly Bullish';
        if (avg >= 0.55) return 'Moderately Bullish';
        return 'Cautiously Bullish';
      case OracleDeskBiasKind.bearish:
        if (avg <= -1.2) return 'Strongly Bearish';
        if (avg <= -0.55) return 'Moderately Bearish';
        return 'Cautiously Bearish';
      case OracleDeskBiasKind.neutral:
        return 'Neutral / Range-Bound';
    }
  }

  static String _reasoningParagraph({
    required List<String> symbols,
    required Map<String, double> change24h,
    required Map<String, double> perfByCoin,
    required List<Map<String, dynamic>> trades,
    required List<Map<String, dynamic>> history,
    required double avg,
    required OracleDeskBiasKind kind,
  }) {
    final watchParts = <String>[];
    for (final sym in symbols.take(4)) {
      final ch = change24h[sym];
      if (ch == null) continue;
      watchParts.add('$sym ${ch >= 0 ? '+' : ''}${ch.toStringAsFixed(1)}%');
    }

    final closedOnWatch = trades.where((t) {
      final s = (t['status'] ?? '').toString();
      return (s == 'Win' || s == 'Loss') && symbols.contains((t['coin'] ?? '').toString().toUpperCase());
    }).length;

    final setupCount = history.where((h) => h['source'] == 'trade_setup').length;
    final bestCoin = perfByCoin.entries.isEmpty
        ? null
        : perfByCoin.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

    final biasWord = kind == OracleDeskBiasKind.bullish
        ? 'constructive'
        : kind == OracleDeskBiasKind.bearish
            ? 'defensive'
            : 'balanced';

    final watchLine = watchParts.isEmpty
        ? 'Watchlist mixed — no clean Daily VWAP reclaim across majors yet.'
        : 'Watchlist: ${watchParts.join(' · ')}.';

    final perfLine = closedOnWatch > 0
        ? ' You have $closedOnWatch closed setup${closedOnWatch == 1 ? '' : 's'} on watchlist names'
            '${bestCoin != null && (perfByCoin[bestCoin] ?? 0) >= 0.55 ? ' — strongest edge on $bestCoin' : ''}.'
        : setupCount > 0
            ? ' $setupCount AI trade setup${setupCount == 1 ? '' : 's'} saved — performance curve building as trades close.'
            : ' Run Trade Setup on your watchlist to personalize this desk.';

    return '$watchLine Desk bias $biasWord (${avg >= 0 ? '+' : ''}${avg.toStringAsFixed(2)}% composite 24h).$perfLine';
  }

  static Map<String, double> _winRateByCoin(List<Map<String, dynamic>> trades) {
    final byCoin = <String, List<String>>{};
    for (final t in trades) {
      final s = (t['status'] ?? '').toString();
      if (s != 'Win' && s != 'Loss') continue;
      final c = (t['coin'] ?? '').toString().toUpperCase();
      if (c.isEmpty) continue;
      byCoin.putIfAbsent(c, () => []).add(s);
    }
    return byCoin.map((coin, statuses) {
      final wins = statuses.where((s) => s == 'Win').length;
      return MapEntry(coin, wins / statuses.length);
    });
  }

  static List<double> _buildEquityCurve(
    List<Map<String, dynamic>> trades,
    DateTime since,
    double capital, {
    required double riskFallback,
    required double levFallback,
  }) {
    final relevant = trades.where((t) {
      final dt = DateTime.tryParse(t['createdAt']?.toString() ?? '');
      return dt != null && !dt.isBefore(since);
    }).toList()
      ..sort((a, b) {
        final at = DateTime.tryParse(a['createdAt']?.toString() ?? '')!;
        final bt = DateTime.tryParse(b['createdAt']?.toString() ?? '')!;
        return at.compareTo(bt);
      });

    final start = capital > 0 ? capital : 1.0;
    final points = <double>[start];
    var equity = start;
    for (final t in relevant) {
      final s = (t['status'] ?? '').toString();
      if (s == 'Win' || s == 'Loss') {
        equity += _dollarPnl(t, capital, riskFallback: riskFallback, levFallback: levFallback);
      } else {
        equity += _dollarPnl(
              t,
              capital,
              riskFallback: riskFallback,
              levFallback: levFallback,
              realizedOnly: false,
            ) *
            0.35;
      }
      points.add(equity);
    }
    if (points.length < 3) {
      return [1.0, 1.02, 1.01, 1.03, 1.02];
    }
    return _normalizeSeries(points);
  }

  static List<double> _normalizeSeries(List<double> raw) {
    final min = raw.reduce(math.min);
    final max = raw.reduce(math.max);
    final span = (max - min).abs() < 1e-6 ? 1.0 : max - min;
    return raw.map((v) => ((v - min) / span).clamp(0.0, 1.0)).toList();
  }

  static OracleDeskStreak _computeStreak(List<Map<String, dynamic>> trades) {
    final closed = trades.where((t) {
      final s = (t['status'] ?? '').toString();
      return s == 'Win' || s == 'Loss';
    }).toList()
      ..sort((a, b) {
        final at = DateTime.tryParse(a['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = DateTime.tryParse(b['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });

    if (closed.isEmpty) {
      return const OracleDeskStreak(kind: OracleDeskStreakKind.neutral, count: 0, label: 'No streak yet');
    }

    final first = (closed.first['status'] ?? '').toString();
    var count = 1;
    for (var i = 1; i < closed.length; i++) {
      if ((closed[i]['status'] ?? '').toString() == first) {
        count++;
      } else {
        break;
      }
    }

    if (first == 'Win') {
      return OracleDeskStreak(
        kind: OracleDeskStreakKind.hot,
        count: count,
        label: count == 1 ? '1W streak' : '${count}W hot streak',
      );
    }
    return OracleDeskStreak(
      kind: OracleDeskStreakKind.cold,
      count: count,
      label: count == 1 ? '1L streak' : '${count}L cold streak',
    );
  }

  static Map<String, double> _winRateByCoinSince(
    List<Map<String, dynamic>> trades,
    DateTime since,
  ) {
    final byCoin = <String, List<String>>{};
    for (final t in trades) {
      final s = (t['status'] ?? '').toString();
      if (s != 'Win' && s != 'Loss') continue;
      final dt = DateTime.tryParse(t['createdAt']?.toString() ?? '');
      if (dt == null || dt.isBefore(since)) continue;
      final c = (t['coin'] ?? '').toString().toUpperCase();
      if (c.isEmpty) continue;
      byCoin.putIfAbsent(c, () => []).add(s);
    }
    return byCoin.map((coin, statuses) {
      final wins = statuses.where((s) => s == 'Win').length;
      return MapEntry(coin, wins / statuses.length);
    });
  }

  static OracleDeskEdgeBreakdown _buildEdgeBreakdown(
    List<Map<String, dynamic>> trades,
    List<String> watchlist,
  ) {
    final now = DateTime.now();
    final weekRates = _winRateByCoinSince(trades, now.subtract(const Duration(days: 7)));
    final monthRates = _winRateByCoinSince(trades, now.subtract(const Duration(days: 30)));
    final allRates = _winRateByCoin(trades);

    final coins = <String>{
      ...weekRates.keys,
      ...monthRates.keys,
      ...allRates.keys,
      ...watchlist.map((w) => w.trim().toUpperCase()).where((c) => c.isNotEmpty),
    };

    final coinEdges = coins.map((coin) {
      final weekWr = weekRates[coin];
      final monthWr = monthRates[coin];
      final allWr = allRates[coin];
      final weekEdge = weekWr != null ? (weekWr - 0.5) * 100 : 0.0;
      final monthEdge = monthWr != null ? (monthWr - 0.5) * 100 : (allWr != null ? (allWr - 0.5) * 100 : 0.0);
      final samples = trades.where((t) {
        final s = (t['status'] ?? '').toString();
        return (s == 'Win' || s == 'Loss') && (t['coin'] ?? '').toString().toUpperCase() == coin;
      }).length;
      return CoinEdgeStat(
        coin: coin,
        winRatePct: (monthWr ?? weekWr ?? allWr ?? 0.5) * 100,
        edgePctWeek: weekEdge,
        edgePctMonth: monthEdge,
        hasWeekData: weekWr != null,
        hasMonthData: monthWr != null || allWr != null,
        samples: samples,
      );
    }).toList();

    coinEdges.sort((a, b) => b.edgePctMonth.compareTo(a.edgePctMonth));
    var topCoins = coinEdges.take(4).toList();
    if (topCoins.length < 4) {
      for (final w in watchlist) {
        final c = w.trim().toUpperCase();
        if (c.isEmpty || topCoins.any((x) => x.coin == c)) continue;
        topCoins.add(CoinEdgeStat(
          coin: c,
          winRatePct: 0,
          edgePctWeek: 0,
          edgePctMonth: 0,
          hasWeekData: false,
          hasMonthData: false,
          samples: 0,
        ));
        if (topCoins.length >= 4) break;
      }
    }
    while (topCoins.length < 4) {
      const fallbacks = ['BTC', 'ETH', 'SOL', 'BNB'];
      for (final c in fallbacks) {
        if (topCoins.any((x) => x.coin == c)) continue;
        topCoins.add(CoinEdgeStat(
          coin: c,
          winRatePct: 0,
          edgePctWeek: 0,
          edgePctMonth: 0,
          hasWeekData: false,
          hasMonthData: false,
          samples: 0,
        ));
        if (topCoins.length >= 4) break;
      }
      break;
    }

    final tfStats = <String, List<String>>{};
    for (final t in trades) {
      final s = (t['status'] ?? '').toString();
      if (s != 'Win' && s != 'Loss') continue;
      final raw = (t['timeframe'] ?? '4h').toString().toUpperCase();
      final tf = raw.contains('1D') || raw == '1D'
          ? '1D'
          : raw.contains('4') || raw == '4H'
              ? '4H'
              : '1H';
      tfStats.putIfAbsent(tf, () => []).add(s);
    }

    final timeframeEdges = tfStats.entries
        .map((e) {
          final wins = e.value.where((s) => s == 'Win').length;
          return TimeframeEdgeStat(
            timeframe: e.key,
            winRatePct: wins / e.value.length * 100,
            samples: e.value.length,
          );
        })
        .toList()
      ..sort((a, b) => b.winRatePct.compareTo(a.winRatePct));

    if (timeframeEdges.isEmpty) {
      timeframeEdges.addAll([
        const TimeframeEdgeStat(timeframe: '4H', winRatePct: 0, samples: 0),
        const TimeframeEdgeStat(timeframe: '1H', winRatePct: 0, samples: 0),
        const TimeframeEdgeStat(timeframe: '1D', winRatePct: 0, samples: 0),
      ]);
    }

    var longWins = 0, longN = 0, shortWins = 0, shortN = 0;
    for (final t in trades) {
      final s = (t['status'] ?? '').toString();
      if (s != 'Win' && s != 'Loss') continue;
      final dir = _resolveDirection(t);
      if (dir == 'Long Only') {
        longN++;
        if (s == 'Win') longWins++;
      } else {
        shortN++;
        if (s == 'Win') shortWins++;
      }
    }

    return OracleDeskEdgeBreakdown(
      topCoins: topCoins,
      timeframes: timeframeEdges,
      longWinRatePct: longN == 0 ? 0 : longWins / longN * 100,
      shortWinRatePct: shortN == 0 ? 0 : shortWins / shortN * 100,
      longSamples: longN,
      shortSamples: shortN,
    );
  }

  static double _paperPnlForWindow(
    List<Map<String, dynamic>> trades,
    DateTime since,
    double capital, {
    required double riskFallback,
    required double levFallback,
  }) {
    var total = 0.0;
    for (final t in trades) {
      final dt = DateTime.tryParse(t['createdAt']?.toString() ?? '');
      if (dt == null || dt.isBefore(since)) continue;
      final s = (t['status'] ?? '').toString();
      if (s == 'Win' || s == 'Loss') {
        total += _dollarPnl(t, capital, riskFallback: riskFallback, levFallback: levFallback);
      }
    }
    return total;
  }

  static double _tradeRiskPercent(Map<String, dynamic> trade, double fallback) {
    return (_toDouble(trade['riskPercent'] ?? trade['risk_percent']) ?? fallback).clamp(0.1, 100.0);
  }

  static double _tradeLeverage(Map<String, dynamic> trade, double fallback) {
    return (_toDouble(trade['leverage']) ?? fallback).clamp(1.0, 100.0);
  }

  /// Citadel sizing: margin = bankroll × risk%, notional = margin × leverage.
  static double _notionalUsd(
    Map<String, dynamic> trade,
    double capital, {
    required double riskFallback,
    required double levFallback,
  }) {
    final stored = _toDouble(
      trade['notionalUsd'] ?? trade['positionSizeUsd'] ?? trade['notional'],
    );
    if (stored != null && stored > 0) return stored;
    if (capital <= 0) return 0;
    return capital * (_tradeRiskPercent(trade, riskFallback) / 100.0) * _tradeLeverage(trade, levFallback);
  }

  static double _rToPriceFraction(Map<String, dynamic> trade, double r) {
    final entry = _toDouble(trade['entry']);
    final sl = _toDouble(trade['sl']);
    if (entry == null || sl == null || entry.abs() < 1e-12) return r * 0.01;
    return r * ((entry - sl).abs() / entry.abs());
  }

  static double _dollarPnl(
    Map<String, dynamic> trade,
    double capital, {
    required double riskFallback,
    required double levFallback,
    bool realizedOnly = true,
  }) {
    if (capital <= 0) return 0;
    final status = (trade['status'] ?? '').toString();
    final closed = status == 'Win' || status == 'Loss' || status == 'Closed';
    if (!closed && realizedOnly) return 0;

    final exchangePnl = _toDouble(trade['realizedPnl']);
    if (exchangePnl != null && closed) {
      final via = (trade['closedVia'] ?? '').toString();
      final fees = via == 'citadel' ? 0.0 : (_toDouble(trade['feesUsd']) ?? 0);
      return exchangePnl - fees;
    }

    double? r;
    if (closed) {
      r = _realizedR(trade) ?? (status == 'Win' ? 1.2 : -1.0);
    } else {
      r = _unrealizedR(trade) ?? 0;
    }
    final gross = _notionalUsd(trade, capital, riskFallback: riskFallback, levFallback: levFallback) *
        _rToPriceFraction(trade, r);
    final fees = _toDouble(trade['feesUsd']) ?? 0;
    return gross - (closed ? fees : 0);
  }

  static double? _realizedR(Map<String, dynamic> trade) {
    final entry = _toDouble(trade['entry']);
    final sl = _toDouble(trade['sl']);
    if (entry == null || sl == null) return null;
    final risk = (entry - sl).abs();
    if (risk < 1e-12) return null;
    final dir = _resolveDirection(trade);
    final status = (trade['status'] ?? '').toString();

    final exit = _toDouble(trade['exitPrice'] ?? trade['exit']);
    if (exit != null) {
      final move = dir == 'Long Only' ? exit - entry : entry - exit;
      return move / risk;
    }

    if (status == 'Loss') return -1.0;
    if (status == 'Win') {
      final tp1 = _toDouble(trade['tp1']);
      if (tp1 == null) return null;
      final reward = dir == 'Long Only' ? (tp1 - entry).abs() : (entry - tp1).abs();
      return reward / risk;
    }
    return _unrealizedR(trade);
  }

  static double? _unrealizedR(Map<String, dynamic> trade) {
    final entry = _toDouble(trade['entry']);
    final sl = _toDouble(trade['sl']);
    final price = _toDouble(trade['lastPrice']) ?? entry;
    if (entry == null || sl == null || price == null) return null;
    final risk = (entry - sl).abs();
    if (risk < 1e-12) return null;
    final dir = _resolveDirection(trade);
    final move = dir == 'Long Only' ? price - entry : entry - price;
    return (move / risk).clamp(-1.5, 2.5);
  }

  static String _resolveDirection(Map<String, dynamic> trade) {
    final selected = (trade['direction'] ?? 'Smart Direction').toString();
    if (selected == 'Long Only' || selected == 'Short Only') return selected;
    final entry = _toDouble(trade['entry']);
    final sl = _toDouble(trade['sl']);
    if (entry != null && sl != null) return sl < entry ? 'Long Only' : 'Short Only';
    return 'Long Only';
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '').trim());
  }
}

enum OracleDeskBiasKind { bullish, bearish, neutral }

class OracleDeskBias {
  final OracleDeskBiasKind kind;
  final int confidencePct;
  final String title;
  final String reasoning;
  final List<String> recommendedCoins;
  final double avgMomentum;

  const OracleDeskBias({
    required this.kind,
    required this.confidencePct,
    required this.title,
    required this.reasoning,
    required this.recommendedCoins,
    required this.avgMomentum,
  });

  static const OracleDeskBias loading = OracleDeskBias(
    kind: OracleDeskBiasKind.neutral,
    confidencePct: 0,
    title: 'Calibrating…',
    reasoning: 'Syncing your watchlist with live market momentum.',
    recommendedCoins: ['BTC', 'ETH'],
    avgMomentum: 0,
  );
}

class OracleDeskPerformance {
  final List<double> equity7d;
  final List<double> equity30d;
  final double winRatePct;
  final double avgRiskReward;
  final double profitFactor;
  final double totalAiAlphaUsd;
  final double paperPnlThisWeekUsd;
  final int closedCount;
  final int winCount;
  final OracleDeskStreak streak;
  final OracleDeskEdgeBreakdown edge;
  final double startingCapitalUsd;

  const OracleDeskPerformance({
    required this.equity7d,
    required this.equity30d,
    required this.winRatePct,
    required this.avgRiskReward,
    required this.profitFactor,
    required this.totalAiAlphaUsd,
    required this.paperPnlThisWeekUsd,
    required this.closedCount,
    required this.winCount,
    required this.streak,
    required this.edge,
    this.startingCapitalUsd = 10000,
  });
}

enum OracleDeskStreakKind { hot, cold, neutral }

class OracleDeskStreak {
  final OracleDeskStreakKind kind;
  final int count;
  final String label;

  const OracleDeskStreak({
    required this.kind,
    required this.count,
    required this.label,
  });
}

class CoinEdgeStat {
  final String coin;
  final double winRatePct;
  final double edgePctWeek;
  final double edgePctMonth;
  final bool hasWeekData;
  final bool hasMonthData;
  final int samples;

  const CoinEdgeStat({
    required this.coin,
    required this.winRatePct,
    required this.edgePctWeek,
    required this.edgePctMonth,
    required this.hasWeekData,
    required this.hasMonthData,
    required this.samples,
  });
}

class TimeframeEdgeStat {
  final String timeframe;
  final double winRatePct;
  final int samples;

  const TimeframeEdgeStat({
    required this.timeframe,
    required this.winRatePct,
    required this.samples,
  });
}

class OracleDeskEdgeBreakdown {
  final List<CoinEdgeStat> topCoins;
  final List<TimeframeEdgeStat> timeframes;
  final double longWinRatePct;
  final double shortWinRatePct;
  final int longSamples;
  final int shortSamples;

  const OracleDeskEdgeBreakdown({
    required this.topCoins,
    required this.timeframes,
    required this.longWinRatePct,
    required this.shortWinRatePct,
    required this.longSamples,
    required this.shortSamples,
  });
}

enum OraclePulseDirection { long, short }

enum OraclePulsePlay { trend, pullbackToSupport, bounceToResistance }

extension OraclePulsePlayX on OraclePulsePlay {
  String get label {
    switch (this) {
      case OraclePulsePlay.pullbackToSupport:
        return 'Pullback to support';
      case OraclePulsePlay.bounceToResistance:
        return 'Bounce to resistance';
      case OraclePulsePlay.trend:
        return 'Trend';
    }
  }

  bool get isMeanRevert => this != OraclePulsePlay.trend;
}

extension OraclePulseDirectionX on OraclePulseDirection {
  String get label => this == OraclePulseDirection.long ? 'LONG' : 'SHORT';
  bool get isLong => this == OraclePulseDirection.long;
  String get tradeSetupDirection => isLong ? 'Long Only' : 'Short Only';
}

class OraclePulseOpportunity {
  final String coin;
  final OraclePulseDirection direction;
  final int convictionPct;
  final String whyNow;
  final String signalTimeframe;
  final OraclePulsePlay play;

  const OraclePulseOpportunity({
    required this.coin,
    required this.direction,
    required this.convictionPct,
    required this.whyNow,
    this.signalTimeframe = '1h',
    this.play = OraclePulsePlay.trend,
  });

  String get tradeSetupDirection =>
      direction.isLong ? 'Long Only' : 'Short Only';
}

class _PulseScore {
  final String coin;
  final double change24h;
  final double score;
  final bool aligned;
  final bool hasDaily;

  const _PulseScore({
    required this.coin,
    required this.change24h,
    required this.score,
    required this.aligned,
    required this.hasDaily,
  });
}
