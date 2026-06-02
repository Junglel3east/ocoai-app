// ─── Trade Performance screen — full Recent Analyses card parity ─────────────
//
// Trade cards now mirror Home "Recent Analyses" layout: Review (gray), Open
// (yellow), and delete icon. Actions show snackbars; Review/Open use real
// navigation when a linked history item exists.
//
part of '../main.dart';

class TradePerformanceScreen extends StatelessWidget {
  final List<Map<String, dynamic>> trades;
  final List<Map<String, dynamic>> history;
  final void Function(Map<String, dynamic>) onViewReport;

  const TradePerformanceScreen({
    super.key,
    required this.trades,
    required this.history,
    required this.onViewReport,
  });

  Map<String, dynamic>? _historyForTrade(Map<String, dynamic> trade) {
    final tradeId = trade['id'];
    for (final item in history) {
      if (item['source'] == 'trade_setup' && item['tradeId'] == tradeId) {
        return item;
      }
    }
    return null;
  }

  String _formatCreated(Map<String, dynamic> trade) {
    final raw = trade['createdAt']?.toString();
    if (raw == null || raw.isEmpty) return '—';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '—';
    final local = dt.toLocal();
    return '${local.month}/${local.day} ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1A1A1A),
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
                ...trades.map((trade) {
                  final coin = (trade['coin'] ?? '—').toString();
                  final status = (trade['status'] ?? 'Open').toString();
                  final linked = _historyForTrade(trade);
                  final timeLabel = linked?['time']?.toString() ?? _formatCreated(trade);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        title: Text(
                          '$coin Trade Setup',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '$timeLabel • $status',
                            style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _HistoryChipButton(
                              label: 'Review',
                              backgroundColor: const Color(0xFF455A64),
                              foregroundColor: Colors.white,
                              onPressed: () {
                                if (linked != null) {
                                  Navigator.push(
                                    context,
                                    _premiumPageRoute(
                                      (_) => ReviewReportScreen(historyItem: linked),
                                    ),
                                  );
                                } else {
                                  _snack(context, 'Review opened');
                                }
                              },
                            ),
                            const SizedBox(width: 8),
                            _HistoryChipButton(
                              label: 'Open',
                              backgroundColor: Colors.amber,
                              foregroundColor: Colors.black87,
                              onPressed: () {
                                if (linked != null) {
                                  onViewReport(linked);
                                } else {
                                  _snack(context, 'Trade opened in Charts');
                                }
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: Colors.red[400]),
                              onPressed: () => _snack(context, 'Trade deleted'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}
