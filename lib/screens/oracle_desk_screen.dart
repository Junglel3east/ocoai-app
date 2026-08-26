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
        });
      }
    } catch (_) {
      if (mounted) {
        final fallback = OracleDeskBias(
          kind: OracleDeskBiasKind.neutral,
          confidencePct: 48,
          title: 'Neutral / Range-Bound',
          reasoning:
              'Could not refresh live quotes. War Room is using watchlist defaults until sync recovers.',
          recommendedCoins: widget.watchlist.take(4).map((c) => c.toUpperCase()).toList(),
          avgMomentum: 0,
        );
        setState(() {
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

  String _formatUsd(double v) {
    final sign = v >= 0 ? '+' : '-';
    final abs = v.abs();
    if (abs >= 1000000) return '$sign\$${(abs / 1000000).toStringAsFixed(2)}M';
    if (abs >= 1000) return '$sign\$${(abs / 1000).toStringAsFixed(1)}k';
    return '$sign\$${abs.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: StartingCapitalStore.notifier,
      builder: (context, capital, _) {
        final perf = OracleDeskService.computePerformance(
          trades: widget.trades,
          watchlist: widget.watchlist,
          startingCapitalUsd: capital,
          defaultRiskPercent: OracleCitadelStore.defaultRiskPercent,
          defaultLeverage: OracleCitadelStore.defaultLeverage,
        );
        return _buildDesk(context, perf);
      },
    );
  }

  Widget _buildDesk(BuildContext context, OracleDeskPerformance perf) {
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
                _WarRoomSection(
                  bias: _bias,
                  opportunities: _oraclePulse,
                  perf: perf,
                  pulseAnimation: _radarController,
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

  String _formatSnapshotBankroll(double v) {
    final n = v.round().clamp(0, 1000000);
    if (n >= 1000000) return '\$1,000,000';
    final raw = n.toString();
    final buf = StringBuffer('\$');
    for (var i = 0; i < raw.length; i++) {
      final fromEnd = raw.length - i;
      buf.write(raw[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Performance Snapshot',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                        ),
                      ),
                      PushToXButton(
                        iconOnly: true,
                        tooltip: 'Share War Room',
                        sheetTitle: 'Share War Room',
                        initialText: XShareService.formatWarRoomPost(
                          bankrollUsd: perf.startingCapitalUsd,
                          winRatePct: perf.winRatePct,
                          avgRiskReward: perf.avgRiskReward,
                          aiAlphaUsd: perf.totalAiAlphaUsd,
                          closedCount: perf.closedCount,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Bankroll ${_formatSnapshotBankroll(perf.startingCapitalUsd)}'
                    ' · each trade sized with stored risk % × leverage',
                    style: TextStyle(fontSize: 12, height: 1.35, color: Colors.grey[500]),
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

// ─── War Room — battlefield intelligence command center ─────────────────────

class _WarRoomIntel {
  final String tensionLabel;
  final double tensionValue;
  final int longPowerPct;
  final int shortPowerPct;
  final List<_BattleZone> zones;
  final String edgeStatus;
  final String edgeSubtext;
  final double edgeReadiness;
  final Color edgeColor;

  const _WarRoomIntel({
    required this.tensionLabel,
    required this.tensionValue,
    required this.longPowerPct,
    required this.shortPowerPct,
    required this.zones,
    required this.edgeStatus,
    required this.edgeSubtext,
    required this.edgeReadiness,
    required this.edgeColor,
  });

  static _WarRoomIntel fromDesk({
    required OracleDeskBias bias,
    required List<OraclePulseOpportunity> opportunities,
    required OracleDeskPerformance perf,
  }) {
    final momentum = bias.avgMomentum.abs();
    final tensionValue = ((momentum / 5.0).clamp(0.0, 1.0) * 0.55 + (bias.confidencePct / 100.0) * 0.45)
        .clamp(0.0, 1.0);
    final tensionLabel = tensionValue < 0.35
        ? 'LOW'
        : tensionValue < 0.68
            ? 'MEDIUM'
            : 'HIGH';

    var longW = 0.0;
    var shortW = 0.0;
    for (final o in opportunities) {
      if (o.direction.isLong) {
        longW += o.convictionPct;
      } else {
        shortW += o.convictionPct;
      }
    }
    if (perf.edge.longSamples + perf.edge.shortSamples >= 3) {
      longW += perf.edge.longWinRatePct * 0.4;
      shortW += perf.edge.shortWinRatePct * 0.4;
    }
    if (longW + shortW <= 0) {
      switch (bias.kind) {
        case OracleDeskBiasKind.bullish:
          longW = 68;
          shortW = 32;
        case OracleDeskBiasKind.bearish:
          longW = 32;
          shortW = 68;
        case OracleDeskBiasKind.neutral:
          longW = 50;
          shortW = 50;
      }
    }
    final totalForce = longW + shortW;
    final longPct = totalForce > 0 ? (longW / totalForce * 100).round().clamp(0, 100) : 50;
    final shortPct = 100 - longPct;

    final zones = opportunities.take(3).map((o) {
      final isLong = o.direction.isLong;
      return _BattleZone(
        coin: o.coin,
        direction: o.direction.label,
        level: _battleZoneLevel(o),
        reactionProb: o.convictionPct.clamp(55, 94),
        accent: isLong ? const Color(0xFF00E676) : const Color(0xFFFF5252),
      );
    }).toList();
    if (zones.isEmpty) {
      zones.addAll([
        _BattleZone(
          coin: 'BTC',
          direction: 'LONG',
          level: 'Daily VWAP + previous lows liquidity zone',
          reactionProb: 72,
          accent: const Color(0xFF00E676),
        ),
        _BattleZone(
          coin: 'ETH',
          direction: 'SHORT',
          level: 'OB rejection + FVG mitigation zone',
          reactionProb: 68,
          accent: const Color(0xFFFF5252),
        ),
      ]);
    }

    final streak = perf.streak;
    late final String edgeStatus;
    late final String edgeSubtext;
    late final double edgeReadiness;
    late final Color edgeColor;
    switch (streak.kind) {
      case OracleDeskStreakKind.hot:
        edgeStatus = 'COMBAT READY';
        edgeSubtext =
            '${streak.label} · ${perf.winRatePct.toStringAsFixed(0)}% win rate · deploy with conviction';
        edgeReadiness = (0.72 + (streak.count.clamp(0, 5) * 0.04)).clamp(0.0, 0.98);
        edgeColor = const Color(0xFF00E676);
      case OracleDeskStreakKind.cold:
        edgeStatus = 'REGROUP';
        edgeSubtext = '${streak.label} · cut size · wait for HTF alignment';
        edgeReadiness = (0.42 - (streak.count.clamp(0, 5) * 0.04)).clamp(0.12, 0.55);
        edgeColor = const Color(0xFFFF5252);
      case OracleDeskStreakKind.neutral:
        edgeStatus = 'ON STANDBY';
        edgeSubtext = perf.closedCount == 0
            ? 'No closed trades yet · paper setups to build edge'
            : '${perf.winRatePct.toStringAsFixed(0)}% win rate · hunt A+ setups only';
        edgeReadiness = (perf.winRatePct / 100.0 * 0.55 + 0.35).clamp(0.35, 0.78);
        edgeColor = const Color(0xFF00BFFF);
    }

    return _WarRoomIntel(
      tensionLabel: tensionLabel,
      tensionValue: tensionValue,
      longPowerPct: longPct,
      shortPowerPct: shortPct,
      zones: zones,
      edgeStatus: edgeStatus,
      edgeSubtext: edgeSubtext,
      edgeReadiness: edgeReadiness,
      edgeColor: edgeColor,
    );
  }

  static String _battleZoneLevel(OraclePulseOpportunity o) {
    final why = o.whyNow.toLowerCase();
    if (why.contains('vwap')) return 'Daily VWAP battle zone';
    if (why.contains('sweep') || why.contains('liquidity')) return 'Liquidity sweep + reaction zone';
    if (why.contains('ob') || why.contains('fvg')) return 'OB / FVG mitigation zone';
    return '${o.coin} key structure zone';
  }
}

class _BattleZone {
  final String coin;
  final String direction;
  final String level;
  final int reactionProb;
  final Color accent;

  const _BattleZone({
    required this.coin,
    required this.direction,
    required this.level,
    required this.reactionProb,
    required this.accent,
  });
}

class _WarRoomSection extends StatelessWidget {
  final OracleDeskBias bias;
  final List<OraclePulseOpportunity> opportunities;
  final OracleDeskPerformance perf;
  final Animation<double> pulseAnimation;

  const _WarRoomSection({
    required this.bias,
    required this.opportunities,
    required this.perf,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    final intel = _WarRoomIntel.fromDesk(
      bias: bias,
      opportunities: opportunities,
      perf: perf,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WarRoomHeader(pulseAnimation: pulseAnimation),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _WarRoomGaugeCard(intel: intel)),
            const SizedBox(width: 10),
            Expanded(child: _DominantForceCard(intel: intel)),
          ],
        ),
        const SizedBox(height: 10),
        _CriticalBattleZonesCard(zones: intel.zones, pulseAnimation: pulseAnimation),
        const SizedBox(height: 10),
        _YourEdgeStatusCard(intel: intel, pulseAnimation: pulseAnimation),
      ],
    );
  }
}

class _WarRoomHeader extends StatelessWidget {
  final Animation<double> pulseAnimation;

  const _WarRoomHeader({required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF1744);
    const cyan = Color(0xFF00D4FF);

    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        final pulse = 0.35 + (sin(pulseAnimation.value * 2 * pi) * 0.5 + 0.5) * 0.45;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1A0A12).withValues(alpha: 0.95),
                const Color(0xFF0A0E18),
                const Color(0xFF0A0A0C),
              ],
            ),
            border: Border.all(
              color: Color.lerp(red, cyan, pulse)!.withValues(alpha: 0.55),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(color: red.withValues(alpha: 0.12 * pulse), blurRadius: 24, spreadRadius: 1),
              BoxShadow(color: cyan.withValues(alpha: 0.10 * pulse), blurRadius: 20),
            ],
          ),
          child: child,
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _WarRoomPulseDot(color: red),
              const SizedBox(width: 8),
              _WarRoomPulseDot(color: cyan),
              const SizedBox(width: 10),
              Text(
                'LIVE INTEL',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                  color: cyan.withValues(alpha: 0.9),
                ),
              ),
              const Spacer(),
              Icon(Icons.shield_moon_outlined, color: red.withValues(alpha: 0.75), size: 22),
            ],
          ),
          const SizedBox(height: 10),
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Color(0xFFFF5252), Color(0xFF00D4FF), Color(0xFF7C4DFF)],
            ).createShader(bounds),
            child: const Text(
              'War Room',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Real-time battlefield intelligence',
            style: TextStyle(fontSize: 12, color: Colors.grey[500], letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}

class _WarRoomPulseDot extends StatefulWidget {
  final Color color;
  const _WarRoomPulseDot({required this.color});

  @override
  State<_WarRoomPulseDot> createState() => _WarRoomPulseDotState();
}

class _WarRoomPulseDotState extends State<_WarRoomPulseDot> with SingleTickerProviderStateMixin {
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
      builder: (context, _) {
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.45 + _c.value * 0.55),
            boxShadow: [
              BoxShadow(color: widget.color.withValues(alpha: 0.7), blurRadius: 5 + _c.value * 8),
            ],
          ),
        );
      },
    );
  }
}

