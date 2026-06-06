import 'oracle_desk_service.dart';

/// Data layer for Oracle Vision — liquidation heatmap + filtered opportunities.
abstract final class OracleVisionService {
  static const visionTimeframes = ['15m', '1h', '4h', '1D'];

  static Future<OracleVisionSnapshot> loadSnapshot({
    required List<String> watchlist,
    required List<Map<String, dynamic>> trades,
    required List<Map<String, dynamic>> history,
    required String timeframe,
    required bool watchlistOnly,
  }) async {
    final bundle = await OracleDeskService.fetchDeskBundle(
      watchlist: watchlist,
      trades: trades,
      history: history,
    );
    final heatZones = buildLiquidationHeatmap(
      change24h: bundle.change24h,
      watchlist: watchlist,
      bias: bundle.bias,
    );
    final opportunities = _filterOpportunities(
      OracleDeskService.buildOraclePulse(
        bias: bundle.bias,
        change24h: bundle.change24h,
        watchlist: watchlist,
        history: history,
        signalTimeframe: timeframe,
      ),
      watchlist: watchlist,
      trades: trades,
      history: history,
      timeframe: timeframe,
      watchlistOnly: watchlistOnly,
    );
    return OracleVisionSnapshot(
      heatZones: heatZones,
      opportunities: opportunities,
    );
  }

  /// Maps Vision filter TF to Trade Setup dropdown values.
  static String tradeSetupTimeframe(String visionTf) {
    switch (visionTf.toLowerCase()) {
      case '15m':
        return '15m';
      case '4h':
        return '4h';
      case '1d':
        return '1d';
      default:
        return '1h';
    }
  }

  /// Builds liquidation heat zones from live 24h tape (Binance-backed bias bundle).
  static List<LiquidationHeatZone> buildLiquidationHeatmap({
    required Map<String, double> change24h,
    required List<String> watchlist,
    required OracleDeskBias bias,
  }) {
    final pool = <String>{
      ...change24h.keys,
      ...watchlist.map((c) => c.trim().toUpperCase()).where((c) => c.isNotEmpty),
      'BTC',
      'ETH',
      'SOL',
      'BNB',
      'XRP',
    };

    final zones = <LiquidationHeatZone>[];
    for (final coin in pool) {
      final ch = change24h[coin];
      if (ch == null) continue;
      final abs = ch.abs();
      if (abs < 0.35) continue;

      final kind = ch <= -0.85
          ? LiquidationZoneKind.longLiqRisk
          : ch >= 0.85
              ? LiquidationZoneKind.shortSqueeze
              : ch < 0
                  ? LiquidationZoneKind.longLiqRisk
                  : LiquidationZoneKind.shortSqueeze;

      final conviction = (62 + abs * 5.5 + (bias.confidencePct * 0.08)).round().clamp(65, 96);
      zones.add(
        LiquidationHeatZone(
          coin: coin,
          kind: kind,
          heat: (abs / 8).clamp(0.35, 1.0),
          change24hPct: ch,
          convictionPct: conviction,
          whyZone: _whyZoneText(coin, ch, kind),
          direction: kind == LiquidationZoneKind.shortSqueeze
              ? OraclePulseDirection.long
              : OraclePulseDirection.short,
        ),
      );
    }

    zones.sort((a, b) => b.heat.compareTo(a.heat));
    if (zones.length >= 5) return zones.take(6).toList();

    final fallbacks = ['BTC', 'ETH', 'SOL', 'BNB', 'XRP', 'DOGE'];
    for (final coin in fallbacks) {
      if (zones.length >= 6) break;
      if (zones.any((z) => z.coin == coin)) continue;
      zones.add(
        LiquidationHeatZone(
          coin: coin,
          kind: LiquidationZoneKind.shortSqueeze,
          heat: 0.45,
          change24hPct: 0,
          convictionPct: 68,
          whyZone: 'Awaiting live liq cluster refresh — $coin on radar.',
          direction: OraclePulseDirection.long,
        ),
      );
    }
    return zones.take(6).toList();
  }

