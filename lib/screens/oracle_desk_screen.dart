// Oracle Desk — personal trading command center (replaces Portfolio tab).

part of '../main.dart';

class OracleDeskScreen extends StatefulWidget {
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const OracleDeskScreen({
    super.key,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<OracleDeskScreen> createState() => _OracleDeskScreenState();
}

class _OracleDeskScreenState extends State<OracleDeskScreen> with SingleTickerProviderStateMixin {
  OracleDeskBias _bias = OracleDeskBias.loading;
  bool _biasLoading = true;
  String? _biasError;
  List<OraclePulseOpportunity> _oraclePulse = const [];
  late final AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
    _loadBias();
  }

  @override
  void dispose() {
    _radarController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OracleDeskScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.watchlist != widget.watchlist) {
      _loadBias();
    }
  }

  Future<void> _loadBias() async {
    setState(() {
      _biasLoading = true;
      _biasError = null;
    });
    try {
      final bundle = await OracleDeskService.fetchDeskBundle(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
      );
      final pulses = OracleDeskService.buildOraclePulse(
        bias: bundle.bias,
        change24h: bundle.change24h,
        watchlist: widget.watchlist,
        history: widget.history,
      );
      if (mounted) {
        setState(() {
          _bias = bundle.bias;
          _oraclePulse = pulses;
          _biasLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        final fallback = OracleDeskBias(
          kind: OracleDeskBiasKind.neutral,
          confidencePct: 48,
          title: 'Neutral / Range-Bound',
          reasoning:
              'Could not refresh live quotes. Oracle Pulse is using watchlist defaults until sync recovers.',
          recommendedCoins: widget.watchlist.take(4).map((c) => c.toUpperCase()).toList(),
          avgMomentum: 0,
        );
        setState(() {
          _biasError = 'Market sync delayed — showing cached desk metrics.';
          _biasLoading = false;
          _bias = fallback;
          _oraclePulse = OracleDeskService.buildOraclePulse(
            bias: fallback,
            change24h: const {},
            watchlist: widget.watchlist,
            history: widget.history,
          );
        });
      }
    }
  }

  Future<void> _onRefresh() async {
    await _loadBias();
  }

  Color _biasColor(OracleDeskBiasKind kind) {
    switch (kind) {
      case OracleDeskBiasKind.bullish:
        return const Color(0xFF00E676);
      case OracleDeskBiasKind.bearish:
        return const Color(0xFFFF5252);
      case OracleDeskBiasKind.neutral:
        return const Color(0xFF00BFFF);
    }
  }

  String _formatUsd(double v) {
    final sign = v >= 0 ? '+' : '-';
    final abs = v.abs();
    if (abs >= 1000) return '$sign\$${(abs / 1000).toStringAsFixed(1)}k';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final perf = OracleDeskService.computePerformance(
      trades: widget.trades,
      watchlist: widget.watchlist,
    );
    final accent = _biasColor(_bias.kind);

    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      body: AppScreenBody(
        // Tab Scaffold already sizes body above bottomNavigationBar — no extra nav clearance.
        includeBottomNav: false,
        child: RefreshIndicator(
          color: const Color(0xFF00BFFF),
          onRefresh: _onRefresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: EdgeInsets.fromLTRB(_AppSpacing.screen, 8, _AppSpacing.screen, 16 + bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _deskHeader(accent),
                const SizedBox(height: _AppSpacing.section),
                _biasSection(accent, perf),
                const SizedBox(height: _AppSpacing.section),
                _OraclePulseSection(
                  opportunities: _oraclePulse,
                  radarAnimation: _radarController,
                  onGenerateSetup: _openTradeSetupForCoin,
                ),
                const SizedBox(height: _AppSpacing.section),
                _EdgeBreakdownPanel(edge: perf.edge, streak: perf.streak),
                const SizedBox(height: _AppSpacing.section),
                _PerformanceSnapshotPanel(perf: perf, formatUsd: _formatUsd),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _deskHeader(Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withValues(alpha: 0.35)),
                gradient: LinearGradient(
                  colors: [
                    accent.withValues(alpha: 0.12),
                    Colors.white.withValues(alpha: 0.04),
                  ],
                ),
              ),
              child: Text(
                'COMMAND CENTER',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: accent,
                ),
              ),
            ),
            const Spacer(),
            Icon(Icons.auto_graph_rounded, color: accent.withValues(alpha: 0.7), size: 22),
          ],
        ),
        const SizedBox(height: 10),
        ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [Colors.white, accent.withValues(alpha: 0.85)],
          ).createShader(bounds),
          child: const Text(
            'Oracle Desk',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Your Personal Trading Command Center',
          style: TextStyle(fontSize: 14, color: Colors.grey[500], height: 1.35),
        ),
      ],
    );
  }

  Widget _biasSection(Color accent, OracleDeskPerformance perf) {
    return _OracleDeskGlassCard(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Today's Oracle Bias For You",
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: Colors.grey[400],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _BiasOrb(
                kind: _bias.kind,
                confidencePct: _biasLoading ? null : _bias.confidencePct,
                accent: accent,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_biasLoading)
                      const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                      )
                    else
                      Text(
                        _bias.title,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                    if (_biasError != null) ...[
                      const SizedBox(height: 6),
                      Text(_biasError!, style: const TextStyle(fontSize: 11, color: Color(0xFFFFB74D))),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      _bias.reasoning,
                      style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'Recommended for you today',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey[500]),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _bias.recommendedCoins.map((coin) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    colors: [
                      accent.withValues(alpha: 0.22),
                      const Color(0xFF1A1A22),
                    ],
                  ),
                  border: Border.all(color: accent.withValues(alpha: 0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.12),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Text(
                      coin,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _openTradeSetupForCoin(String coin) {
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => TradeSetupScreen(
          coin: coin,
          trades: widget.trades,
          onTradeSetupGenerated: widget.onTradeSetupGenerated,
        ),
      ),
    );
  }

}

class _OracleDeskGlassCard extends StatelessWidget {
  final Widget child;
  final Color accent;

  const _OracleDeskGlassCard({required this.child, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1A1A22).withValues(alpha: 0.95),
            const Color(0xFF0F0F14),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.08),
            blurRadius: 28,
            spreadRadius: 0,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _BiasOrb extends StatelessWidget {
  final OracleDeskBiasKind kind;
  final int? confidencePct;
  final Color accent;

  const _BiasOrb({
    required this.kind,
    required this.confidencePct,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: accent.withValues(alpha: 0.55), blurRadius: 28, spreadRadius: 2),
                BoxShadow(color: accent.withValues(alpha: 0.2), blurRadius: 48, spreadRadius: 8),
              ],
            ),
          ),
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accent.withValues(alpha: 0.9),
                  accent.withValues(alpha: 0.35),
                  const Color(0xFF0A0A0C),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (confidencePct != null) ...[
                  Text(
                    '$confidencePct%',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1,
                    ),
                  ),
                  Text(
                    'conf.',
                    style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.75)),
                  ),
                ] else
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Performance Snapshot + Edge Breakdown ─────────────────────────────────

