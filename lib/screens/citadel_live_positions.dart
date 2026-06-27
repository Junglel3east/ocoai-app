// Citadel Live Positions — real-time BloFin open trades (Expert Citadel tab).

part of '../main.dart';

typedef CitadelPositionClosedCallback = void Function({
  required String coin,
  required double realizedPnl,
});

/// Live BloFin positions panel — premium command-center cards with real-time PnL.
class CitadelLivePositionsPanel extends StatefulWidget {
  final bool isActive;
  final bool serverLinked;
  final CitadelPositionClosedCallback? onPositionClosed;

  const CitadelLivePositionsPanel({
    super.key,
    required this.isActive,
    required this.serverLinked,
    this.onPositionClosed,
  });

  @override
  State<CitadelLivePositionsPanel> createState() => _CitadelLivePositionsPanelState();
}

class _CitadelLivePositionsPanelState extends State<CitadelLivePositionsPanel> {
  List<CitadelLivePosition> _positions = const [];
  bool _loading = false;
  String? _error;
  Timer? _pollTimer;
  String? _actionBusyId;

  @override
  void initState() {
    super.initState();
    _startPolling();
    if (widget.serverLinked) _refresh();
  }

  @override
  void didUpdateWidget(covariant CitadelLivePositionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && widget.serverLinked) {
      _refresh();
    }
    if (widget.serverLinked != oldWidget.serverLinked) {
      if (widget.serverLinked) {
        _refresh();
      } else {
        setState(() {
          _positions = const [];
          _error = null;
        });
      }
    }
    if (widget.isActive != oldWidget.isActive) {
      _startPolling();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!widget.isActive || !widget.serverLinked) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted && widget.isActive && widget.serverLinked) {
        _refresh(silent: true);
      }
    });
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!widget.serverLinked || !OracleCitadelStore.isConfigured) return;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await OracleCitadelStore.load();
      final list = await CitadelPositionsService.fetchPositions(
        userId: OracleCitadelStore.userId,
        appApiKey: OracleCitadelStore.apiKey,
      );
      if (!mounted) return;
      setState(() {
        _positions = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      debugPrint('[CitadelLivePositions] refresh error: $e');
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = 'Could not load live positions.';
      });
    }
  }

  Future<void> _close(CitadelLivePosition pos, {required bool flash}) async {
    setState(() => _actionBusyId = pos.positionId);
    try {
      await OracleCitadelStore.load();
      final result = await CitadelPositionsService.closePosition(
        userId: OracleCitadelStore.userId,
        appApiKey: OracleCitadelStore.apiKey,
        position: pos,
        flash: flash,
      );
      if (!mounted) return;
      if (result.success) {
        widget.onPositionClosed?.call(coin: result.coin, realizedPnl: result.realizedPnl);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              flash
                  ? 'Flash closed ${pos.coin} · PnL ${_formatPnl(result.realizedPnl)}'
                  : 'Closed ${pos.coin} · PnL ${_formatPnl(result.realizedPnl)}',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _refresh(silent: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.userMessage ?? 'Close failed.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusyId = null);
    }
  }

  Future<void> _trailingStop(CitadelLivePosition pos) async {
    final callback = await showDialog<double>(
      context: context,
      builder: (ctx) => _TrailingStopDialog(initialPct: 1.5),
    );
    if (callback == null || !mounted) return;
    setState(() => _actionBusyId = pos.positionId);
    try {
      await OracleCitadelStore.load();
      final err = await CitadelPositionsService.setTrailingStop(
        userId: OracleCitadelStore.userId,
        appApiKey: OracleCitadelStore.apiKey,
        position: pos,
        callbackPct: callback,
      );
      if (!mounted) return;
      if (err == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Trailing stop set on ${pos.coin} (${callback.toStringAsFixed(1)}%)'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _actionBusyId = null);
    }
  }

  Future<void> _showTpsl(CitadelLivePosition pos) async {
    setState(() => _actionBusyId = pos.positionId);
    List<CitadelTpslOrder> orders = const [];
    try {
      await OracleCitadelStore.load();
      orders = await CitadelPositionsService.fetchTpslDetails(
        userId: OracleCitadelStore.userId,
        appApiKey: OracleCitadelStore.apiKey,
        instId: pos.instId,
      );
    } finally {
      if (mounted) setState(() => _actionBusyId = null);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _TpslDetailsDialog(position: pos, orders: orders),
    );
  }

  static String _formatPnl(double v) {
    final sign = v >= 0 ? '+' : '';
    return '$sign\$${v.toStringAsFixed(2)}';
  }

  static String _formatPrice(double v) {
    if (v >= 1000) return '\$${v.toStringAsFixed(2)}';
    if (v >= 1) return '\$${v.toStringAsFixed(4)}';
    return '\$${v.toStringAsFixed(6)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.serverLinked) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LivePositionsHeader(
          count: _positions.length,
          loading: _loading,
          onRefresh: () => _refresh(),
        ),
        const SizedBox(height: 12),
        if (_loading && _positions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
              ),
            ),
          )
        else if (_error != null && _positions.isEmpty)
          Text(_error!, style: TextStyle(fontSize: 13, color: Colors.grey[500]))
        else if (_positions.isEmpty)
          _EmptyPositionsCard()
        else
          ..._positions.map(
            (p) => _LivePositionCard(
              position: p,
              busy: _actionBusyId == p.positionId,
              onClose: () => _close(p, flash: false),
              onFlashClose: () => _close(p, flash: true),
              onTrailingStop: () => _trailingStop(p),
              onTpslDetails: () => _showTpsl(p),
              formatPrice: _formatPrice,
              formatPnl: _formatPnl,
            ),
          ),
      ],
    );
  }
}

