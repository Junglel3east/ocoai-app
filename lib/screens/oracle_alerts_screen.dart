// Oracle Alerts — Setup Guardian, custom price, Pulse, Citadel.

part of '../main.dart';

class AlertsScreen extends StatefulWidget {
  final List<Map<String, dynamic>> trades;
  final void Function({
    required dynamic tradeId,
    required String status,
    required double exitPrice,
    double feesUsd,
  })? onCloseTrade;

  const AlertsScreen({
    super.key,
    required this.trades,
    this.onCloseTrade,
  });

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  @override
  void initState() {
    super.initState();
    OracleAlertStore.load().then((_) {
      if (mounted) setState(() {});
    });
    OracleAlertEngine.instance.bindTrades(widget.trades);
    unawaited(OracleAlertEngine.instance.tick());
  }

  @override
  void didUpdateWidget(covariant AlertsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    OracleAlertEngine.instance.bindTrades(widget.trades);
  }

  Future<void> _addPriceAlert() async {
    await SubscriptionPlanStore.load();
    final max = _alertPolicy.maxCustomPrice;
    final armed = OracleAlertStore.custom.where((a) => a.status == OracleAlertStatus.armed).length;
    if (armed >= max) {
      if (!mounted) return;
      _showLimitDialog(max);
      return;
    }
    if (!mounted) return;
    final created = await showModalBottomSheet<OracleAlert>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => const _PriceAlertEditorSheet(),
    );
    if (!mounted || created == null) return;
    await OracleAlertStore.addCustom(created);
    unawaited(OracleAlertEngine.instance.tick());
    setState(() {});
  }

  AlertTierPolicy get _alertPolicy {
    if (SubscriptionPlanStore.isExpert) return AlertTierPolicy.expert;
    if (SubscriptionPlanStore.isPremiumOrHigher) return AlertTierPolicy.premium;
    return AlertTierPolicy.free;
  }

  void _showLimitDialog(int max) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Alert limit', style: TextStyle(fontWeight: FontWeight.w600)),
        content: Text(
          max <= 1
              ? 'Free includes 1 custom price alert. Setup Guardians on your trades are unlimited. Upgrade for more price alerts and desk Pulse.'
              : 'This plan allows $max custom price alerts. Setup Guardians stay unlimited.',
          style: TextStyle(height: 1.45, color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('OK', style: TextStyle(color: Colors.grey[500])),
          ),
          if (SubscriptionPlanStore.isFree)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(context, _premiumPageRoute((_) => const SubscriptionPlanScreen()));
              },
              child: const Text('View Plans', style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    return ValueListenableBuilder<int>(
      valueListenable: OracleAlertStore.revision,
      builder: (context, _, __) {
        final open = widget.trades.where((t) => (t['status'] ?? '') == 'Open').toList();
        final custom = OracleAlertStore.custom;
        final triggered = custom.where((a) => a.status == OracleAlertStatus.triggered).toList();
        return Scaffold(
          backgroundColor: const Color(0xFF0F0F0F),
          appBar: AppBar(
            backgroundColor: const Color(0xFF0F0F0F),
            title: const Text('Oracle Alerts'),
            actions: [
              TextButton(
                onPressed: () async {
                  OracleAlertStore.muteAll = !OracleAlertStore.muteAll;
                  await OracleAlertStore.saveMutes();
                  if (mounted) setState(() {});
                },
                child: Text(
                  OracleAlertStore.muteAll ? 'Unmute' : 'Mute all',
                  style: TextStyle(color: OracleAlertStore.muteAll ? const Color(0xFFFFB74D) : Colors.grey[400]),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _addPriceAlert,
            backgroundColor: cyan,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.add),
            label: const Text('Price alert', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              _AlertsIntroCard(policy: _alertPolicy, muted: OracleAlertStore.muteAll),
              const SizedBox(height: 18),
              const _SectionHeader(title: 'Setup Guardians'),
              if (open.isEmpty)
                _AlertsEmptyCard(
                  icon: Icons.shield_moon_outlined,
                  title: 'No open setups',
                  subtitle: 'Generate a Trade Setup and I will watch entry, stop, and targets automatically.',
                )
              else
                ...open.map((trade) => _GuardianCard(
                      trade: trade,
                      onClose: widget.onCloseTrade == null
                          ? null
                          : () => _showCloseTradeDialog(context, trade).then((result) {
                                if (result == null) return;
                                widget.onCloseTrade!(
                                  tradeId: trade['id'],
                                  status: result.status,
                                  exitPrice: result.exitPrice,
                                  feesUsd: result.feesUsd,
                                );
                                setState(() {});
                              }),
                    )),
              const SizedBox(height: 18),
              const _SectionHeader(title: 'Custom price'),
              if (custom.where((a) => a.status == OracleAlertStatus.armed).isEmpty)
                _AlertsEmptyCard(
                  icon: Icons.attach_money,
                  title: 'No price alerts',
                  subtitle: 'Optional extra — one tap if you just want a level watched. Guardians already cover your setups.',
                )
              else
                ...custom.where((a) => a.status == OracleAlertStatus.armed).map(
                      (a) => _CustomPriceCard(
                        alert: a,
                        onDelete: () async {
                          await OracleAlertStore.removeCustom(a.id);
                          setState(() {});
                        },
                      ),
                    ),
              if (triggered.isNotEmpty) ...[
                const SizedBox(height: 18),
                const _SectionHeader(title: 'Triggered'),
                ...triggered.map(
                  (a) => _CustomPriceCard(
                    alert: a,
                    onDelete: () async {
                      await OracleAlertStore.removeCustom(a.id);
                      setState(() {});
                    },
                  ),
                ),
              ],
              const SizedBox(height: 18),
              _AlertsTierFootnote(policy: _alertPolicy),
            ],
          ),
        );
      },
    );
  }
}

class _AlertsIntroCard extends StatelessWidget {
  final AlertTierPolicy policy;
  final bool muted;

  const _AlertsIntroCard({required this.policy, required this.muted});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cyan.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            muted ? 'ALERTS MUTED' : 'WATCHING YOUR DESK',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: muted ? const Color(0xFFFFB74D) : Colors.grey[500],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            muted
                ? 'You will not get pings until you unmute. Setup levels still show here.'
                : 'Guardians arm with every open setup. Pulse ${policy.pulse ? 'on' : 'is Premium+'}. '
                    'Citadel live ${policy.citadel ? 'on' : 'is Expert'}. '
                    '${policy.maxCustomPrice} custom price alert${policy.maxCustomPrice == 1 ? '' : 's'} on this plan.',
            style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[300]),
          ),
        ],
      ),
    );
  }
}

