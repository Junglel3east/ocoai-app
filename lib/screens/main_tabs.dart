// Bottom-nav tabs: Citadel hub, Oracle Vision, Oracle Desk, tier gates.

part of '../main.dart';

/// Bottom-nav Citadel tab — Expert: full Citadel hub; Free/Premium: upgrade gate.
class _CitadelScreen extends StatefulWidget {
  final bool isActive;
  final CitadelPositionClosedCallback? onPositionClosed;

  const _CitadelScreen({
    required this.isActive,
    this.onPositionClosed,
  });

  @override
  State<_CitadelScreen> createState() => _CitadelScreenState();
}

class _CitadelScreenState extends State<_CitadelScreen> {
  bool _isExpert = false;
  final GlobalKey<_CitadelExpertViewState> _expertKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _CitadelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    final expert = SubscriptionPlanStore.hasCitadelAccess;
    setState(() => _isExpert = expert);
    if (expert) {
      _expertKey.currentState?.refreshHub();
    }
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_isExpert) {
      return _CitadelExpertView(
        key: _expertKey,
        isActive: widget.isActive,
        onPositionClosed: widget.onPositionClosed,
        onOpenSetup: () async {
          await showCitadelSetupDialog(context);
          await _expertKey.currentState?.refreshHub();
        },
      );
    }
    return _CitadelUpgradeView(onUpgrade: _openSubscription);
  }
}

/// Expert plan — full Citadel hub (BloFin status, leverage, setup).
class _CitadelPendingDeployCard extends StatelessWidget {
  final CitadelPendingTrade trade;
  final VoidCallback onDeploy;
  final VoidCallback onDismiss;

  const _CitadelPendingDeployCard({
    required this.trade,
    required this.onDeploy,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final dir = trade.direction.toUpperCase();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF43A047).withValues(alpha: 0.14),
            const Color(0xFF141414),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF43A047).withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Trade ready to deploy',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.green[100],
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: onDismiss,
                icon: Icon(Icons.close, color: Colors.grey[500], size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$dir ${trade.coin} · Entry ${_formatCitadelPrice(trade.entry)} · '
            'SL ${_formatCitadelPrice(trade.stopLoss)}',
            style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[400]),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onDeploy,
            icon: const Icon(Icons.bolt_rounded, size: 20),
            label: Text('Deploy to ${OracleCitadelStore.exchangeBrandName} now'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF43A047),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Expert plan — full Citadel hub (BloFin status, leverage, setup).
class _CitadelExpertView extends StatefulWidget {
  final bool isActive;
  final Future<void> Function() onOpenSetup;
  final CitadelPositionClosedCallback? onPositionClosed;

  const _CitadelExpertView({
    super.key,
    required this.isActive,
    required this.onOpenSetup,
    this.onPositionClosed,
  });

  @override
  State<_CitadelExpertView> createState() => _CitadelExpertViewState();
}

class _CitadelExpertViewState extends State<_CitadelExpertView> {
  bool _loading = true;
  bool _serverLinked = false;
  String? _linkMessage;
  String _exchangeLabel = 'BloFin';
  DateTime? _lastConnected;
  double _leverage = 5;
  double _riskPercent = 1;
  CitadelPendingTrade? _pendingTrade;

  @override
  void initState() {
    super.initState();
    refreshHub();
  }

  @override
  void didUpdateWidget(covariant _CitadelExpertView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      refreshHub();
    }
  }