class _PerformanceSnapshotPanel extends StatefulWidget {
  final OracleDeskPerformance perf;
  final String Function(double) formatUsd;

  const _PerformanceSnapshotPanel({required this.perf, required this.formatUsd});

  @override
  State<_PerformanceSnapshotPanel> createState() => _PerformanceSnapshotPanelState();
}

class _PerformanceSnapshotPanelState extends State<_PerformanceSnapshotPanel> {
  int _equityTab = 0;

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D4FF);
    const green = Color(0xFF00E676);
    final perf = widget.perf;
    final series = _equityTab == 0 ? perf.equity7d : perf.equity30d;
    final chartColor = _equityTab == 0 ? green : cyan;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: cyan.withValues(alpha: 0.16), blurRadius: 36),
          BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 24, offset: const Offset(0, 12)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF1E2438).withValues(alpha: 0.88),
                      const Color(0xFF0A0C12),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Performance Snapshot',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                  ),
                  const SizedBox(height: 18),
                  _EquityTabBar(
                    selected: _equityTab,
                    onSelect: (i) => setState(() => _equityTab = i),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    height: 132,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.black.withValues(alpha: 0.32),
                      border: Border.all(color: chartColor.withValues(alpha: 0.2)),
                      boxShadow: [
                        BoxShadow(color: chartColor.withValues(alpha: 0.12), blurRadius: 24),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CustomPaint(
                        painter: _GlowEquityPainter(series: series, color: chartColor),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: _GlowingMetricCard(
                          label: 'Win Rate',
                          value: perf.closedCount == 0 ? '—' : '${perf.winRatePct.toStringAsFixed(0)}%',
                          accent: green,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlowingMetricCard(
                          label: 'Avg R:R',
                          value: perf.closedCount == 0 ? '—' : perf.avgRiskReward.toStringAsFixed(2),
                          accent: cyan,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _GlowingMetricCard(
                          label: 'Profit Factor',
                          value: perf.closedCount == 0 ? '—' : perf.profitFactor.toStringAsFixed(2),
                          accent: const Color(0xFF7C4DFF),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlowingMetricCard(
                          label: 'AI Alpha Score',
                          value: widget.formatUsd(perf.totalAiAlphaUsd),
                          accent: green,
                          large: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
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

class _EquityTabBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;

  const _EquityTabBar({required this.selected, required this.onSelect});

  Widget _tab(String label, int index) {
    const cyan = Color(0xFF00D4FF);
    final active = selected == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => onSelect(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: active
                ? LinearGradient(colors: [cyan.withValues(alpha: 0.35), cyan.withValues(alpha: 0.08)])
                : null,
            boxShadow: active ? [BoxShadow(color: cyan.withValues(alpha: 0.25), blurRadius: 12)] : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: active ? cyan : Colors.grey[600],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.35),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          _tab('7D', 0),
          _tab('30D', 1),
        ],
      ),
    );
  }
}

class _GlowingMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  final Color accent;
  final IconData? icon;
  final bool large;

  const _GlowingMetricCard({
    required this.label,
    required this.value,
    required this.accent,
    this.subtitle,
    this.icon,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14, large ? 16 : 14, 14, large ? 16 : 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.14),
            const Color(0xFF101218),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.1), blurRadius: 16)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: Colors.grey[600],
                ),
              ),
              if (icon != null) ...[
                const Spacer(),
                Icon(icon, size: 14, color: accent.withValues(alpha: 0.85)),
              ],
            ],
          ),
          SizedBox(height: large ? 10 : 8),
          Text(
            value,
            style: TextStyle(
              fontSize: large ? 22 : 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
              color: accent,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: accent.withValues(alpha: 0.9))),
          ],
        ],
      ),
    );
  }
}