class _WarRoomPanel extends StatelessWidget {
  final Widget child;
  final Color accent;

  const _WarRoomPanel({required this.child, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141018), Color(0xFF0A0A0E)],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.08), blurRadius: 16, spreadRadius: 0),
        ],
      ),
      child: child,
    );
  }
}

class _WarRoomGaugeCard extends StatelessWidget {
  final _WarRoomIntel intel;

  const _WarRoomGaugeCard({required this.intel});

  Color _tensionColor() {
    switch (intel.tensionLabel) {
      case 'HIGH':
        return const Color(0xFFFF5252);
      case 'MEDIUM':
        return const Color(0xFFFFB300);
      default:
        return const Color(0xFF00E676);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _tensionColor();
    return _WarRoomPanel(
      accent: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, size: 16, color: color.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Text(
                'Market Tension',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[400]),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            width: double.infinity,
            child: CustomPaint(
              painter: _TensionGaugePainter(value: intel.tensionValue, color: color),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: Text(
                    intel.tensionLabel,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Volatility + positioning pressure',
            style: TextStyle(fontSize: 10, color: Colors.grey[600]),
            maxLines: 2,
          ),
        ],
      ),
    );
  }
}

class _TensionGaugePainter extends CustomPainter {
  final double value;
  final Color color;

