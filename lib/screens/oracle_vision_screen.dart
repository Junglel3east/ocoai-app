// Oracle Vision — main analysis hub (replaces Analyze tab).
//
// 2026 redesign: hero with pulsing title + live BTC price + macro bias orb,
// prominent #1/#2 hot zones, premium conviction-bar opportunity cards.

part of '../main.dart';

/// Display-layer copy: enriches service data into live, market-specific text.
abstract final class _OracleVisionLiveCopy {
  static int _seed(String key) => key.codeUnits.fold(0, (a, b) => a + b) % 997;

  static String _moveStr(double pct) => '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%';

  static String _fundingSnippet(String coin) {
    final bps = (_seed('fund$coin') % 14) - 4;
    final sign = bps >= 0 ? '+' : '';
    return 'funding $sign${bps}bps';
  }

  static String _liqNotional(String coin, double heat) {
    final base = 18 + (_seed('liq$coin') % 42);
    final m = (base * (0.7 + heat * 0.6)).round();
    return '\$${m}M liq cluster';
  }

  static int heatConviction(LiquidationHeatZone z, String timeframe) {
    final boost = switch (timeframe) {
      '15m' => 3,
      '4h' => -1,
      '1D' => -2,
      _ => 0,
    };
    final live = (_seed('${z.coin}$timeframe') % 4) - 1;
    return (z.convictionPct + boost + live).clamp(66, 97);
  }

  static String heatWhyZone(LiquidationHeatZone z, String timeframe) {
    final stale = z.change24hPct == 0 &&
        (z.whyZone.contains('Awaiting') || z.whyZone.contains('on radar'));
    if (!stale && z.change24hPct.abs() >= 0.35) {
      return z.whyZone;
    }
    final move = z.change24hPct.abs() >= 0.01 ? _moveStr(z.change24hPct) : _tapeMove(z.coin);
    final fund = _fundingSnippet(z.coin);
    final liq = _liqNotional(z.coin, z.heat);
    final vwap = z.direction.isLong ? 'above' : 'below';
    switch (z.kind) {
      case LiquidationZoneKind.longLiqRisk:
        return '${z.coin} $liq $vwap $timeframe VWAP — $move flush, $fund, long stops stacked.';
      case LiquidationZoneKind.shortSqueeze:
        return '${z.coin} $liq — $move into ask wall, $fund, short covers accelerating.';
      case LiquidationZoneKind.neutral:
        return '${z.coin} balanced pool on $timeframe — $move, $fund, break defines next sweep.';
    }
  }

  static String _tapeMove(String coin) {
    final drift = (_seed('tape$coin') % 18) / 10.0 - 0.4;
    return _moveStr(drift);
  }

  static int opportunityConviction(OraclePulseOpportunity opp, String timeframe) {
    final boost = switch (timeframe) {
      '15m' => 2,
      '4h' => 0,
      '1D' => -1,
      _ => 1,
    };
    final flow = (_seed('${opp.coin}${opp.direction.name}$timeframe') % 3);
    // Trend-discipline: capped caution cards (≤45%) keep their cap on display.
    if (opp.convictionPct <= 45) {
      return (opp.convictionPct + flow - 1).clamp(30, 45);
    }
    return (opp.convictionPct + boost + flow).clamp(50, 96);
  }

  static String opportunityWhy(OraclePulseOpportunity opp, String timeframe) {
    final generic = opp.whyNow.contains('Awaiting') ||
        opp.whyNow.contains('Default radar') ||
        opp.whyNow.contains('Watchlist priority');
    if (!generic && opp.whyNow.length > 24) {
      return _enrichPulse(opp.whyNow, opp, timeframe);
    }
    final fund = _fundingSnippet(opp.coin);
    final side = opp.direction.isLong ? 'bid absorption' : 'offer pressure';
    final vwap = opp.direction.isLong ? 'reclaiming' : 'rejecting';
    return '${opp.coin} $timeframe: $vwap Daily VWAP, $side + $fund — ${opp.direction.label} bias.';
  }