class _AlertsEmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _AlertsEmptyCard({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF00BFFF), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.grey[500])),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuardianCard extends StatelessWidget {
  final Map<String, dynamic> trade;
  final VoidCallback? onClose;

  const _GuardianCard({required this.trade, this.onClose});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    final coin = (trade['coin'] ?? '—').toString();
    final entry = trade['entry'];
    final sl = trade['sl'];
    final tp1 = trade['tp1'];
    final id = '${trade['id']}';
    String chip(String level, String label) {
      final fired = OracleAlertStore.wasFired('g:$id:$level');
      return fired ? '$label ✓' : label;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cyan.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.shield_outlined, color: cyan, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$coin setup', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 4),
                Text(
                  'Entry $entry · SL $sl · TP1 $tp1',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _levelChip(chip('approach', 'Approach')),
                    _levelChip(chip('entry', 'Entry')),
                    _levelChip(chip('sl', 'SL')),
                    _levelChip(chip('tp1', 'TP1')),
                  ],
                ),
              ],
            ),
          ),
          if (onClose != null)
            TextButton(
              onPressed: onClose,
              child: const Text('Close', style: TextStyle(color: cyan, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }

  Widget _levelChip(String label) {
    final done = label.contains('✓');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: done ? const Color(0xFF00E676).withValues(alpha: 0.12) : const Color(0xFF0A0A0A),
        border: Border.all(color: done ? const Color(0xFF00E676).withValues(alpha: 0.45) : Colors.grey[800]!),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: done ? const Color(0xFF00E676) : Colors.grey[400],
        ),
      ),
    );
  }
}

class _CustomPriceCard extends StatelessWidget {
  final OracleAlert alert;
  final VoidCallback onDelete;

  const _CustomPriceCard({required this.alert, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final triggered = alert.status == OracleAlertStatus.triggered;
    final accent = triggered ? const Color(0xFFFFB74D) : const Color(0xFF00BFFF);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: triggered ? accent.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(triggered ? Icons.notifications_active : Icons.attach_money, color: accent, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${alert.coin} ${alert.above ? '≥' : '≤'} ${alert.targetPrice ?? '—'}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(
                  triggered ? (alert.body.isEmpty ? 'Triggered' : alert.body) : 'Armed',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, color: Colors.red[300], size: 22),
          ),
        ],
      ),
    );
  }
}

class _AlertsTierFootnote extends StatelessWidget {
  final AlertTierPolicy policy;

  const _AlertsTierFootnote({required this.policy});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Quiet hours 10pm–7am except stop / liquidation. Prices from Binance (free) — no extra API key.',
      style: TextStyle(fontSize: 12, height: 1.4, color: Colors.grey[600]),
    );
  }
}

class _PriceAlertEditorSheet extends StatefulWidget {
  const _PriceAlertEditorSheet();

  @override
  State<_PriceAlertEditorSheet> createState() => _PriceAlertEditorSheetState();
}

class _PriceAlertEditorSheetState extends State<_PriceAlertEditorSheet> {
  static const _coins = ['BTC', 'ETH', 'SOL', 'XRP', 'BNB'];
  String _coin = 'BTC';
  bool _above = true;
  final _price = TextEditingController();

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(4)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Custom price alert', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Optional. Your open setups are already guarded.',
            style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _coin,
            dropdownColor: const Color(0xFF1A1A1A),
            items: _coins.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) => setState(() => _coin = v ?? 'BTC'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Above')),
              ButtonSegment(value: false, label: Text('Below')),
            ],
            selected: {_above},
            onSelectionChanged: (s) => setState(() => _above = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Price (USD)', prefixText: '\$ '),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(_price.text.trim());
              if (value == null || value <= 0) return;
              Navigator.pop(
                context,
                OracleAlert(
                  id: DateTime.now().microsecondsSinceEpoch.toString(),
                  kind: OracleAlertKind.price,
                  coin: _coin,
                  level: 'custom',
                  title: '$_coin price',
                  body: '',
                  status: OracleAlertStatus.armed,
                  targetPrice: value,
                  above: _above,
                  createdAt: DateTime.now(),
                ),
              );
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00BFFF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Arm alert', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