  _TensionGaugePainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.92);
    final radius = size.width * 0.38;
    const start = pi;
    const sweep = pi;

    final track = Paint()
      ..color = const Color(0xFF1E2836)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, false, track);

    final fill = Paint()
      ..shader = SweepGradient(
        startAngle: pi,
        endAngle: 2 * pi,
        colors: [color.withValues(alpha: 0.35), color],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep * value.clamp(0.02, 1.0), false, fill);

    final needleAngle = pi + sweep * value.clamp(0.0, 1.0);
    final needleEnd = Offset(
      center.dx + cos(needleAngle) * (radius - 4),
      center.dy + sin(needleAngle) * (radius - 4),
    );
    canvas.drawCircle(needleEnd, 4.5, Paint()..color = color..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(needleEnd, 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _TensionGaugePainter old) => old.value != value || old.color != color;
}

class _DominantForceCard extends StatelessWidget {
  final _WarRoomIntel intel;

  const _DominantForceCard({required this.intel});

  @override
  Widget build(BuildContext context) {
    const longColor = Color(0xFF00E676);
    const shortColor = Color(0xFFFF5252);
    final dominant = intel.longPowerPct >= intel.shortPowerPct ? 'LONGS' : 'SHORTS';
    final domColor = intel.longPowerPct >= intel.shortPowerPct ? longColor : shortColor;

    return _WarRoomPanel(
      accent: domColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.balance, size: 16, color: domColor.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Text(
                'Dominant Force',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[400]),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            dominant,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: domColor, letterSpacing: 0.8),
          ),
          const SizedBox(height: 10),
          _ForceBar(label: 'LONGS', pct: intel.longPowerPct, color: longColor),
          const SizedBox(height: 8),
          _ForceBar(label: 'SHORTS', pct: intel.shortPowerPct, color: shortColor),
        ],
      ),
    );
  }
}