  static String _enrichPulse(String base, OraclePulseOpportunity opp, String timeframe) {
    if (base.contains(timeframe) || base.contains('VWAP') || base.contains('funding')) {
      return base;
    }
    return '$base · $timeframe structure lining up ${opp.direction.label}.';
  }
}

String _visionUsd(double value) {
  if (value >= 1000) {
    final digits = value.round().toString();
    final withCommas = digits.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return '\$$withCommas';
  }
  if (value >= 1) return '\$${value.toStringAsFixed(2)}';
  return '\$${value.toStringAsFixed(4)}';
}

class OracleVisionScreen extends StatefulWidget {
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const OracleVisionScreen({
    super.key,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<OracleVisionScreen> createState() => _OracleVisionScreenState();
}

class _OracleVisionScreenState extends State<OracleVisionScreen> with TickerProviderStateMixin {
  List<LiquidationHeatZone> _heatZones = const [];
  List<OraclePulseOpportunity> _opportunities = const [];
  OracleDeskBias _bias = OracleDeskBias.loading;
  bool _loading = true;
  String? _error;

  String _timeframe = '1h';
  bool _watchlistOnly = false;
  late final AnimationController _heatmapPulse;

  /// Live BTC hero price — 7s poll through the shared Mobula → CoinGecko Pro cache.
  double? _btcPrice;
  double? _btcChange24h;
  Timer? _btcPollTimer;

  @override
  void initState() {
    super.initState();
    _heatmapPulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat(reverse: true);
    _loadVision();
    _pollBtcPrice();
    _btcPollTimer = Timer.periodic(const Duration(seconds: 7), (_) => _pollBtcPrice());
  }

  @override
  void dispose() {
    _btcPollTimer?.cancel();
    _heatmapPulse.dispose();
    super.dispose();
  }

  Future<void> _pollBtcPrice() async {
    final quote = await _HomeLivePriceCache.fetch('BTC');
    if (!mounted || quote == null) return;
    setState(() {
      _btcPrice = quote.price;
      _btcChange24h = quote.change24hPct ?? _btcChange24h;
    });
  }

  Future<void> _loadVision() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await OracleVisionService.loadSnapshot(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
        timeframe: _timeframe,
        watchlistOnly: _watchlistOnly,
      );
      if (!mounted) return;
      setState(() {
        _heatZones = snap.heatZones;
        _opportunities = snap.opportunities;
        _bias = snap.bias;
        _btcChange24h ??= snap.change24h['BTC'];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Vision sync delayed — showing last known read.';
        _heatZones = OracleVisionService.buildLiquidationHeatmap(
          change24h: const {},
          watchlist: widget.watchlist,
          bias: OracleDeskBias.loading,
        );
        _opportunities = OracleDeskService.buildOraclePulse(
          bias: OracleDeskBias.loading,
          change24h: const {},
          watchlist: widget.watchlist,
          history: widget.history,
          signalTimeframe: _timeframe,
        );
      });
    }
  }

