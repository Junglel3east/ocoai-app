// ─── Trade Performance — trade card actions (Review / Open / Trash) ─────────



part of '../main.dart';



/// True when a saved report is a UI placeholder — not valid for Review/Open.
bool isPlaceholderStoredReport(String? report) {
  final t = report?.trim() ?? '';
  if (t.isEmpty) return true;
  final lower = t.toLowerCase();
  return lower == 'loading...' ||
      lower == 'loading' ||
      lower == 'no report' ||
      lower == 'no report.';
}

/// Compares ids after Hive reload (int, String, num, precision loss).

bool _historyIdsMatch(dynamic a, dynamic b) {

  if (a == null || b == null) return false;

  return a.toString() == b.toString();

}



/// History list time label from trade [createdAt] (e.g. "6/2 7:38").

String _tradeSetupTimeLabel(Map<String, dynamic> trade) {

  final raw = trade['createdAt']?.toString();

  if (raw == null || raw.isEmpty) return '';

  final dt = DateTime.tryParse(raw);

  if (dt == null) return '';

  final local = dt.toLocal();

  return '${local.month}/${local.day} ${local.hour}:${local.minute.toString().padLeft(2, '0')}';

}



/// Resolves the saved report for a trade — used at tap time, not only at build.

Map<String, dynamic>? resolveHistoryItemForTrade(

  Map<String, dynamic> trade,

  List<Map<String, dynamic>> history, {

  Set<String>? excludeHistoryIds,

}) {

  final tradeId = trade['id'];

  final coin = (trade['coin'] ?? '').toString().toUpperCase();

  final timeLabel = _tradeSetupTimeLabel(trade);

  final excluded = excludeHistoryIds ?? {};



  bool isExcluded(Map<String, dynamic> item) {

    final hid = item['id']?.toString();

    return hid != null && excluded.contains(hid);

  }



  Map<String, dynamic>? pick(Map<String, dynamic> item) {

    if (isExcluded(item)) return null;

    final report = item['report']?.toString() ?? '';

    if (isPlaceholderStoredReport(report)) return null;

    return Map<String, dynamic>.from(item);

  }



  // 1) Linked by tradeId (primary key).

  for (final item in history) {

    if (item['source'] != 'trade_setup') continue;

    if (_historyIdsMatch(item['tradeId'], tradeId)) {

      final picked = pick(item);

      if (picked != null) return picked;

    }

  }



  // 2) Linked by historyId stored on the trade row.

  final historyId = trade['historyId'];

  if (historyId != null) {

    for (final item in history) {

      if (item['source'] != 'trade_setup') continue;

      if (_historyIdsMatch(item['id'], historyId)) {

        final picked = pick(item);

        if (picked != null) return picked;

      }

    }

  }



  // 3) Same coin + same display time as Recent Analyses subtitle.

  if (coin.isNotEmpty && timeLabel.isNotEmpty) {

    for (final item in history) {

      if (item['source'] != 'trade_setup') continue;

      if ((item['coin'] ?? '').toString().toUpperCase() != coin) continue;

      if (item['time']?.toString() != timeLabel) continue;

      final picked = pick(item);

      if (picked != null) return picked;

    }

  }



  // 4) Report snapshot stored directly on the trade (survives history trim).

  final report = trade['report']?.toString() ?? '';

  if (!isPlaceholderStoredReport(report)) {

    return {

      'id': tradeId,

      'coin': trade['coin'],

      'report': report,

      'time': timeLabel.isNotEmpty ? timeLabel : trade['createdAt'],

      'source': 'trade_setup',

      'tradeId': tradeId,

      'tradeStatus': trade['status'] ?? 'Open',

    };

  }



  return null;

}



class TradePerformanceScreen extends StatelessWidget {

  final List<Map<String, dynamic>> trades;

  final Map<String, dynamic>? Function(Map<String, dynamic> trade) resolveHistoryForTrade;

  final void Function(Map<String, dynamic>) onViewReport;

  final void Function(dynamic tradeId) onDeleteTrade;



  const TradePerformanceScreen({

    super.key,

    required this.trades,

    required this.resolveHistoryForTrade,

    required this.onViewReport,

    required this.onDeleteTrade,

  });



  String _formatCreated(Map<String, dynamic> trade) {

    final label = _tradeSetupTimeLabel(trade);

    return label.isEmpty ? '—' : label;

  }



  void _snack(BuildContext context, String message) {

    ScaffoldMessenger.of(context).clearSnackBars();

    ScaffoldMessenger.of(context).showSnackBar(

      SnackBar(

        content: Text(message, style: const TextStyle(color: Colors.white)),

        behavior: SnackBarBehavior.floating,

        backgroundColor: const Color(0xFF2A2A2A),

        duration: const Duration(seconds: 3),

      ),

    );

  }



