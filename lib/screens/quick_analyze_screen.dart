// ─── Quick Analyze tab — premium crystal orb background ───────────────────────
//
// Added the same HD OracleProfileBackdrop used on Profile/Account (deep black
// base, crisp app_logo orb, subtle dark overlays — no teal wash). The backdrop
// sits behind the existing TabRootBody scroll layout; widgets, spacing, colors,
// and analyze() logic are unchanged.
//
part of '../main.dart';

class QuickAnalyzeScreen extends StatefulWidget {
  final void Function(String coin, String report) addToHistory;
  const QuickAnalyzeScreen({super.key, required this.addToHistory});
  @override
  State<QuickAnalyzeScreen> createState() => _QuickAnalyzeScreenState();
}

class _QuickAnalyzeScreenState extends State<QuickAnalyzeScreen> {
  final TextEditingController _controller = TextEditingController(text: "BTC");
  String _coinHint = CoinAccessPolicy.tierCoinHint();
  bool _useFallbackCoinField = false;

  @override
  void initState() {
    super.initState();
    SubscriptionPlanStore.load().then((_) {
      if (mounted) setState(() => _coinHint = CoinAccessPolicy.tierCoinHint());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openCoinSymbolSearch() async {
    try {
      final picked = await showCoinSymbolSearchModal(context, currentSymbol: _controller.text);
      if (!mounted || picked == null) return;
      setState(() => _controller.text = picked);
    } catch (_) {
      if (!mounted) return;
      setState(() => _useFallbackCoinField = true);
    }
  }

  Future<void> analyze() async {
    final coin = await resolveCoinForCurrentPlan(context, _controller.text);
    if (coin == null || !mounted) return;
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => AnalysisReportScreen(coin: coin, onNewAnalysis: widget.addToHistory),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text("Quick Analyze"),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(
            child: OracleProfileBackdrop(
              centeredOrb: true,
              orbHeight: kProfileBackgroundOrbHeight,
              orbOpacity: kProfileBackgroundOrbOpacity,
            ),
          ),
          Positioned.fill(
            child: TabRootBody(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return RepaintBoundary(
                    child: _premiumTabScrollBody(
                      minHeight: constraints.maxHeight,
                      children: [
                        const Text(
                          'Analyze a coin',
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Get an AI-powered market analysis with key levels and context.',
                          style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _coinHint,
                          style: TextStyle(fontSize: 12, height: 1.4, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: _AppSpacing.section),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(_AppSpacing.card),
                            child: _useFallbackCoinField
                                ? TextField(
                                    controller: _controller,
                                    textCapitalization: TextCapitalization.characters,
                                    decoration: InputDecoration(
                                      labelText: 'Coin Symbol',
                                      hintText: _coinHint,
                                      prefixIcon: const Icon(Icons.currency_bitcoin, color: Color(0xFF00BFFF)),
                                    ),
                                  )
                                : TextField(
                                    readOnly: true,
                                    controller: _controller,
                                    onTap: _openCoinSymbolSearch,
                                    textCapitalization: TextCapitalization.characters,
                                    decoration: const InputDecoration(
                                      labelText: 'Coin Symbol',
                                      hintText: 'Tap to search symbols',
                                      prefixIcon: Icon(Icons.currency_bitcoin, color: Color(0xFF00BFFF)),
                                      suffixIcon: Icon(Icons.search, color: Color(0xFF00BFFF)),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: _AppSpacing.section),
                        _ScaleTap(
                          onTap: () => analyze(),
                          child: ElevatedButton(
                            onPressed: analyze,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00BFFF),
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(52),
                            ),
                            child: const Text('Get Analysis'),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
