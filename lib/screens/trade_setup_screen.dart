// ─── Trade Setup tab — premium crystal orb background ───────────────────────
//
// Added the same HD OracleProfileBackdrop as Profile/Account behind the form.
// The orb is positioned in the upper hero zone so it fills the visual gap
// between the AppBar ("Trade Setup") and "Configure your setup" with branded
// artwork instead of flat black — while keeping every SizedBox, card, field,
// button, and generateSetup() behavior identical.
//
part of '../main.dart';

class TradeSetupScreen extends StatefulWidget {
  final String coin;
  final Function(Map<String, dynamic>) onTradeSetupGenerated;

  const TradeSetupScreen({
    super.key,
    required this.coin,
    required this.onTradeSetupGenerated,
  });

  @override
  State<TradeSetupScreen> createState() => _TradeSetupScreenState();
}

class _TradeSetupScreenState extends State<TradeSetupScreen> {
  final TextEditingController _coinController = TextEditingController();
  String selectedCoin = "BTC";
  bool useCustomCoin = false;
  bool _useFallbackCoinDropdown = false;
  String selectedTimeframe = "1h";
  String selectedDirection = "Smart Direction";

  @override
  void initState() {
    super.initState();
    selectedCoin = CoinAccessPolicy.normalizeCoinSymbol(widget.coin) ?? widget.coin.toUpperCase();
    _coinController.text = selectedCoin;
  }

  @override
  void dispose() {
    _coinController.dispose();
    super.dispose();
  }

  Future<void> _openCoinSymbolSearch() async {
    try {
      final picked = await showCoinSymbolSearchModal(
        context,
        currentSymbol: useCustomCoin ? _coinController.text : selectedCoin,
      );
      if (!mounted || picked == null) return;
      setState(() {
        useCustomCoin = false;
        selectedCoin = picked;
        _coinController.text = picked;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _useFallbackCoinDropdown = true);
    }
  }

  Widget _buildCoinSymbolFallback() {
    return Column(
      children: [
        DropdownButton<String>(
          value: useCustomCoin ? "Custom" : selectedCoin,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: "BTC", child: Text("BTC")),
            DropdownMenuItem(value: "ETH", child: Text("ETH")),
            DropdownMenuItem(value: "SOL", child: Text("SOL")),
            DropdownMenuItem(value: "XRP", child: Text("XRP")),
            DropdownMenuItem(value: "BNB", child: Text("BNB")),
            DropdownMenuItem(value: "Custom", child: Text("Custom")),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              if (v == "Custom") {
                useCustomCoin = true;
              } else {
                useCustomCoin = false;
                selectedCoin = v;
                _coinController.text = v;
              }
            });
          },
        ),
        if (useCustomCoin) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _coinController,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Custom Coin Symbol (e.g. HYPE, AVAX)',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> generateSetup() async {
    final raw = useCustomCoin ? _coinController.text : selectedCoin;
    final coin = await resolveCoinForCurrentPlan(context, raw);
    if (coin == null || !mounted) return;
    Navigator.push(
      context,
      _premiumPageRoute(
        (_) => TradeSetupResultScreen(
          coin: coin,
          timeframe: selectedTimeframe,
          direction: selectedDirection,
          onTradeSetupGenerated: widget.onTradeSetupGenerated,
        ),
      ),
    );
  }

  Widget _formSection({required String label, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(_AppSpacing.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text("Trade Setup"),
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
                        Text(
                          'Configure your setup',
                          style: TextStyle(fontSize: 14, height: 1.45, color: Colors.grey[500]),
                        ),
                        const SizedBox(height: _AppSpacing.section),
                        _formSection(
                          label: 'Coin Symbol',
                          child: _useFallbackCoinDropdown
                              ? _buildCoinSymbolFallback()
                              : TextField(
                                  readOnly: true,
                                  controller: _coinController,
                                  onTap: _openCoinSymbolSearch,
                                  textCapitalization: TextCapitalization.characters,
                                  decoration: const InputDecoration(
                                    hintText: 'Tap to search symbols',
                                    suffixIcon: Icon(Icons.search, color: Color(0xFF00BFFF)),
                                  ),
                                ),
                        ),
                        const SizedBox(height: _AppSpacing.item),
                        _formSection(
                          label: 'Timeframe',
                          child: DropdownButton<String>(
                            value: selectedTimeframe,
                            isExpanded: true,
                            items: ["5m", "10m", "15m", "20m", "30m", "1h", "2h", "4h", "8h", "1d"]
                                .map((tf) => DropdownMenuItem(value: tf, child: Text(tf)))
                                .toList(),
                            onChanged: (v) => setState(() => selectedTimeframe = v!),
                          ),
                        ),
                        const SizedBox(height: _AppSpacing.item),
                        _formSection(
                          label: 'Direction',
                          child: DropdownButton<String>(
                            value: selectedDirection,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: "Smart Direction", child: Text("Smart Direction")),
                              DropdownMenuItem(value: "Long Only", child: Text("Long Only")),
                              DropdownMenuItem(value: "Short Only", child: Text("Short Only")),
                            ],
                            onChanged: (v) => setState(() => selectedDirection = v!),
                          ),
                        ),
                        const SizedBox(height: _AppSpacing.section),
                        _ScaleTap(
                          onTap: () => generateSetup(),
                          child: ElevatedButton(
                            onPressed: generateSetup,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber,
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(54),
                            ),
                            child: const Text("Generate Trade Setup"),
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