  void _confirmDeleteTrade(BuildContext context, Map<String, dynamic> trade) {

    final coin = (trade['coin'] ?? '—').toString();

    showDialog<void>(

      context: context,

      builder: (ctx) => AlertDialog(

        backgroundColor: const Color(0xFF1A1A1A),

        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),

        title: const Text('Delete trade?', style: TextStyle(fontWeight: FontWeight.w600)),

        content: Text(

          'Remove $coin trade setup from Trade Performance and Recent Analyses. This cannot be undone.',

          style: TextStyle(color: Colors.grey[400], height: 1.4),

        ),

        actions: [

          TextButton(

            onPressed: () => Navigator.pop(ctx),

            child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),

          ),

          TextButton(

            onPressed: () {

              Navigator.pop(ctx);

              onDeleteTrade(trade['id']);

              _snack(context, '$coin trade deleted');

            },

            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w600)),

          ),

        ],

      ),

    );

  }



  Widget _tradeCard(BuildContext context, Map<String, dynamic> trade) {

    final coin = (trade['coin'] ?? '—').toString();

    final status = (trade['status'] ?? 'Open').toString();

    final preview = resolveHistoryForTrade(trade);

    final timeLabel = preview?['time']?.toString() ?? _formatCreated(trade);



    return Padding(

      key: ValueKey('trade_${trade['id']}'),

      padding: const EdgeInsets.only(bottom: 10),

      child: Card(

        child: Padding(

          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),

          child: Row(

            crossAxisAlignment: CrossAxisAlignment.center,

            children: [

              Expanded(

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text(

                      '$coin Trade Setup',

                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),

                    ),

                    const SizedBox(height: 4),

                    Text(

                      '$timeLabel • $status',

                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),

                    ),

                  ],

                ),

              ),

              _HistoryChipButton(

                label: 'Review',

                backgroundColor: const Color(0xFF455A64),

                foregroundColor: Colors.white,

                onPressed: () {

                  final item = resolveHistoryForTrade(trade);

                  final report = item?['report']?.toString().trim() ?? '';

                  if (item == null || isPlaceholderStoredReport(report)) {

                    _snack(context, 'No saved report for this trade — run Trade Setup again to refresh.');

                    return;

                  }

                  Navigator.push(

                    context,

                    _premiumPageRoute(

                      (_) => ReviewReportScreen(historyItem: Map<String, dynamic>.from(item)),

                    ),

                  );

                },

              ),

              const SizedBox(width: 6),

              _HistoryChipButton(

                label: 'Open',

                backgroundColor: Colors.amber,

                foregroundColor: Colors.black87,

                onPressed: () {

                  final item = resolveHistoryForTrade(trade);

                  final report = item?['report']?.toString().trim() ?? '';

                  if (item == null || isPlaceholderStoredReport(report)) {

                    _snack(context, 'No saved report for this trade — run Trade Setup again to refresh.');

                    return;

                  }

                  onViewReport(Map<String, dynamic>.from(item));

                },

              ),

              IconButton(

                padding: EdgeInsets.zero,

                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),

                icon: Icon(Icons.delete_outline, color: Colors.red[400], size: 22),

                onPressed: () => _confirmDeleteTrade(context, trade),

              ),

            ],

          ),

        ),

      ),

    );

  }



  @override

  Widget build(BuildContext context) {

    final winCount = trades.where((t) => t['status'] == 'Win').length;

    final lossCount = trades.where((t) => t['status'] == 'Loss').length;

    final closed = winCount + lossCount;

    final openCount = trades.where((t) => t['status'] == 'Open').length;

    final rate = closed == 0 ? 0 : ((winCount / closed) * 100).round();



    return Scaffold(

      backgroundColor: const Color(0xFF0F0F0F),

      appBar: AppBar(

        title: const Text('Trade Performance'),

        backgroundColor: const Color(0xFF0F0F0F),

      ),

      body: trades.isEmpty

          ? _AppEmptyState(

              icon: Icons.emoji_events_outlined,

              title: 'No trades yet',

              subtitle: 'Generate a Trade Setup to start tracking performance here.',

            )

          : ListView(

              physics: const BouncingScrollPhysics(),

              padding: const EdgeInsets.all(_AppSpacing.screen),

              children: [

                Card(

                  child: Padding(

                    padding: const EdgeInsets.all(_AppSpacing.card),

                    child: Column(

                      crossAxisAlignment: CrossAxisAlignment.start,

                      children: [

                        const Text(

                          'Past Performance',

                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),

                        ),

                        const SizedBox(height: 10),

                        Text(

                          'Win Rate: $rate% ($winCount Wins / $closed Closed)',

                          style: const TextStyle(

                            fontSize: 15,

                            fontWeight: FontWeight.w600,

                            color: Color(0xFF00BFFF),

                          ),

                        ),

                        const SizedBox(height: 6),

                        Text(

                          '$openCount open · ${trades.length} total setups',

                          style: TextStyle(fontSize: 13, color: Colors.grey[500]),

                        ),

                      ],

                    ),

                  ),

                ),

                const SizedBox(height: _AppSpacing.section),

                const _SectionHeader(title: 'All Trades'),

                ...trades.map((trade) => _tradeCard(context, trade)),

              ],

            ),

    );

  }

}


