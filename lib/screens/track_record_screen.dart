// Track Record — every published daily setup, graded on real candles. Free for everyone.

part of '../main.dart';

class _TrackRecordSummary {
  final int closed;
  final int open;
  final int pending;
  final int noFill;
  final double? winRate;
  final double? tp1HitRate;
  final double? tp2HitRate;
  final double totalR;
  final double? avgR;

  const _TrackRecordSummary({
    required this.closed,
    required this.open,
    required this.pending,
    required this.noFill,
    required this.winRate,
    required this.tp1HitRate,
    required this.tp2HitRate,
    required this.totalR,
    required this.avgR,
  });

  factory _TrackRecordSummary.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    double? d(Object? v) => (v as num?)?.toDouble();
    int i(Object? v) => (v as num?)?.toInt() ?? 0;
    return _TrackRecordSummary(
      closed: i(j['closed']),
      open: i(j['open']),
      pending: i(j['pending']),
      noFill: i(j['no_fill']),
      winRate: d(j['win_rate']),
      tp1HitRate: d(j['tp1_hit_rate']),
      tp2HitRate: d(j['tp2_hit_rate']),
      totalR: d(j['total_r']) ?? 0,
      avgR: d(j['avg_r']),
    );
  }
}

class _TrackRecordSetup {
  final String coin;
  final String day;
  final String direction;
  final double entry;
  final String status;
  final String? outcome;
  final double? r;

  const _TrackRecordSetup({
    required this.coin,
    required this.day,
    required this.direction,
    required this.entry,
    required this.status,
    required this.outcome,
    required this.r,
  });

  factory _TrackRecordSetup.fromJson(Map<String, dynamic> j) => _TrackRecordSetup(
        coin: '${j['coin'] ?? ''}',
        day: '${j['day'] ?? ''}',
        direction: '${j['direction'] ?? ''}',
        entry: (j['entry'] as num?)?.toDouble() ?? 0,
        status: '${j['status'] ?? 'pending'}',
        outcome: j['outcome']?.toString(),
        r: (j['r_multiple'] as num?)?.toDouble(),
      );
}

class TrackRecordScreen extends StatefulWidget {
  const TrackRecordScreen({super.key});

  @override
  State<TrackRecordScreen> createState() => _TrackRecordScreenState();
}

class _TrackRecordScreenState extends State<TrackRecordScreen> {
  static const _windows = ['last_7d', 'last_30d', 'all_time'];
  static const _windowLabels = {'last_7d': '7 days', 'last_30d': '30 days', 'all_time': 'All time'};

  Map<String, _TrackRecordSummary> _summaries = {};
  List<_TrackRecordSetup> _recent = [];
  String _methodology = '';
  String _window = 'last_30d';
  bool _loading = true;
  String? _error;

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
    try {
      final response = await http
          .get(Uri.parse('$kBackendBaseUrl/track_record'))
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(response.body);
      if (response.statusCode != 200 || body is! Map<String, dynamic> || body['success'] != true) {
        throw Exception('status ${response.statusCode}');
      }
      if (!mounted) return;
      setState(() {
        _summaries = {for (final w in _windows) w: _TrackRecordSummary.fromJson(body[w])};
        _recent = (body['recent'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(_TrackRecordSetup.fromJson)
            .toList();
        _methodology = '${body['methodology'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('[TrackRecord] load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the track record. Pull to retry.';
      });
    }
  }

  static String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

  static String _r(double? v) => v == null ? '—' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}R';

  static (String, Color) _statusLabel(_TrackRecordSetup s) {
    switch (s.outcome) {
      case 'tp2':
        return ('TP2 hit', const Color(0xFF00E676));
      case 'tp1_then_stop':
        return ('TP1, then stop', const Color(0xFF00E676));
      case 'stopped':
        return ('Stopped', const Color(0xFFFF5252));
      case 'expired':
        return ('Closed at 14d', Colors.grey);
      case 'no_fill':
        return ('Never filled', Colors.grey);
    }
    return s.status == 'open' ? ('Open', const Color(0xFF00BFFF)) : ('Waiting for entry', Colors.grey);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summaries[_window];
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Text('Track Record', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: const Color(0xFF00BFFF),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            const Text(
              'Every daily setup, graded honestly',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4),
            ),
            const SizedBox(height: 6),
            Text(
              'Wins and losses are both shown. Nothing is hand-picked or edited after the fact.',
              style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.grey[400]),
            ),
            const SizedBox(height: 18),
            if (_loading && _summaries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator(color: Color(0xFF00BFFF))),
              )
            else if (_error != null && _summaries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[400])),
              )
            else ...[
              SegmentedButton<String>(
                segments: [
                  for (final w in _windows) ButtonSegment(value: w, label: Text(_windowLabels[w]!)),
                ],
                selected: {_window},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _window = s.first),
              ),
              const SizedBox(height: 16),
              if (summary != null) _buildSummary(summary),
              const SizedBox(height: 24),
              const Text('Recent setups', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (_recent.isEmpty)
                Text(
                  'Grading starts with the next daily analysis. Check back soon.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                )
              else
                ..._recent.map(_buildSetupRow),
              const SizedBox(height: 24),
              if (_methodology.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('How grading works', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(_methodology, style: TextStyle(fontSize: 12.5, height: 1.5, color: Colors.grey[400])),
                      const SizedBox(height: 8),
                      Text(
                        'Past performance does not guarantee future results. Not financial advice.',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(_TrackRecordSummary s) {
    final totalColor = s.totalR >= 0 ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    Widget tile(String label, String value, {Color? color}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                FittedBox(
                  child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
                ),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 11.5, color: Colors.grey[500])),
              ],
            ),
          ),
        );
    return Column(
      children: [
        Row(
          children: [
            tile('Win rate', _pct(s.winRate)),
            const SizedBox(width: 10),
            tile('Total', _r(s.closed == 0 ? null : s.totalR), color: s.closed == 0 ? null : totalColor),
            const SizedBox(width: 10),
            tile('Avg per trade', _r(s.avgR)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            tile('TP1 hit', _pct(s.tp1HitRate)),
            const SizedBox(width: 10),
            tile('TP2 hit', _pct(s.tp2HitRate)),
            const SizedBox(width: 10),
            tile('Closed', '${s.closed}'),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${s.open} open · ${s.pending} waiting for entry · ${s.noFill} never filled (excluded)',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
      ],
    );
  }

  Widget _buildSetupRow(_TrackRecordSetup s) {
    final (label, color) = _statusLabel(s);
    final dirColor = s.direction == 'long' ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(s.coin, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    Text(
                      s.direction.toUpperCase(),
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: dirColor),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${s.day} · Entry ${_formatCitadelPrice(s.entry)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
              if (s.r != null)
                Text(
                  _r(s.r),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