class _EdgeBreakdownPanel extends StatefulWidget {
  final OracleDeskEdgeBreakdown edge;
  final OracleDeskStreak streak;

  const _EdgeBreakdownPanel({required this.edge, required this.streak});

  @override
  State<_EdgeBreakdownPanel> createState() => _EdgeBreakdownPanelState();
}

class _EdgeBreakdownPanelState extends State<_EdgeBreakdownPanel> {
  int _coinPeriod = 1; // 0 = week, 1 = month

  static Color _coinAccent(String coin) {
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
    final edge = widget.edge;
    final streak = widget.streak;
    const cyan = Color(0xFF00D4FF);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: const Color(0xFF7C4DFF).withValues(alpha: 0.1), blurRadius: 28),
          BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [const Color(0xFF161820), const Color(0xFF0A0A0E)],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.hub_outlined, size: 20, color: cyan.withValues(alpha: 0.8)),
                      const SizedBox(width: 10),
                      const Text(
                        'Edge Breakdown',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your edge by setup history',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600], height: 1.35),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Text(
                        'BEST PERFORMING COINS',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: Colors.grey[600]),
                      ),
                      const Spacer(),
                      _EdgePeriodChip(
                        label: '7D',
                        selected: _coinPeriod == 0,
                        onTap: () => setState(() => _coinPeriod = 0),
                      ),
                      const SizedBox(width: 6),
                      _EdgePeriodChip(
                        label: '30D',
                        selected: _coinPeriod == 1,
                        onTap: () => setState(() => _coinPeriod = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...edge.topCoins.map((c) {
                    final accent = _coinAccent(c.coin);
                    final edgeVal = _coinPeriod == 0 ? c.edgePctWeek : c.edgePctMonth;
                    final hasData = _coinPeriod == 0 ? c.hasWeekData : c.hasMonthData;
                    final bar = (edgeVal.abs() / 50).clamp(0.08, 1.0);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(alpha: 0.15),
                              border: Border.all(color: accent.withValues(alpha: 0.4)),
                            ),
                            child: Center(
                              child: Text(
                                c.coin.length > 3 ? c.coin.substring(0, 3) : c.coin,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: accent),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(c.coin, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                                    const Spacer(),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          hasData
                                              ? '${edgeVal >= 0 ? '+' : ''}${edgeVal.toStringAsFixed(0)}% edge'
                                              : 'Building data',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: edgeVal >= 0 ? const Color(0xFF00E676) : const Color(0xFFFF5252),
                                          ),
                                        ),
                                        if (c.samples > 0 && c.edgePctWeek != 0 && c.edgePctMonth != 0)
                                          Text(
                                            '7D ${c.edgePctWeek >= 0 ? '+' : ''}${c.edgePctWeek.toStringAsFixed(0)}% · 30D ${c.edgePctMonth >= 0 ? '+' : ''}${c.edgePctMonth.toStringAsFixed(0)}%',
                                            style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: bar,
                                    minHeight: 4,
                                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                                    color: accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 18),
                  Text(
                    'BEST TIMEFRAMES FOR YOUR STYLE',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: edge.timeframes.take(3).map((tf) {
                      final pct = tf.samples > 0 ? tf.winRatePct : 0.0;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cyan.withValues(alpha: 0.25)),
                          gradient: LinearGradient(
                            colors: [cyan.withValues(alpha: 0.12), Colors.transparent],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tf.timeframe, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                            Text(
                              tf.samples > 0 ? '${pct.toStringAsFixed(0)}% WR' : 'No closes',
                              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _DirectionEdgeCard(
                          label: 'Long',
                          winRate: edge.longWinRatePct,
                          samples: edge.longSamples,
                          color: const Color(0xFF00E676),
                          icon: Icons.north_east,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _DirectionEdgeCard(
                          label: 'Short',
                          winRate: edge.shortWinRatePct,
                          samples: edge.shortSamples,
                          color: const Color(0xFFFF5252),
                          icon: Icons.south_east,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _StreakBanner(streak: streak),
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: cyan.withValues(alpha: 0.14)),
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

class _EdgePeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _EdgePeriodChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D4FF);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected ? cyan.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(color: selected ? cyan.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: selected ? cyan : Colors.grey[600],
          ),
        ),
      ),
    );
  }
}

class _DirectionEdgeCard extends StatelessWidget {
  final String label;
  final double winRate;
  final int samples;
  final Color color;
  final IconData icon;

  const _DirectionEdgeCard({
    required this.label,
    required this.winRate,
    required this.samples,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            samples > 0 ? '${winRate.toStringAsFixed(0)}%' : '—',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          Text(
            samples > 0 ? '$samples trades' : 'No data',
            style: TextStyle(fontSize: 10, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

class _StreakBanner extends StatelessWidget {
  final OracleDeskStreak streak;

  const _StreakBanner({required this.streak});

  @override
  Widget build(BuildContext context) {
    final isHot = streak.kind == OracleDeskStreakKind.hot;
    final isCold = streak.kind == OracleDeskStreakKind.cold;
    final color = isHot
        ? const Color(0xFF00E676)
        : isCold
            ? const Color(0xFF00BFFF)
            : Colors.grey;
    final title = isHot ? 'Hot Streak' : isCold ? 'Cold Streak' : 'Streak';
    final icon = isHot ? Icons.whatshot : isCold ? Icons.ac_unit : Icons.timeline;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.16), Colors.transparent],
        ),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
                Text(
                  streak.count > 0 ? streak.label : 'Close trades to unlock streak tracking',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowEquityPainter extends CustomPainter {
  final List<double> series;
  final Color color;

  _GlowEquityPainter({required this.series, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (series.length < 2) return;
    final path = Path();
    final fill = Path();
    for (var i = 0; i < series.length; i++) {
      final x = size.width * (i / (series.length - 1));
      final y = size.height * (1 - series[i].clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(size.width, size.height);
    fill.close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.45)
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.25
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _GlowEquityPainter old) => old.series != series;
}

// ─── Oracle Pulse — live opportunity radar ──────────────────────────────────

class _OraclePulseSection extends StatelessWidget {
  final List<OraclePulseOpportunity> opportunities;
  final Animation<double> radarAnimation;
  final void Function(String coin) onGenerateSetup;

  const _OraclePulseSection({
    required this.opportunities,
    required this.radarAnimation,
    required this.onGenerateSetup,
  });

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D4FF);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 72,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -8,
                top: 0,
                child: AnimatedBuilder(
                  animation: radarAnimation,
                  builder: (context, _) {
                    return Transform.rotate(
                      angle: radarAnimation.value * 2 * pi,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: SweepGradient(
                            colors: [
                              Colors.transparent,
                              cyan.withValues(alpha: 0.28),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.5, 1.0],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _PulsingDot(color: cyan),
                          const SizedBox(width: 8),
                          Text(
                            'LIVE',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.6,
                              color: cyan,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Oracle Pulse — Live Opportunities',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'High-confluence radar · tap to deploy Trade Setup',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                  Icon(Icons.radar, color: cyan.withValues(alpha: 0.65), size: 28),
                ],
              ),
            ),
          ],
        ),
        ),
        const SizedBox(height: 16),
        ...opportunities.asMap().entries.map((entry) {
          return _OraclePulseCard(
            opportunity: entry.value,
            index: entry.key,
            onGenerate: () => onGenerateSetup(entry.value.coin),
          );
        }),
      ],
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
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
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.5 + _c.value * 0.5),
            boxShadow: [
              BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 6 + _c.value * 6),
            ],
          ),
        );
      },
    );
  }
}

