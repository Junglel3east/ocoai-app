// First-run desk setup — venue, bankroll, four watchlist coins.

part of '../main.dart';

class FirstRunSetupScreen extends StatefulWidget {
  const FirstRunSetupScreen({super.key});

  @override
  State<FirstRunSetupScreen> createState() => _FirstRunSetupScreenState();
}

class _FirstRunSetupScreenState extends State<FirstRunSetupScreen> {
  final _page = PageController();
  int _step = 0;
  String _venueId = TradingVenueStore.venueId;
  double _capital = StartingCapitalStore.capitalUsd;
  late final TextEditingController _capitalController;
  final Set<String> _coins = {};

  static const _maxCoins = 4;
  static const _introCount = 3;
  static const _setupCount = 3;
  int get _pageCount => _introCount + _setupCount;
  bool get _onIntro => _step < _introCount;
  bool get _onLastPage => _step >= _pageCount - 1;

  List<String> get _popular {
    final popular = CoinAccessPolicy.popularForTier();
    if (popular.length >= 8) return popular.take(12).toList();
    return [...popular, ...CoinAccessPolicy.browseableCoins().where((c) => !popular.contains(c))]
        .take(12)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _capitalController = TextEditingController(text: _formatCap(_capital));
    _coins.addAll(WatchlistStore.defaults.take(_maxCoins));
    TradingVenueStore.load().then((_) {
      if (!mounted) return;
      setState(() => _venueId = TradingVenueStore.venueId);
    });
    StartingCapitalStore.load().then((_) {
      if (!mounted) return;
      setState(() {
        _capital = StartingCapitalStore.capitalUsd;
        _capitalController.text = _formatCap(_capital);
      });
    });
  }

  @override
  void dispose() {
    _page.dispose();
    _capitalController.dispose();
    super.dispose();
  }