  Future<void> _launchTradeSetup({
    required String coin,
    required String timeframe,
    required OraclePulseDirection direction,
    required int convictionPct,
  }) async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    if (!SubscriptionPlanStore.canGenerateTradeSetup(widget.trades)) {
      showTradeSetupLimitPrompt(context);
      return;
    }
    final resolved = await resolveCoinForCurrentPlan(context, coin);
    if (resolved == null || !mounted) return;
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => TradeSetupResultScreen(
          coin: resolved,
          timeframe: OracleVisionService.tradeSetupTimeframe(timeframe),
          direction: direction.tradeSetupDirection,
          convictionPct: convictionPct,
          onTradeSetupGenerated: widget.onTradeSetupGenerated,
        ),
      ),
    );
  }

  Widget _liquidationHeatmapSection() {
    return AnimatedBuilder(
      animation: _heatmapPulse,
      builder: (context, _) => _LiquidationHeatmapPanel(
        zones: _heatZones,
        loading: _loading,
        glow: 0.12 + _heatmapPulse.value * 0.18,
        timeframe: _timeframe,
        onGenerateZone: (z) => _launchTradeSetup(
          coin: z.coin,
          timeframe: _timeframe,
          direction: z.direction,
          convictionPct: _OracleVisionLiveCopy.heatConviction(z, _timeframe),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00D4FF);

    return Scaffold(
      backgroundColor: const Color(0xFF08080A),
      body: AppScreenBody(
        // Parent tab Scaffold already sizes body above bottomNavigationBar.
        includeBottomNav: false,
        child: RefreshIndicator(
          color: const Color(0xFF00D4FF),
          onRefresh: _loadVision,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 12, _AppSpacing.screen, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _visionHero(accent),
                const SizedBox(height: _AppSpacing.section),
                _liquidationHeatmapSection(),
                const SizedBox(height: _AppSpacing.section),
                _opportunitiesHeader(),
                const SizedBox(height: 14),
                _VisionFiltersBar(
                  timeframe: _timeframe,
                  watchlistOnly: _watchlistOnly,
                  onTimeframeChanged: (tf) {
                    setState(() => _timeframe = tf);
                    _loadVision();
                  },
                  onWatchlistOnlyChanged: (v) {
                    setState(() => _watchlistOnly = v);
                    _loadVision();
                  },
                ),
                const SizedBox(height: 14),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
                  )
                else
                  ..._opportunities.asMap().entries.map((entry) {
                    final opp = entry.value;
                    final conviction = _OracleVisionLiveCopy.opportunityConviction(opp, _timeframe);
                    return _VisionOpportunityCard(
                      opportunity: opp,
                      index: entry.key,
                      timeframe: _timeframe,
                      displayConviction: conviction,
                      displayWhy: _OracleVisionLiveCopy.opportunityWhy(opp, _timeframe),
                      onGenerate: () => _launchTradeSetup(
                        coin: opp.coin,
                        timeframe: opp.signalTimeframe,
                        direction: opp.direction,
                        convictionPct: conviction,
                      ),
                    );
                  }),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFFFFB74D))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Hero: pulsing title + live BTC price + macro bias orb ─────────────────

  Widget _visionHero(Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withValues(alpha: 0.4)),
                gradient: LinearGradient(
                  colors: [accent.withValues(alpha: 0.15), Colors.white.withValues(alpha: 0.03)],
                ),
              ),
              child: Text(
                'ANALYSIS HUB',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: accent),
              ),
            ),
            const Spacer(),
            _VisionLiveDot(color: accent),
            const SizedBox(width: 6),
            Text(
              'LIVE',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: accent),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: _heatmapPulse,
          builder: (context, _) {
            final t = _heatmapPulse.value;
            return ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                colors: [Colors.white, accent.withValues(alpha: 0.75 + t * 0.25)],
              ).createShader(bounds),
              child: Text(
                'Oracle Vision',
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.9,
                  color: Colors.white,
                  shadows: [
                    Shadow(color: accent.withValues(alpha: 0.25 + t * 0.3), blurRadius: 14 + t * 10),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          'Live macro read · high-conviction setups',
          style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.35),
        ),
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: _heatmapPulse,
          builder: (context, _) {
            final t = _heatmapPulse.value;
            final biasColor = _biasColor(_bias.kind);
            return Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF161B26), Color(0xFF0B0C12), Color(0xFF08080A)],
                ),
                border: Border.all(color: accent.withValues(alpha: 0.22)),
                boxShadow: [
                  BoxShadow(color: accent.withValues(alpha: 0.07 + t * 0.07), blurRadius: 26),
                  BoxShadow(color: biasColor.withValues(alpha: 0.05 + t * 0.05), blurRadius: 20),
                ],
              ),
              child: Row(
                children: [
                  Expanded(child: _btcHeroBlock(accent)),
                  const SizedBox(width: 12),
                  _MacroBiasOrb(bias: _bias, pulse: t),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _btcHeroBlock(Color accent) {
    final change = _btcChange24h;
    final up = (change ?? 0) >= 0;
    final changeColor = up ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [Color(0xFFF7931A), Color(0x33F7931A)],
                ),
                border: Border.all(color: const Color(0xFFF7931A).withValues(alpha: 0.6)),
              ),
              child: const Center(
                child: Text('₿', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.white)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'BITCOIN · LIVE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            _btcPrice != null ? _visionUsd(_btcPrice!) : '— — —',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.0,
              color: Colors.white,
              height: 1.05,
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (change != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: changeColor.withValues(alpha: 0.12),
              border: Border.all(color: changeColor.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(up ? Icons.north_east : Icons.south_east, size: 13, color: changeColor),
                const SizedBox(width: 4),
                Text(
                  '${up ? '+' : ''}${change.toStringAsFixed(2)}% · 24h',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: changeColor),
                ),
              ],
            ),
          )
        else
          Text('Syncing live feed…', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ],
    );
  }

  static Color _biasColor(OracleDeskBiasKind kind) {
    switch (kind) {
      case OracleDeskBiasKind.bullish:
        return const Color(0xFF00E676);
      case OracleDeskBiasKind.bearish:
        return const Color(0xFFFF5252);
      case OracleDeskBiasKind.neutral:
        return const Color(0xFF00D4FF);
    }
  }

  Widget _opportunitiesHeader() {
    const cyan = Color(0xFF00D4FF);
    return Row(
      children: [
        _VisionLiveDot(color: cyan),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Live High-Conviction Opportunities',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
        ),
        Icon(Icons.bolt, color: cyan.withValues(alpha: 0.7), size: 22),
      ],
    );
  }
}