class _OraclePulseCard extends StatefulWidget {
  final OraclePulseOpportunity opportunity;
  final int index;
  final VoidCallback onGenerate;

  const _OraclePulseCard({
    required this.opportunity,
    required this.index,
    required this.onGenerate,
  });

  @override
  State<_OraclePulseCard> createState() => _OraclePulseCardState();
}

class _OraclePulseCardState extends State<_OraclePulseCard> with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 1800 + widget.index * 200),
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
      case 'BNB':
        return const Color(0xFFF0B90B);
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

    return AnimatedBuilder(
      animation: _glow,
      builder: (context, child) {
        final pulse = 0.12 + _glow.value * 0.18;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(color: dirColor.withValues(alpha: pulse), blurRadius: 22, spreadRadius: 0),
                BoxShadow(color: coinColor.withValues(alpha: pulse * 0.5), blurRadius: 14),
              ],
            ),
            child: child,
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      dirColor.withValues(alpha: 0.08),
                      const Color(0xFF12141C),
                      const Color(0xFF0A0A0E),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [coinColor.withValues(alpha: 0.5), coinColor.withValues(alpha: 0.08)],
                          ),
                          border: Border.all(color: coinColor.withValues(alpha: 0.5)),
                          boxShadow: [BoxShadow(color: coinColor.withValues(alpha: 0.35), blurRadius: 12)],
                        ),
                        child: Center(
                          child: Text(
                            opp.coin.length > 3 ? opp.coin.substring(0, 3) : opp.coin,
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: coinColor),
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
                                  opp.coin,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(width: 10),
                                Icon(
                                  isLong ? Icons.north_east : Icons.south_east,
                                  size: 20,
                                  color: dirColor,
                                ),
                                Text(
                                  opp.direction.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: dirColor,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    color: const Color(0xFF00D4FF).withValues(alpha: 0.12),
                                    border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.35)),
                                  ),
                                  child: Text(
                                    '${opp.convictionPct}% conviction',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF00D4FF),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    opp.whyNow,
                    style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: widget.onGenerate,
                      icon: const Icon(Icons.bolt, size: 18),
                      label: const Text('Generate Trade Setup'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFFF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: dirColor.withValues(alpha: 0.22)),
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