  String _formatCap(double value) {
    final n = value.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < n.length; i++) {
      final fromEnd = n.length - i;
      buf.write(n[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  Future<void> _goTo(int step) async {
    setState(() => _step = step);
    await _page.animateToPage(step, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  bool _finishing = false;

  Future<void> _finish({required bool skipped}) async {
    if (_finishing) return;
    _finishing = true;
    if (!skipped) {
      await TradingVenueStore.save(_venueId);
      await StartingCapitalStore.save(_capital);
      final coins = _coins.isEmpty ? WatchlistStore.defaults : _coins.toList();
      await WatchlistStore.save(coins);
    }
    await FirstRunStore.markComplete();
    if (!mounted) return;
    Navigator.of(context).pop(skipped ? null : _coins.toList());
  }

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _finish(skipped: true);
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _onIntro ? 'Welcome to the desk' : 'Set up your desk',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _finish(skipped: true),
                    child: Text('Skip', style: TextStyle(color: Colors.grey[500], fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _onIntro
                    ? 'A 60-second read on what this app is — then venue, bankroll, watchlist.'
                    : 'Three taps — venue, bankroll, watchlist. War Room uses these for AI Alpha.',
                style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[500]),
              ),
              const SizedBox(height: 16),
              Row(
                children: List.generate(_pageCount, (i) {
                  final active = i <= _step;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(right: i == _pageCount - 1 ? 0 : 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: active ? cyan : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: PageView(
                  controller: _page,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _introWhat(),
                    _introHow(),
                    _introNfa(),
                    _venueStep(),
                    _capitalStep(),
                    _coinsStep(),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_step > 0)
                    TextButton(
                      onPressed: () => _goTo(_step - 1),
                      child: Text('Back', style: TextStyle(color: Colors.grey[400], fontWeight: FontWeight.w600)),
                    )
                  else
                    const SizedBox(width: 64),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      if (!_onLastPage) {
                        _goTo(_step + 1);
                      } else {
                        _finish(skipped: false);
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: cyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      _onLastPage ? 'Start trading' : 'Continue',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _stepCard({required String title, required String subtitle, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[500])),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _introWhat() {
    return _introCard(
      icon: Icons.dashboard_customize_outlined,
      title: 'This is a desk — not an exchange',
      body:
          'On-Chain Oracle AI gives you daily BTC/ETH bias, written Entry / TP / SL, War Room sizing from your bankroll, and alerts on your setups.\n\n'
          'It is not TradingView and it is not a brokerage. Charts stay where you already trade. This app is the read and the scoreboard.',
    );
  }

  Widget _introHow() {
    return _introCard(
      icon: Icons.route_outlined,
      title: 'How you use it',
      body:
          'Home — Daily Oracle Bias and your watchlist.\n'
          'Oracle Vision — live opportunities. After a pump it waits for support, not a chase.\n'
          'Trade Setup — the levels.\n'
          'Oracle Desk — win rate, R, and AI Alpha.\n\n'
          'Learn tab teaches the language (VWAP, structure, risk) so the reports make sense.',
    );
  }

  Widget _introNfa() {
    return _introCard(
      icon: Icons.gavel_outlined,
      title: 'NFA / DYOR',
      body:
          'Everything here is education only — not financial advice. Crypto is volatile.\n\n'
          'Starting capital sizes War Room paper risk. Live orders only happen if you later connect Oracle Citadel. Never trade money you cannot afford to lose.',
    );
  }

  Widget _introCard({required IconData icon, required String title, required String body}) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _stepCard(
          title: title,
          subtitle: '',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFF00BFFF), size: 36),
              const SizedBox(height: 14),
              Text(body, style: TextStyle(fontSize: 14.5, height: 1.5, color: Colors.grey[300])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _venueStep() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _stepCard(
          title: 'I trade on',
          subtitle: 'Tells the AI your execution venue. Citadel still places orders only on the linked exchange.',
          child: DropdownButtonFormField<String>(
            value: _venueId,
            isExpanded: true,
            dropdownColor: const Color(0xFF1A1A1A),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFF0A0A0A),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey[800]!),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFF00BFFF), width: 1.5),
              ),
            ),
            items: TradingVenueStore.options
                .map((opt) => DropdownMenuItem(value: opt.id, child: Text(opt.label, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (id) {
              if (id == null) return;
              setState(() => _venueId = id);
            },
          ),
        ),
      ],
    );
  }

  Widget _capitalStep() {
    final risk = OracleCitadelStore.defaultRiskPercent;
    final lev = OracleCitadelStore.defaultLeverage;
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _stepCard(
          title: 'Starting capital',
          subtitle: 'War Room AI Alpha sizes every trade from this bankroll.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _capitalController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                decoration: InputDecoration(
                  prefixText: '\$ ',
                  prefixStyle: TextStyle(color: Colors.grey[400], fontWeight: FontWeight.w600, fontSize: 18),
                  filled: true,
                  fillColor: const Color(0xFF0A0A0A),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey[800]!),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide(color: Color(0xFF00BFFF), width: 1.5),
                  ),
                ),
                onChanged: (raw) {
                  final parsed = double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), ''));
                  if (parsed == null) return;
                  setState(() => _capital = parsed.clamp(StartingCapitalStore.minUsd, StartingCapitalStore.maxUsd));
                },
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: const Color(0xFF00BFFF),
                  inactiveTrackColor: Colors.grey[800],
                  thumbColor: const Color(0xFF00BFFF),
                  overlayColor: const Color(0xFF00BFFF).withValues(alpha: 0.16),
                  trackHeight: 3,
                ),
                child: Slider(
                  min: StartingCapitalStore.minUsd,
                  max: StartingCapitalStore.maxUsd,
                  value: _capital.clamp(StartingCapitalStore.minUsd, StartingCapitalStore.maxUsd),
                  onChanged: (v) {
                    setState(() {
                      _capital = v;
                      _capitalController.text = _formatCap(v);
                    });
                  },
                ),
              ),
              Text(
                '${PositionSizing.formulaLine(capital: _capital, riskPercent: risk, leverage: lev)}\n'
                '${PositionSizing.breakdownLine(capital: _capital, riskPercent: risk, leverage: lev)}',
                style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _coinsStep() {
    return ListView(
      physics: const BouncingScrollPhysics(),
      children: [
        _stepCard(
          title: 'Your first four coins',
          subtitle: 'Watchlist + Daily bias use these. You can add more later from Home.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _popular.map((coin) {
              final selected = _coins.contains(coin);
              final locked = !selected && _coins.length >= _maxCoins;
              return GestureDetector(
                onTap: locked
                    ? null
                    : () {
                        setState(() {
                          if (selected) {
                            _coins.remove(coin);
                          } else {
                            _coins.add(coin);
                          }
                        });
                      },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: selected
                        ? const Color(0xFF00BFFF).withValues(alpha: 0.18)
                        : const Color(0xFF0A0A0A),
                    border: Border.all(
                      color: selected ? const Color(0xFF00BFFF) : Colors.grey[800]!,
                    ),
                  ),
                  child: Text(
                    coin,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: locked
                          ? Colors.grey[700]
                          : selected
                              ? const Color(0xFF00BFFF)
                              : Colors.grey[300],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${_coins.length}/$_maxCoins selected',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
      ],
    );
  }
}