class _LivePositionsHeader extends StatelessWidget {
  final int count;
  final bool loading;
  final VoidCallback onRefresh;

  const _LivePositionsHeader({
    required this.count,
    required this.loading,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF00E676),
            boxShadow: [
              BoxShadow(color: const Color(0xFF00E676).withValues(alpha: 0.7), blurRadius: 8),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Live Positions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
        const SizedBox(width: 8),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.35)),
            ),
            child: Text(
              '$count OPEN',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF00BFFF)),
            ),
          ),
        const Spacer(),
        if (loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
          )
        else
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20, color: Colors.white54),
            onPressed: onRefresh,
            tooltip: 'Refresh positions',
          ),
      ],
    );
  }
}

class _EmptyPositionsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, color: Colors.grey[600], size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No open ${OracleCitadelStore.exchangeBrandName} positions yet.\n'
              '1. Trade Setup → generate a report\n'
              '2. Scroll down → Send to Oracle Citadel\n'
              '3. Choose MARKET or LIMIT and confirm',
              style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[500]),
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePositionCard extends StatelessWidget {
  final CitadelLivePosition position;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onFlashClose;
  final VoidCallback onTrailingStop;
  final VoidCallback onTpslDetails;
  final String Function(double) formatPrice;
  final String Function(double) formatPnl;

  const _LivePositionCard({
    required this.position,
    required this.busy,
    required this.onClose,
    required this.onFlashClose,
    required this.onTrailingStop,
    required this.onTpslDetails,
    required this.formatPrice,
    required this.formatPnl,
  });

  @override
  Widget build(BuildContext context) {
    final pnlColor = position.isProfit ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final dirColor = position.isLong ? const Color(0xFF00E676) : const Color(0xFFFF5252);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            pnlColor.withValues(alpha: 0.08),
            const Color(0xFF12141C),
            const Color(0xFF0A0A0E),
          ],
        ),
        border: Border.all(color: pnlColor.withValues(alpha: 0.28)),
        boxShadow: [
          BoxShadow(color: pnlColor.withValues(alpha: 0.12), blurRadius: 20, spreadRadius: 0),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  position.coin,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: dirColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: dirColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    position.direction.toUpperCase(),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: dirColor),
                  ),
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatPnl(position.unrealizedPnl),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: pnlColor),
                    ),
                    Text(
                      '${position.unrealizedPnlPct >= 0 ? '+' : ''}${position.unrealizedPnlPct.toStringAsFixed(2)}%',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pnlColor),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            _PositionMetricRow(
              left: 'Entry',
              leftVal: formatPrice(position.entryPrice),
              right: 'Mark',
              rightVal: formatPrice(position.markPrice),
            ),
            const SizedBox(height: 8),
            _PositionMetricRow(
              left: 'Size',
              leftVal: position.size.toStringAsFixed(4),
              right: 'Leverage',
              rightVal: '${position.leverage.toStringAsFixed(0)}x',
            ),
            const SizedBox(height: 8),
            _PositionMetricRow(
              left: 'Unrealized PnL',
              leftVal: formatPnl(position.unrealizedPnl),
              right: 'Liq Price',
              rightVal: position.liquidationPrice > 0
                  ? formatPrice(position.liquidationPrice)
                  : '—',
            ),
            const SizedBox(height: 14),
            if (busy)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                  ),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _PositionActionChip(
                    label: 'Close Position',
                    icon: Icons.close_rounded,
                    color: const Color(0xFFFFB74D),
                    onTap: onClose,
                  ),
                  _PositionActionChip(
                    label: 'Flash Close',
                    icon: Icons.flash_on_rounded,
                    color: const Color(0xFFFF5252),
                    onTap: onFlashClose,
                  ),
                  _PositionActionChip(
                    label: 'Trailing Stop',
                    icon: Icons.trending_down_rounded,
                    color: const Color(0xFF7C4DFF),
                    onTap: onTrailingStop,
                  ),
                  _PositionActionChip(
                    label: 'TP/SL Details',
                    icon: Icons.shield_outlined,
                    color: const Color(0xFF00BFFF),
                    onTap: onTpslDetails,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PositionMetricRow extends StatelessWidget {
  final String left;
  final String leftVal;
  final String right;
  final String rightVal;

  const _PositionMetricRow({
    required this.left,
    required this.leftVal,
    required this.right,
    required this.rightVal,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _MetricCell(label: left, value: leftVal)),
        const SizedBox(width: 12),
        Expanded(child: _MetricCell(label: right, value: rightVal, alignEnd: true)),
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  final String label;
  final String value;
  final bool alignEnd;

  const _MetricCell({required this.label, required this.value, this.alignEnd = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _PositionActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _PositionActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrailingStopDialog extends StatefulWidget {
  final double initialPct;

  const _TrailingStopDialog({required this.initialPct});

  @override
  State<_TrailingStopDialog> createState() => _TrailingStopDialogState();
}

class _TrailingStopDialogState extends State<_TrailingStopDialog> {
  late double _pct;

  @override
  void initState() {
    super.initState();
    _pct = widget.initialPct;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A22),
      title: const Text('Set Trailing Stop'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Callback distance from mark price',
            style: TextStyle(fontSize: 13, color: Colors.grey[400]),
          ),
          const SizedBox(height: 12),
          Slider(
            value: _pct,
            min: 0.5,
            max: 10,
            divisions: 19,
            label: '${_pct.toStringAsFixed(1)}%',
            activeColor: const Color(0xFF7C4DFF),
            onChanged: (v) => setState(() => _pct = v),
          ),
          Text(
            '${_pct.toStringAsFixed(1)}% trailing callback',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pct),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7C4DFF)),
          child: const Text('Set Stop'),
        ),
      ],
    );
  }
}

class _TpslDetailsDialog extends StatelessWidget {
  final CitadelLivePosition position;
  final List<CitadelTpslOrder> orders;

  const _TpslDetailsDialog({required this.position, required this.orders});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A22),
      title: Text('TP/SL · ${position.coin}'),
      content: SizedBox(
        width: double.maxFinite,
        child: orders.isEmpty
            ? Text(
                'No active TP/SL orders on BloFin for this position.',
                style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: orders.map((o) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (o.tpTriggerPrice != null)
                          Text('TP: \$${o.tpTriggerPrice!.toStringAsFixed(4)}'),
                        if (o.slTriggerPrice != null)
                          Text('SL: \$${o.slTriggerPrice!.toStringAsFixed(4)}'),
                        Text('State: ${o.state}', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                      ],
                    ),
                  );
                }).toList(),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