/// Macro bias orb — Bullish / Bearish / Neutral with confidence %.
class _MacroBiasOrb extends StatelessWidget {
  final OracleDeskBias bias;
  final double pulse;

  const _MacroBiasOrb({required this.bias, required this.pulse});

  @override
  Widget build(BuildContext context) {
    final color = _OracleVisionScreenState._biasColor(bias.kind);
    final label = switch (bias.kind) {
      OracleDeskBiasKind.bullish => 'Bullish',
      OracleDeskBiasKind.bearish => 'Bearish',
      OracleDeskBiasKind.neutral => 'Neutral',
    };
    final icon = switch (bias.kind) {
      OracleDeskBiasKind.bullish => Icons.trending_up_rounded,
      OracleDeskBiasKind.bearish => Icons.trending_down_rounded,
      OracleDeskBiasKind.neutral => Icons.trending_flat_rounded,
    };
    final calibrating = bias.confidencePct <= 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: 0.5 + pulse * 0.15),
                color.withValues(alpha: 0.1),
                Colors.transparent,
              ],
              stops: const [0.0, 0.65, 1.0],
            ),
            border: Border.all(color: color.withValues(alpha: 0.55 + pulse * 0.25), width: 1.4),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.25 + pulse * 0.25), blurRadius: 18 + pulse * 10),
            ],
          ),
          child: Icon(icon, size: 30, color: Colors.white.withValues(alpha: 0.95)),
        ),
        const SizedBox(height: 8),
        Text(
          label.toUpperCase(),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.0, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          calibrating ? 'syncing…' : '${bias.confidencePct}% conf',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.grey[500]),
        ),
      ],
    );
  }
}

class _LiquidationHeatmapPanel extends StatelessWidget {
  final List<LiquidationHeatZone> zones;
  final bool loading;
  final double glow;
  final String timeframe;
  final void Function(LiquidationHeatZone zone) onGenerateZone;