  Future<void> refreshHub() async {
    setState(() => _loading = true);
    await OracleCitadelStore.load();
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString('citadel_last_connected_iso');
    final label = prefs.getString('citadel_connected_exchange_label');
    var linked = false;
    String? message;
    if (OracleCitadelStore.isConfigured) {
      final status = await OracleCitadelService.checkServerLinked();
      linked = status.linked;
      message = status.linked ? null : status.userMessage;
    } else {
      message = 'App credentials not saved — open setup to configure Citadel.';
    }
    final pending = await CitadelPendingTradeStore.load();
    if (!mounted) return;
    setState(() {
      _serverLinked = linked;
      _linkMessage = message;
      _exchangeLabel = (label != null && label.trim().isNotEmpty)
          ? label
          : OracleCitadelStore.exchangeDisplayLabel;
      _lastConnected = iso != null ? DateTime.tryParse(iso) : null;
      _leverage = OracleCitadelStore.defaultLeverage;
      _riskPercent = OracleCitadelStore.defaultRiskPercent;
      _pendingTrade = pending;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 22),
            SizedBox(width: 8),
            Text('Citadel', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(24, 12, 24, 20 + bottomInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Oracle Citadel',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                'MARKET & LIMIT execution via ${OracleCitadelStore.exchangeBrandName}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configure keys, leverage, and risk here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                    ),
                  ),
                )
              else if (_serverLinked)
                _CitadelConnectionStatusCard(
                  exchangeLabel: _exchangeLabel,
                  demoMode: OracleCitadelStore.useDemoMode,
                  lastConnected: _lastConnected ?? DateTime.now(),
                  leverage: _leverage.round(),
                )
              else
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB74D).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFB74D).withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.link_off_rounded, color: Color(0xFFFFB74D), size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _linkMessage ??
                              'Not connected — open setup to link your ${OracleCitadelStore.exchangeBrandName} API keys.',
                          style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[300]),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!_loading && _serverLinked) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFF00BFFF), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Connected means your ${OracleCitadelStore.exchangeBrandName} keys are linked — it does not place orders by itself. '
                          'Deploy from Trade Setup: generate a report, scroll down, tap Send to Oracle Citadel, '
                          'then choose MARKET or LIMIT.',
                          style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_pendingTrade != null) ...[
                  const SizedBox(height: 14),
                  _CitadelPendingDeployCard(
                    trade: _pendingTrade!,
                    onDeploy: () {
                      final pending = _pendingTrade!;
                      _showCitadelExecuteChoiceDialog(
                        context,
                        reportText: pending.reportText,
                        coin: pending.coin,
                        direction: pending.direction,
                        plannedEntry: pending.entry,
                        stopLoss: pending.stopLoss,
                        tp1: pending.tp1,
                        tp2: pending.tp2,
                      );
                    },
                    onDismiss: () async {
                      await CitadelPendingTradeStore.clear();
                      if (!mounted) return;
                      setState(() => _pendingTrade = null);
                    },
                  ),
                ],
                const SizedBox(height: 20),
                CitadelLivePositionsPanel(
                  isActive: widget.isActive,
                  serverLinked: _serverLinked,
                  onPositionClosed: widget.onPositionClosed,
                ),
              ],
              if (!_loading) ...[
                const SizedBox(height: 18),
                CitadelPaperTradesPanel(isActive: widget.isActive),
                const SizedBox(height: 18),
                _CitadelLeverageRiskPanel(
                  leverage: _leverage,
                  riskPercent: _riskPercent,
                  onLeverageChanged: (v) async {
                    await OracleCitadelStore.saveLeverage(v);
                    setState(() => _leverage = OracleCitadelStore.defaultLeverage);
                  },
                  onRiskPercentChanged: (v) async {
                    await OracleCitadelStore.saveRiskPercent(v);
                    setState(() => _riskPercent = OracleCitadelStore.defaultRiskPercent);
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'API & execution',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[500],
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'User ID: ${OracleCitadelStore.userId}',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        OracleCitadelStore.selectedExchange == 'bitunix'
                            ? 'Mode: Bitunix Live'
                            : 'Mode: BloFin Demo (demo only — testing)',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        OracleCitadelStore.isConfigured
                            ? 'App API key: configured'
                            : 'App API key: not set',
                        style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => widget.onOpenSetup(),
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  label: const Text('Open Citadel Setup'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Free / Premium — Citadel upgrade gate (mirrors Expert hero, locks execution).
class _CitadelUpgradeView extends StatelessWidget {
  final VoidCallback onUpgrade;

  const _CitadelUpgradeView({required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 22),
            SizedBox(width: 8),
            Text('Citadel', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28, 12, 28, 20 + bottomInset),
          child: Column(
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Oracle Citadel',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                'MARKET & LIMIT execution via ${OracleCitadelStore.exchangeBrandName}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Configure keys, leverage, and risk here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onUpgrade,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 3,
                    shadowColor: const Color(0xFF00BFFF).withValues(alpha: 0.45),
                  ),
                  child: const Text(
                    '🔓 Unlock Oracle Pro',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Oracle Citadel is non-custodial — you connect your own exchange API keys. Included with Oracle Pro.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom-nav Oracle Vision — Premium+: live hub; Free: upgrade gate.
class _OracleVisionTabScreen extends StatefulWidget {
  final bool isActive;
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const _OracleVisionTabScreen({
    required this.isActive,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<_OracleVisionTabScreen> createState() => _OracleVisionTabScreenState();
}

class _OracleVisionTabScreenState extends State<_OracleVisionTabScreen> {
  bool _hasAccess = false;

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _OracleVisionTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() => _hasAccess = SubscriptionPlanStore.hasOracleVisionAccess);
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasAccess) {
      return OracleVisionScreen(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
        onTradeSetupGenerated: widget.onTradeSetupGenerated,
      );
    }
    return _TierGateUpgradeView(
      title: 'Oracle Vision',
      icon: Icons.visibility_outlined,
      headline: 'Oracle Vision',
      subtitle: 'Live High-Conviction Opportunities',
      detail: 'Real-time liquidation heatmaps, pulse signals, and confluence-driven setups.',
      buttonLabel: '🔓 Unlock Oracle Pro',
      footnote: 'Free users get Daily Analysis on BTC, ETH, and SOL. Oracle Vision is included with Oracle Pro.',
      onUpgrade: _openSubscription,
    );
  }
}

/// Bottom-nav Oracle Desk — Expert only; Free/Premium: upgrade gate.
class _OracleDeskTabScreen extends StatefulWidget {
  final bool isActive;
  final List<String> watchlist;
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onTradeSetupGenerated;

  const _OracleDeskTabScreen({
    required this.isActive,
    required this.watchlist,
    required this.trades,
    required this.history,
    required this.onTradeSetupGenerated,
  });

  @override
  State<_OracleDeskTabScreen> createState() => _OracleDeskTabScreenState();
}

class _OracleDeskTabScreenState extends State<_OracleDeskTabScreen> {
  bool _isExpert = false;

  @override
  void initState() {
    super.initState();
    _refreshPlan();
  }

  @override
  void didUpdateWidget(covariant _OracleDeskTabScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refreshPlan();
    }
  }

  Future<void> _refreshPlan() async {
    await SubscriptionPlanStore.load();
    if (!mounted) return;
    setState(() => _isExpert = SubscriptionPlanStore.hasOracleDeskAccess);
  }

  Future<void> _openSubscription() async {
    await Navigator.push(
      context,
      _premiumPageRoute((_) => const SubscriptionPlanScreen()),
    );
    await _refreshPlan();
  }

  @override
  Widget build(BuildContext context) {
    if (_isExpert) {
      return OracleDeskScreen(
        watchlist: widget.watchlist,
        trades: widget.trades,
        history: widget.history,
        onTradeSetupGenerated: widget.onTradeSetupGenerated,
      );
    }
    return _TierGateUpgradeView(
      title: 'Oracle Desk',
      icon: Icons.dashboard_customize_outlined,
      headline: 'Oracle Desk',
      subtitle: 'Advanced Performance + Personal Command Center',
      detail: 'Watchlist bias, trade performance, Oracle Pulse, and your personal trading hub.',
      buttonLabel: '🔓 Unlock Oracle Pro',
      footnote: 'Your performance analytics and personal command center. Included with Oracle Pro.',
      onUpgrade: _openSubscription,
    );
  }
}

/// Reusable tier gate shell (Citadel / Vision / Desk upgrade screens).
class _TierGateUpgradeView extends StatelessWidget {
  final String title;
  final IconData icon;
  final String headline;
  final String subtitle;
  final String detail;
  final String buttonLabel;
  final String footnote;
  final VoidCallback onUpgrade;

  const _TierGateUpgradeView({
    required this.title,
    required this.icon,
    required this.headline,
    required this.subtitle,
    required this.detail,
    required this.buttonLabel,
    required this.footnote,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF00BFFF), size: 22),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(28, 12, 28, 20 + bottomInset),
          child: Column(
            children: [
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: const Color(0xFF00BFFF), size: 32),
                    ),
                    const SizedBox(width: 14),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43A047).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.rocket_launch_rounded, color: Color(0xFF43A047), size: 32),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Text(
                headline,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[400],
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onUpgrade,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 3,
                    shadowColor: const Color(0xFF00BFFF).withValues(alpha: 0.45),
                  ),
                  child: Text(
                    buttonLabel,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                footnote,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
