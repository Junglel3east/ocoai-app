// ─── Market Movers screen — live sections + plan gating ───────────────────────
//
// Fixed empty screen: uses cached fallback movers when Binance is unavailable.
// Premium/Expert see Top Gainers & Losers; Expert also sees New Coins. Free
// tier gets a premium upgrade message. Refresh in AppBar for paid plans.
//
part of '../main.dart';

class MarketMoversScreen extends StatefulWidget {
  const MarketMoversScreen({super.key});

  @override
  State<MarketMoversScreen> createState() => _MarketMoversScreenState();
}

class _MarketMoversScreenState extends State<MarketMoversScreen> {
  MarketMoversSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  bool _isFree = true;
  bool _isExpert = false;
  String _planLabel = 'Free';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await SubscriptionPlanStore.load();
    final isFree = SubscriptionPlanStore.isFree;
    final isExpert = SubscriptionPlanStore.isExpert;

    if (!mounted) return;

    if (isFree) {
      setState(() {
        _isFree = true;
        _isExpert = false;
        _planLabel = SubscriptionPlanStore.currentPlan;
        _loading = false;
        _snapshot = null;
      });
      return;
    }

    try {
      final snap = await MarketMoversService.fetch(
        allowedSymbols: CoinAccessPolicy.top150Coins,
        includeNewCoins: isExpert,
      );
      if (mounted) {
        setState(() {
          _isFree = false;
          _isExpert = isExpert;
          _planLabel = SubscriptionPlanStore.currentPlan;
          _snapshot = snap;
          _loading = false;
          if (snap.gainers.isEmpty && snap.losers.isEmpty) {
            _error = 'No mover data available right now.';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isFree = false;
          _isExpert = isExpert;
          _planLabel = SubscriptionPlanStore.currentPlan;
          _error = 'Could not load market movers. Tap refresh to retry.';
          _loading = false;
        });
      }
    }
  }

  void _openPlans() {
    Navigator.push(context, _premiumPageRoute((_) => const SubscriptionPlanScreen()));
  }

  Widget _upgradePanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.local_fire_department, color: Color(0xFF00BFFF), size: 48),
            const SizedBox(height: 16),
            const Text(
              'Unlock Market Movers',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'Unlock real-time Market Movers and new coin alerts with Premium or Expert. '
              'See who is leading the session — top gainers and losers across the Top 150 universe.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400]),
            ),
            const SizedBox(height: 14),
            Text(
              'Premium unlocks live Top Gainers & Losers. Expert adds exclusive New Coins '
              'and the full Oracle desk toolkit.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[500]),
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              onPressed: _openPlans,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFFF),
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('View Premium & Expert Plans'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moverSection({
    required String title,
    required List<MarketMoverRow> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              child: ListTile(
                title: Text('No $title data', style: TextStyle(color: Colors.grey[500])),
              ),
            ),
          )
        else
          ...rows.map((row) {
            final up = row.change24hPct >= 0;
            final color = up ? const Color(0xFF00E676) : const Color(0xFFFF5252);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                    child: Text(
                      row.symbol.length >= 2 ? row.symbol.substring(0, 2) : row.symbol,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        color: Color(0xFF00BFFF),
                      ),
                    ),
                  ),
                  title: Text(row.symbol, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '\$${_formatPrice(row.priceUsd)} · 24h',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  trailing: Text(
                    '${up ? '+' : ''}${row.change24hPct.toStringAsFixed(2)}%',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: color),
                  ),
                ),
              ),
            );
          }),
        const SizedBox(height: _AppSpacing.item),
      ],
    );
  }

  String _formatPrice(double price) {
    if (price >= 1000) return price.toStringAsFixed(2);
    if (price >= 1) return price.toStringAsFixed(4);
    return price.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text('Market Movers'),
        backgroundColor: const Color(0xFF0F0F0F),
        actions: [
          if (!_isFree)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded, size: 22),
              onPressed: _loading ? null : _load,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF)))
          : _isFree
              ? ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.all(_AppSpacing.screen),
                  children: [_upgradePanel()],
                )
              : RefreshIndicator(
                  color: const Color(0xFF00BFFF),
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    padding: const EdgeInsets.all(_AppSpacing.screen),
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(_error!, style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 13)),
                        ),
                      Text(
                        '$_planLabel · ${(_snapshot?.usedLiveData ?? false) ? 'Live Binance 24h' : 'Estimated movers'}',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: _AppSpacing.section),
                      _moverSection(
                        title: 'Top Gainers',
                        rows: _snapshot?.gainers ?? [],
                      ),
                      _moverSection(
                        title: 'Top Losers',
                        rows: _snapshot?.losers ?? [],
                      ),
                      if (_isExpert)
                        _moverSection(
                          title: 'New Coins',
                          rows: _snapshot?.newCoins ?? [],
                        ),
                    ],
                  ),
                ),
    );
  }
}