  static String _whyZoneText(String coin, double change24h, LiquidationZoneKind kind) {
    final move = '${change24h >= 0 ? '+' : ''}${change24h.toStringAsFixed(1)}% 24h';
    switch (kind) {
      case LiquidationZoneKind.longLiqRisk:
        return '$coin long liquidation cluster below — $move cascade risk into stops.';
      case LiquidationZoneKind.shortSqueeze:
        return '$coin short squeeze heat — $move fuel for rapid upside liquidation hunt.';
      case LiquidationZoneKind.neutral:
        return '$coin balanced liq pool — $move, watch for break of heat zone.';
    }
  }

  static List<OraclePulseOpportunity> _filterOpportunities(
    List<OraclePulseOpportunity> base, {
    required List<String> watchlist,
    required List<Map<String, dynamic>> trades,
    required List<Map<String, dynamic>> history,
    required String timeframe,
    required bool watchlistOnly,
  }) {
    final wl = watchlist.map((c) => c.trim().toUpperCase()).where((c) => c.isNotEmpty).toSet();
    final tfNorm = _normalizeTimeframe(timeframe);

    double tfBoost(String coin) {
      var boost = 0.0;
      for (final t in trades) {
        if ((t['coin'] ?? '').toString().toUpperCase() != coin) continue;
        if (_normalizeTimeframe((t['timeframe'] ?? '').toString()) == tfNorm) boost += 4;
      }
      for (final h in history) {
        if (h['source'] != 'trade_setup') continue;
        if ((h['coin'] ?? '').toString().toUpperCase() != coin) continue;
        boost += 1.5;
      }
      return boost;
    }

    var list = List<OraclePulseOpportunity>.from(base);
    if (watchlistOnly && wl.isNotEmpty) {
      list = list.where((o) => wl.contains(o.coin)).toList();
      if (list.isEmpty) {
        list = base.where((o) => wl.contains(o.coin)).toList();
      }
    }

    list.sort((a, b) {
      final scoreA = a.convictionPct + tfBoost(a.coin);
      final scoreB = b.convictionPct + tfBoost(b.coin);
      return scoreB.compareTo(scoreA);
    });

    if (list.length < 4) {
      final seen = list.map((o) => o.coin).toSet();
      for (final coin in wl) {
        if (seen.contains(coin)) continue;
        list.add(OraclePulseOpportunity(
          coin: coin,
          direction: OraclePulseDirection.long,
          convictionPct: 66,
          whyNow: 'Watchlist priority on $tfNorm — run Trade Setup for a fresh Oracle read.',
          signalTimeframe: timeframe,
        ));
        seen.add(coin);
        if (list.length >= 6) break;
      }
    }

    return list.take(6).toList();
  }

  static String _normalizeTimeframe(String raw) {
    final u = raw.toUpperCase();
    if (u.contains('15')) return '15m';
    if (u.contains('1D') || u == '1D' || u.contains('D')) return '1D';
    if (u.contains('4')) return '4h';
    return '1h';
  }
}

enum LiquidationZoneKind { longLiqRisk, shortSqueeze, neutral }

class LiquidationHeatZone {
  final String coin;
  final LiquidationZoneKind kind;
  final double heat;
  final double change24hPct;
  final int convictionPct;
  final String whyZone;
  final OraclePulseDirection direction;

  const LiquidationHeatZone({
    required this.coin,
    required this.kind,
    required this.heat,
    required this.change24hPct,
    required this.convictionPct,
    required this.whyZone,
    required this.direction,
  });

  String get tradeSetupDirection =>
      direction.isLong ? 'Long Only' : 'Short Only';
}

class OracleVisionSnapshot {
  final List<LiquidationHeatZone> heatZones;
  final List<OraclePulseOpportunity> opportunities;

  const OracleVisionSnapshot({
    required this.heatZones,
    required this.opportunities,
  });
}