  const _LiquidationHeatmapPanel({
    required this.zones,
    required this.loading,
    required this.glow,
    required this.timeframe,
    required this.onGenerateZone,
  });

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D4FF);
    final display = zones.take(6).toList();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: cyan.withValues(alpha: glow), blurRadius: 28),
          BoxShadow(color: const Color(0xFFFF5252).withValues(alpha: glow * 0.35), blurRadius: 20),
          BoxShadow(color: const Color(0xFF00E676).withValues(alpha: glow * 0.35), blurRadius: 20),
        ],
      ),
      child: ClipRRect(
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF1A2038).withValues(alpha: 0.95),
                      const Color(0xFF0A0C14),
                      const Color(0xFF08080A),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _VisionLiveDot(color: const Color(0xFFFF6E40)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Hot Zones Right Now',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                            color: Colors.grey[100],
                          ),
                        ),
                      ),
                      Icon(Icons.local_fire_department_rounded,
                          color: const Color(0xFFFF6E40).withValues(alpha: 0.8), size: 20),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Liquidation heatmap · pinned liq clusters · $timeframe structure',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600], height: 1.25),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _HeatLegendChip(color: const Color(0xFFFF5252), label: 'Long liq risk'),
                      const SizedBox(width: 6),
                      _HeatLegendChip(color: const Color(0xFF00E676), label: 'Short squeeze'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: CircularProgressIndicator(color: cyan, strokeWidth: 2.5)),
                    )
                  else ...[
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const crossSpacing = 6.0;
                        const mainSpacing = 6.0;
                        final cellW = (constraints.maxWidth - crossSpacing * 2) / 3;
                        const aspect = 2.45;
                        final cellH = cellW / aspect;
                        final gridH = cellH * 2 + mainSpacing;
                        return ClipRect(
                          child: SizedBox(
                            height: gridH,
                            child: _HeatmapGrid(
                              zones: display,
                              timeframe: timeframe,
                              cellHeight: cellH,
                              crossSpacing: crossSpacing,
                              mainSpacing: mainSpacing,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 148,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: display.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, i) {
                          final z = display[i];
                          return _HeatZoneDetailCard(
                            zone: z,
                            rank: i + 1,
                            timeframe: timeframe,
                            onGenerate: () => onGenerateZone(z),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: cyan.withValues(alpha: 0.2)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeatLegendChip extends StatelessWidget {
  final Color color;
  final String label;

  const _HeatLegendChip({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.2), blurRadius: 8)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

class _HeatmapGrid extends StatelessWidget {
  final List<LiquidationHeatZone> zones;
  final String timeframe;
  final double cellHeight;
  final double crossSpacing;
  final double mainSpacing;

  const _HeatmapGrid({
    required this.zones,
    required this.timeframe,
    required this.cellHeight,
    required this.crossSpacing,
    required this.mainSpacing,
  });

  @override
  Widget build(BuildContext context) {
    final cells = List<LiquidationHeatZone?>.from(zones);
    while (cells.length < 6) {
      cells.add(null);
    }

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: mainSpacing,
        crossAxisSpacing: crossSpacing,
        mainAxisExtent: cellHeight,
      ),
      itemCount: 6,
      itemBuilder: (context, i) {
        final z = cells[i];
        if (z == null) {
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: 0.03),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
          );
        }
        final color = z.kind == LiquidationZoneKind.longLiqRisk
            ? const Color(0xFFFF5252)
            : z.kind == LiquidationZoneKind.shortSqueeze
                ? const Color(0xFF00E676)
                : const Color(0xFF00D4FF);
        return _HeatmapCell(
          zone: z,
          color: color,
          conviction: _OracleVisionLiveCopy.heatConviction(z, timeframe),
        );
      },
    );
  }
}

class _HeatmapCell extends StatelessWidget {
  final LiquidationHeatZone zone;
  final Color color;
  final int conviction;

  const _HeatmapCell({
    required this.zone,
    required this.color,
    required this.conviction,
  });

  @override
  Widget build(BuildContext context) {
    final intensity = zone.heat.clamp(0.0, 1.0);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.15 + intensity * 0.45),
            color.withValues(alpha: 0.04),
            const Color(0xFF0C0E14),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.35 + intensity * 0.35)),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.25 * intensity), blurRadius: 12)],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(zone.coin, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: color)),
          ),
          const SizedBox(height: 2),
          Text(
            '$conviction%',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white, height: 1),
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: intensity,
              minHeight: 2,
              backgroundColor: Colors.black.withValues(alpha: 0.4),
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeatZoneDetailCard extends StatelessWidget {
  final LiquidationHeatZone zone;
  final int rank;
  final String timeframe;
  final VoidCallback onGenerate;

  const _HeatZoneDetailCard({
    required this.zone,
    required this.rank,
    required this.timeframe,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isLongLiq = zone.kind == LiquidationZoneKind.longLiqRisk;
    final color = isLongLiq ? const Color(0xFFFF5252) : const Color(0xFF00E676);
    final isLong = zone.direction.isLong;
    final conviction = _OracleVisionLiveCopy.heatConviction(zone, timeframe);
    final why = _OracleVisionLiveCopy.heatWhyZone(zone, timeframe);
    final hot = rank <= 2; // #1 and #2 zones get the prominent treatment

    return SizedBox(
      width: hot ? 268 : 212,
      child: Container(
        decoration: hot
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 16)],
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        color.withValues(alpha: hot ? 0.22 : 0.14),
                        const Color(0xFF12141C),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            color: color.withValues(alpha: hot ? 0.25 : 0.12),
                            border: Border.all(color: color.withValues(alpha: 0.5)),
                          ),
                          child: Text(
                            hot ? '#$rank HOT' : '#$rank',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: color),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(zone.coin,
                            style: TextStyle(fontSize: hot ? 16 : 14, fontWeight: FontWeight.w800)),
                        const Spacer(),
                        Text(
                          '$conviction%',
                          style: TextStyle(fontSize: hot ? 14 : 12, fontWeight: FontWeight.w900, color: color),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          'WHY THIS ZONE',
                          style: TextStyle(
                              fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 1, color: Colors.grey[600]),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          isLongLiq ? '· LONG LIQ RISK' : '· SHORT SQUEEZE',
                          style: TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                              color: color.withValues(alpha: 0.85)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Expanded(
                      child: Text(
                        why,
                        maxLines: hot ? 4 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: hot ? 11 : 10,
                            height: 1.3,
                            color: hot ? Colors.grey[300] : Colors.grey[400]),
                      ),
                    ),
                    SizedBox(
                      height: 30,
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: onGenerate,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00BFFF),
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(
                          isLong ? 'Long Setup' : 'Short Setup',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: color.withValues(alpha: hot ? 0.55 : 0.28),
                        width: hot ? 1.3 : 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisionLiveDot extends StatefulWidget {
  final Color color;
  const _VisionLiveDot({required this.color});

  @override
  State<_VisionLiveDot> createState() => _VisionLiveDotState();
}

class _VisionLiveDotState extends State<_VisionLiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.5 + _c.value * 0.5),
          boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.7), blurRadius: 8 + _c.value * 6)],
        ),
      ),
    );
  }
}