class _ForceBar extends StatelessWidget {
  final String label;
  final int pct;
  final Color color;

  const _ForceBar({required this.label, required this.pct, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.grey[500])),
            Text('$pct%', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: pct / 100.0),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) {
              return Stack(
                children: [
                  Container(height: 6, color: const Color(0xFF1A2230)),
                  FractionallySizedBox(
                    widthFactor: v.clamp(0.0, 1.0),
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [color.withValues(alpha: 0.5), color]),
                        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6)],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CriticalBattleZonesCard extends StatelessWidget {
  final List<_BattleZone> zones;
  final Animation<double> pulseAnimation;

  const _CriticalBattleZonesCard({required this.zones, required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF7C4DFF);
    return _WarRoomPanel(
      accent: purple,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gps_fixed, size: 16, color: purple.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Text(
                'Critical Battle Zones',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[400]),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...zones.asMap().entries.map((e) {
            final z = e.value;
            return Padding(
              padding: EdgeInsets.only(bottom: e.key < zones.length - 1 ? 10 : 0),
              child: _BattleZoneRow(zone: z, index: e.key, pulseAnimation: pulseAnimation),
            );
          }),
        ],
      ),
    );
  }
}

class _BattleZoneRow extends StatelessWidget {
  final _BattleZone zone;
  final int index;
  final Animation<double> pulseAnimation;

  const _BattleZoneRow({
    required this.zone,
    required this.index,
    required this.pulseAnimation,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        final flicker = 0.85 + (sin((pulseAnimation.value + index * 0.2) * 2 * pi) * 0.5 + 0.5) * 0.15;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: zone.accent.withValues(alpha: 0.06),
            border: Border.all(color: zone.accent.withValues(alpha: 0.22 * flicker)),
          ),
          child: child,
        );
      },
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: zone.accent.withValues(alpha: 0.12),
              border: Border.all(color: zone.accent.withValues(alpha: 0.4)),
            ),
            child: Center(
              child: Text(
                zone.coin.length > 3 ? zone.coin.substring(0, 3) : zone.coin,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: zone.accent),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${zone.coin} · ${zone.direction}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  zone.level,
                  style: TextStyle(fontSize: 10, color: Colors.grey[500], height: 1.3),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              Text(
                '${zone.reactionProb}%',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: zone.accent),
              ),
              Text(
                'react',
                style: TextStyle(fontSize: 8, color: Colors.grey[600], letterSpacing: 0.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _YourEdgeStatusCard extends StatelessWidget {
  final _WarRoomIntel intel;
  final Animation<double> pulseAnimation;

  const _YourEdgeStatusCard({required this.intel, required this.pulseAnimation});

  @override
  Widget build(BuildContext context) {
    return _WarRoomPanel(
      accent: intel.edgeColor,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            height: 72,
            child: AnimatedBuilder(
              animation: pulseAnimation,
              builder: (context, _) {
                final pulse = 0.9 + (sin(pulseAnimation.value * 2 * pi) * 0.5 + 0.5) * 0.1;
                return CustomPaint(
                  painter: _ReadinessRingPainter(
                    progress: intel.edgeReadiness,
                    color: intel.edgeColor,
                    pulse: pulse,
                  ),
                  child: Center(
                    child: Text(
                      '${(intel.edgeReadiness * 100).round()}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: intel.edgeColor,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Edge Status',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey[400]),
                ),
                const SizedBox(height: 6),
                Text(
                  intel.edgeStatus,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                    color: intel.edgeColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  intel.edgeSubtext,
                  style: TextStyle(fontSize: 11, height: 1.35, color: Colors.grey[500]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadinessRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double pulse;

  _ReadinessRingPainter({required this.progress, required this.color, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.38;

    final track = Paint()
      ..color = const Color(0xFF1E2836)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..color = color.withValues(alpha: 0.85 * pulse)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * pulse);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      2 * pi * progress.clamp(0.02, 1.0),
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _ReadinessRingPainter old) =>
      old.progress != progress || old.color != color || old.pulse != pulse;
}