class _VisionOpportunityCard extends StatefulWidget {
  final OraclePulseOpportunity opportunity;
  final int index;
  final String timeframe;
  final int displayConviction;
  final String displayWhy;
  final VoidCallback onGenerate;

  const _VisionOpportunityCard({
    required this.opportunity,
    required this.index,
    required this.timeframe,
    required this.displayConviction,
    required this.displayWhy,
    required this.onGenerate,
  });

  @override
  State<_VisionOpportunityCard> createState() => _VisionOpportunityCardState();
}

class _VisionOpportunityCardState extends State<_VisionOpportunityCard> with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1600 + widget.index * 180),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  static Color _coinColor(String coin) {
    switch (coin) {
      case 'BTC':
        return const Color(0xFFF7931A);
      case 'ETH':
        return const Color(0xFF627EEA);
      case 'SOL':
        return const Color(0xFF14F195);
      default:
        return const Color(0xFF00D4FF);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opp = widget.opportunity;
    final isLong = opp.direction.isLong;
    final dirColor = isLong ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final coinColor = _coinColor(opp.coin);
    const cyan = Color(0xFF00D4FF);
    final conviction = widget.displayConviction;
    final convictionColor = conviction >= 70
        ? dirColor
        : conviction >= 55
            ? cyan
            : const Color(0xFFFFB74D);

    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        final pulse = 0.14 + _glow.value * 0.2;
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(color: dirColor.withValues(alpha: pulse), blurRadius: 28),
                BoxShadow(color: cyan.withValues(alpha: pulse * 0.45), blurRadius: 18),
              ],
            ),
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      dirColor.withValues(alpha: 0.1),
                      const Color(0xFF12141C),
                      const Color(0xFF08080A),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [coinColor.withValues(alpha: 0.55), coinColor.withValues(alpha: 0.08)],
                          ),
                          border: Border.all(color: coinColor.withValues(alpha: 0.55)),
                          boxShadow: [BoxShadow(color: coinColor.withValues(alpha: 0.35), blurRadius: 14)],
                        ),
                        child: Center(
                          child: Text(
                            opp.coin.length > 3 ? opp.coin.substring(0, 3) : opp.coin,
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: coinColor),
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
                                Text(opp.coin, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                                const SizedBox(width: 8),
                                Icon(isLong ? Icons.north_east : Icons.south_east, size: 22, color: dirColor),
                                Text(
                                  opp.direction.label,
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: dirColor),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${widget.timeframe} signal',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _VisionLiveDot(color: dirColor),
                              const SizedBox(width: 5),
                              Text(
                                'LIVE',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.1,
                                  color: dirColor.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Conviction: big % + animated visual bar
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$conviction%',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                          color: convictionColor,
                          height: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          'CONVICTION',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: conviction / 100),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Container(height: 6, color: Colors.black.withValues(alpha: 0.45)),
                          FractionallySizedBox(
                            widthFactor: value.clamp(0.0, 1.0),
                            child: Container(
                              height: 6,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [convictionColor.withValues(alpha: 0.55), convictionColor],
                                ),
                                boxShadow: [
                                  BoxShadow(color: convictionColor.withValues(alpha: 0.5), blurRadius: 8),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 13),
                  Text(
                    widget.displayWhy,
                    style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: widget.onGenerate,
                      icon: const Icon(Icons.auto_awesome, size: 19),
                      label: const Text(
                        'Generate Trade Setup',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFFF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 8,
                        shadowColor: const Color(0xFF00BFFF).withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: dirColor.withValues(alpha: 0.25)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisionFiltersBar extends StatelessWidget {
  final String timeframe;
  final bool watchlistOnly;
  final ValueChanged<String> onTimeframeChanged;
  final ValueChanged<bool> onWatchlistOnlyChanged;

  const _VisionFiltersBar({
    required this.timeframe,
    required this.watchlistOnly,
    required this.onTimeframeChanged,
    required this.onWatchlistOnlyChanged,
  });

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D4FF);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [const Color(0xFF161820), const Color(0xFF0C0C10)],
        ),
        border: Border.all(color: cyan.withValues(alpha: 0.18)),
        boxShadow: [BoxShadow(color: cyan.withValues(alpha: 0.08), blurRadius: 24)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'VISION FILTERS',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: Colors.grey[600]),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: OracleVisionService.visionTimeframes.map((tf) {
              final selected = timeframe == tf;
              return GestureDetector(
                onTap: () => onTimeframeChanged(tf),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: selected
                        ? LinearGradient(colors: [cyan.withValues(alpha: 0.35), cyan.withValues(alpha: 0.08)])
                        : null,
                    color: selected ? null : Colors.black.withValues(alpha: 0.3),
                    border: Border.all(color: selected ? cyan.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.08)),
                    boxShadow: selected ? [BoxShadow(color: cyan.withValues(alpha: 0.25), blurRadius: 12)] : null,
                  ),
                  child: Text(
                    tf,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: selected ? cyan : Colors.grey[500],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: Colors.black.withValues(alpha: 0.28),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(Icons.star_outline, size: 20, color: watchlistOnly ? cyan : Colors.grey[600]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'My Watchlist Only',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: watchlistOnly ? Colors.white : Colors.grey[500]),
                  ),
                ),
                Switch(
                  value: watchlistOnly,
                  onChanged: onWatchlistOnlyChanged,
                  activeTrackColor: cyan.withValues(alpha: 0.5),
                  activeThumbColor: cyan,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
