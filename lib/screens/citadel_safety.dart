// Citadel safety — order preview before live orders, paper trading, pause / close-all.

part of '../main.dart';

class CitadelOrderPreview {
  final String exchange;
  final String coin;
  final String direction;
  final String orderType;
  final double entryPrice;
  final double stopLoss;
  final double tp1;
  final double tp2;
  final String sizeLabel;
  final double notional;
  final double margin;
  final double leverage;
  final double? available;
  final double risk;
  final double rewardTp1;
  final double rewardFull;
  final double? liquidation;
  final bool paused;
  final List<String> warnings;

  const CitadelOrderPreview({
    required this.exchange,
    required this.coin,
    required this.direction,
    required this.orderType,
    required this.entryPrice,
    required this.stopLoss,
    required this.tp1,
    required this.tp2,
    required this.sizeLabel,
    required this.notional,
    required this.margin,
    required this.leverage,
    required this.available,
    required this.risk,
    required this.rewardTp1,
    required this.rewardFull,
    required this.liquidation,
    required this.paused,
    required this.warnings,
  });

  static double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  static double? _dn(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));

  factory CitadelOrderPreview.fromJson(Map<String, dynamic> j) => CitadelOrderPreview(
        exchange: '${j['exchange'] ?? ''}',
        coin: '${j['coin'] ?? ''}',
        direction: '${j['direction'] ?? ''}',
        orderType: '${j['order_type'] ?? 'market'}',
        entryPrice: _d(j['entry_price']),
        stopLoss: _d(j['stop_loss']),
        tp1: _d(j['tp1']),
        tp2: _d(j['tp2']),
        sizeLabel: '${j['size_label'] ?? ''}',
        notional: _d(j['notional_usdt']),
        margin: _d(j['margin_usdt']),
        leverage: _d(j['leverage']),
        available: _dn(j['available_usdt']),
        risk: _d(j['risk_usdt']),
        rewardTp1: _d(j['reward_tp1_usdt']),
        rewardFull: _d(j['reward_full_usdt']),
        liquidation: _dn(j['est_liquidation_price']),
        paused: j['paused'] == true,
        warnings: (j['warnings'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}

class CitadelPaperTrade {
  final String coin;
  final String direction;
  final String orderType;
  final double entry;
  final String status;
  final String? outcome;
  final double? rMultiple;
  final DateTime createdAt;

  const CitadelPaperTrade({
    required this.coin,
    required this.direction,
    required this.orderType,
    required this.entry,
    required this.status,
    required this.outcome,
    required this.rMultiple,
    required this.createdAt,
  });

  factory CitadelPaperTrade.fromJson(Map<String, dynamic> j) => CitadelPaperTrade(
        coin: '${j['coin'] ?? ''}',
        direction: '${j['direction'] ?? ''}',
        orderType: '${j['order_type'] ?? 'market'}',
        entry: CitadelOrderPreview._d(j['entry']),
        status: '${j['status'] ?? 'pending'}',
        outcome: j['outcome']?.toString(),
        rMultiple: CitadelOrderPreview._dn(j['r_multiple']),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (CitadelOrderPreview._d(j['created_at']) * 1000).round(),
        ),
      );
}

class CitadelPaperSummary {
  final int closed;
  final int open;
  final double? winRate;
  final double totalR;
  final List<CitadelPaperTrade> trades;

  const CitadelPaperSummary({
    required this.closed,
    required this.open,
    required this.winRate,
    required this.totalR,
    required this.trades,
  });

  static const empty = CitadelPaperSummary(closed: 0, open: 0, winRate: null, totalR: 0, trades: []);
}

abstract final class CitadelSafetyService {
  static Map<String, dynamic> _decode(http.Response r) {
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  static String _message(http.Response r, Map<String, dynamic> body, String fallback) =>
      body['user_message']?.toString() ?? OracleCitadelService._parseUserMessage(r) ?? fallback;

  static Map<String, dynamic> _orderPayload({
    required String orderType,
    required String coin,
    required String direction,
    required double entryPrice,
    required double stopLoss,
    required double tp1,
    required double tp2,
    required double riskPercent,
    required double leverage,
  }) =>
      {
        'user_id': OracleCitadelStore.userId,
        'coin': coin.toUpperCase(),
        'direction': direction,
        'order_type': orderType,
        'use_demo_mode': OracleCitadelStore.useDemoMode,
        'entry_price': entryPrice,
        'stop_loss': stopLoss,
        'tp1': tp1,
        'tp2': tp2,
        'risk_percent': riskPercent,
        'leverage': leverage.round(),
      };

  static Future<CitadelOrderPreview> preview({
    required String orderType,
    required String coin,
    required String direction,
    required double entryPrice,
    required double stopLoss,
    required double tp1,
    required double tp2,
    required double riskPercent,
    required double leverage,
  }) async {
    final response = await http
        .post(
          Uri.parse('$kCitadelBaseUrl/citadel/preview_trade'),
          headers: await OracleCitadelService._authHeaders(),
          body: jsonEncode(_orderPayload(
            orderType: orderType,
            coin: coin,
            direction: direction,
            entryPrice: entryPrice,
            stopLoss: stopLoss,
            tp1: tp1,
            tp2: tp2,
            riskPercent: riskPercent,
            leverage: leverage,
          )),
        )
        .timeout(const Duration(seconds: 30));
    final body = _decode(response);
    if (response.statusCode == 200 && body['success'] == true) {
      return CitadelOrderPreview.fromJson(body);
    }
    throw OracleCitadelException(
      _message(response, body, 'Could not calculate this order (${response.statusCode}).'),
      errorCode: body['error_code']?.toString(),
    );
  }

  static Future<void> setPaused(bool paused) async {
    final response = await http
        .post(
          Uri.parse('$kCitadelBaseUrl/citadel/pause'),
          headers: await OracleCitadelService._authHeaders(),
          body: jsonEncode({'user_id': OracleCitadelStore.userId, 'paused': paused}),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw OracleCitadelException(_message(response, body, 'Could not update Citadel.'));
    }
    OracleCitadelStore.serverPaused = body['paused'] == true;
  }

  /// Pauses Citadel, cancels resting orders and market-closes every position.
  static Future<String> closeAll() async {
    final response = await http
        .post(
          Uri.parse('$kCitadelBaseUrl/citadel/close_all'),
          headers: await OracleCitadelService._authHeaders(),
          body: jsonEncode({'user_id': OracleCitadelStore.userId}),
        )
        .timeout(const Duration(seconds: 60));
    final body = _decode(response);
    if (response.statusCode != 200 && response.statusCode != 207) {
      throw OracleCitadelException(_message(response, body, 'Close all failed.'));
    }
    OracleCitadelStore.serverPaused = true;
    final closed = (body['closed'] as List?)?.length ?? 0;
    final failed = (body['failed'] as List?) ?? const [];
    final ordersNote = body['orders_cancelled'] == false
        ? ' Resting orders could not be cancelled — check the exchange.'
        : '';
    if (failed.isNotEmpty) {
      final coins = failed.map((f) => f is Map ? '${f['coin']}' : '$f').join(', ');
      return 'Closed $closed. Could not close: $coins — close them on the exchange.$ordersNote';
    }
    return closed == 0
        ? 'No open positions. Citadel is paused.$ordersNote'
        : 'Closed $closed position${closed == 1 ? '' : 's'}. Citadel is paused.$ordersNote';
  }

  static Future<void> placePaper({
    required String orderType,
    required String coin,
    required String direction,
    required double entryPrice,
    required double stopLoss,
    required double tp1,
    required double tp2,
  }) async {
    final response = await http
        .post(
          Uri.parse('$kCitadelBaseUrl/citadel/paper_trade'),
          headers: await OracleCitadelService._authHeaders(),
          body: jsonEncode(_orderPayload(
            orderType: orderType,
            coin: coin,
            direction: direction,
            entryPrice: entryPrice,
            stopLoss: stopLoss,
            tp1: tp1,
            tp2: tp2,
            riskPercent: OracleCitadelStore.defaultRiskPercent,
            leverage: OracleCitadelStore.defaultLeverage,
          )),
        )
        .timeout(const Duration(seconds: 20));
    final body = _decode(response);
    if (response.statusCode != 200) {
      throw OracleCitadelException(_message(response, body, 'Paper trade could not be recorded.'));
    }
  }

  static Future<CitadelPaperSummary> fetchPaper() async {
    final response = await http
        .get(
          Uri.parse('$kCitadelBaseUrl/citadel/paper_trades'),
          headers: await OracleCitadelService._authHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decode(response);
    if (response.statusCode != 200) return CitadelPaperSummary.empty;
    final summary = body['summary'] is Map ? body['summary'] as Map : const {};
    final trades = (body['trades'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CitadelPaperTrade.fromJson)
        .toList();
    return CitadelPaperSummary(
      closed: (summary['closed'] as num?)?.toInt() ?? 0,
      open: (summary['open'] as num?)?.toInt() ?? 0,
      winRate: (summary['win_rate'] as num?)?.toDouble(),
      totalR: (summary['total_r'] as num?)?.toDouble() ?? 0,
      trades: trades,
    );
  }
}

String _citadelUsd(double v) {
  final abs = v.abs();
  final digits = abs >= 100 ? 2 : (abs >= 1 ? 2 : 4);
  return '\$${v.toStringAsFixed(digits)}';
}

/// Live orders only: fetch the exact order Citadel will send and ask the user to confirm it.
Future<bool> _previewAndConfirmCitadelOrder(
  BuildContext context, {
  required String orderType,
  required String coin,
  required String direction,
  required double entryPrice,
  required double stopLoss,
  required double tp1,
  required double tp2,
  required double riskPercent,
  required double leverage,
}) async {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Calculating exact order…'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
    ),
  );
  CitadelOrderPreview preview;
  try {
    await OracleCitadelStore.load();
    preview = await CitadelSafetyService.preview(
      orderType: orderType,
      coin: coin,
      direction: direction,
      entryPrice: entryPrice,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
      riskPercent: riskPercent,
      leverage: leverage,
    );
  } on OracleCitadelException catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
      ),
    );
    return false;
  } catch (e) {
    debugPrint('[Citadel] preview failed: $e');
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not calculate the order. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  if (preview.paused) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Oracle Citadel is paused. Resume it in the Citadel tab to place trades.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => _CitadelOrderPreviewDialog(preview: preview),
  );
  return confirmed == true;
}

class _CitadelOrderPreviewDialog extends StatelessWidget {
  final CitadelOrderPreview preview;

  const _CitadelOrderPreviewDialog({required this.preview});

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final isLong = p.direction == 'long';
    final sideColor = isLong ? const Color(0xFF00E676) : const Color(0xFFFF5252);
    final exchangeName = p.exchange == 'bitunix' ? 'Bitunix' : 'BloFin';
    final rows = <(String, String)>[
      (p.orderType == 'market' ? 'Entry (live)' : 'Limit entry', _formatCitadelPrice(p.entryPrice)),
      ('Size', p.sizeLabel),
      ('Position value', _citadelUsd(p.notional)),
      ('Margin used', '${_citadelUsd(p.margin)} · ${p.leverage.toStringAsFixed(0)}x'),
      if (p.available != null) ('Available balance', _citadelUsd(p.available!)),
      ('Stop loss', _formatCitadelPrice(p.stopLoss)),
      if (p.liquidation != null) ('Est. liquidation', _formatCitadelPrice(p.liquidation!)),
    ];

    return Dialog(
      backgroundColor: const Color(0xFF141414),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: sideColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${p.orderType.toUpperCase()} ${p.direction.toUpperCase()}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: sideColor),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${p.coin} on $exchangeName',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Review the exact order before it goes live.',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _PreviewOutcome(label: 'If stopped', value: '-${_citadelUsd(p.risk)}', color: const Color(0xFFFF5252)),
                  const SizedBox(width: 10),
                  _PreviewOutcome(label: 'At TP1', value: '+${_citadelUsd(p.rewardTp1)}', color: const Color(0xFF00E676)),
                  const SizedBox(width: 10),
                  _PreviewOutcome(label: 'At TP2', value: '+${_citadelUsd(p.rewardFull)}', color: const Color(0xFF00E676)),
                ],
              ),
              const SizedBox(height: 16),
              ...rows.map(
                (r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Text(r.$1, style: TextStyle(fontSize: 13.5, color: Colors.grey[500])),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          r.$2,
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (p.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...p.warnings.map(
                  (w) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB74D).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFFB74D).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFFFB74D)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(w, style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.grey[300])),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                'Liquidation is an isolated-margin estimate; your exchange shows the exact level after fill.',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: Colors.grey[600]),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: sideColor,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  'Confirm ${p.orderType.toUpperCase()} ${p.direction.toUpperCase()}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewOutcome extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _PreviewOutcome({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paper mode: same flow as a live order, recorded and graded on real candles instead.
Future<void> _sendPaperOrder(
  BuildContext context, {
  required String orderType,
  required String coin,
  required String direction,
  required double plannedEntry,
  required double stopLoss,
  required double tp1,
  required double tp2,
}) async {
  try {
    await CitadelSafetyService.placePaper(
      orderType: orderType,
      coin: coin,
      direction: direction,
      entryPrice: plannedEntry,
      stopLoss: stopLoss,
      tp1: tp1,
      tp2: tp2,
    );
    await CitadelPendingTradeStore.clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Paper ${orderType.toUpperCase()} ${direction.toUpperCase()} on $coin recorded — '
          'track it in the Citadel tab.',
        ),
        backgroundColor: const Color(0xFF7E57C2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } on OracleCitadelException catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(e.userMessage),
        backgroundColor: const Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
      ),
    );
  } catch (e) {
    debugPrint('[Citadel] paper order failed: $e');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Paper trade failed. Check connection and try again.'),
        backgroundColor: Color(0xFFB71C1C),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Pause / Resume and the emergency Close All, above Live Positions.
class _CitadelSafetyBar extends StatefulWidget {
  final VoidCallback onAfterCloseAll;

  const _CitadelSafetyBar({required this.onAfterCloseAll});

  @override
  State<_CitadelSafetyBar> createState() => _CitadelSafetyBarState();
}

class _CitadelSafetyBarState extends State<_CitadelSafetyBar> {
  bool _busy = false;

  void _snack(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? const Color(0xFFB71C1C) : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _togglePause() async {
    final next = !OracleCitadelStore.serverPaused;
    setState(() => _busy = true);
    try {
      await CitadelSafetyService.setPaused(next);
      _snack(next ? 'Citadel paused — no new orders will be placed.' : 'Citadel resumed.');
    } on OracleCitadelException catch (e) {
      _snack(e.userMessage, error: true);
    } catch (_) {
      _snack('Could not reach Citadel. Try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Close everything?', style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          'Citadel will pause, cancel resting orders, and market-close every open '
          '${OracleCitadelStore.exchangeBrandName} position now. This can\'t be undone.',
          style: TextStyle(height: 1.45, color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
            child: const Text('Close All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      _snack(await CitadelSafetyService.closeAll());
      widget.onAfterCloseAll();
    } on OracleCitadelException catch (e) {
      _snack(e.userMessage, error: true);
    } catch (_) {
      _snack('Close all failed. Check connection, then close positions on the exchange.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paused = OracleCitadelStore.serverPaused;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (paused)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFB74D).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFB74D).withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.pause_circle_filled_rounded, color: Color(0xFFFFB74D), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Citadel is paused — new orders are blocked. Existing positions keep their stops.',
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.grey[300]),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _togglePause,
                icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
                label: Text(paused ? 'Resume Citadel' : 'Pause Citadel'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: paused ? const Color(0xFF00E676) : const Color(0xFFFFB74D),
                  side: BorderSide(
                    color: (paused ? const Color(0xFF00E676) : const Color(0xFFFFB74D)).withValues(alpha: 0.5),
                  ),
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _closeAll,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Close All'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF5252),
                  side: BorderSide(color: const Color(0xFFFF5252).withValues(alpha: 0.5)),
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Paper trading toggle + graded results. Works without exchange keys.
class CitadelPaperTradesPanel extends StatefulWidget {
  final bool isActive;

  const CitadelPaperTradesPanel({super.key, required this.isActive});

  @override
  State<CitadelPaperTradesPanel> createState() => _CitadelPaperTradesPanelState();
}

class _CitadelPaperTradesPanelState extends State<CitadelPaperTradesPanel> {
  CitadelPaperSummary _summary = CitadelPaperSummary.empty;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant CitadelPaperTradesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final summary = await CitadelSafetyService.fetchPaper();
      if (mounted) setState(() => _summary = summary);
    } catch (e) {
      debugPrint('[CitadelPaper] refresh failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _togglePaper(bool value) async {
    await OracleCitadelStore.savePaperMode(value);
    if (mounted) setState(() {});
  }

  static (String, Color) _statusLabel(CitadelPaperTrade t) {
    switch (t.outcome) {
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
    return t.status == 'open' ? ('Open', const Color(0xFF00BFFF)) : ('Waiting for entry', Colors.grey);
  }

  @override
  Widget build(BuildContext context) {
    const paperColor = Color(0xFF7E57C2);
    final paperOn = OracleCitadelStore.paperMode;
    final s = _summary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: paperColor.withValues(alpha: paperOn ? 0.08 : 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: paperColor.withValues(alpha: paperOn ? 0.4 : 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.science_outlined, color: paperColor, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Paper Trading',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                ),
              ),
              Switch(value: paperOn, activeThumbColor: paperColor, onChanged: _togglePaper),
            ],
          ),
          Text(
            paperOn
                ? 'On — Send to Oracle Citadel records a paper trade instead of a real order. '
                    'Results are graded on live market candles.'
                : 'Practice Citadel with no money at risk. Paper trades are graded on real market candles.',
            style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
          ),
          if (s.trades.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _PaperStat(label: 'Closed', value: '${s.closed}'),
                _PaperStat(
                  label: 'Win rate',
                  value: s.winRate == null ? '—' : '${(s.winRate! * 100).round()}%',
                ),
                _PaperStat(
                  label: 'Total R',
                  value: '${s.totalR >= 0 ? '+' : ''}${s.totalR.toStringAsFixed(1)}R',
                ),
                _PaperStat(label: 'Open', value: '${s.open}'),
              ],
            ),
            const SizedBox(height: 10),
            ...s.trades.take(8).map((t) {
              final (label, color) = _statusLabel(t);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Text(
                      '${t.coin} ${t.direction.toUpperCase()}',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '@ ${_formatCitadelPrice(t.entry)}',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
                    ),
                    const Spacer(),
                    if (t.rMultiple != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '${t.rMultiple! >= 0 ? '+' : ''}${t.rMultiple!.toStringAsFixed(2)}R',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
                        ),
                      ),
                    Text(label, style: TextStyle(fontSize: 12, color: color)),
                  ],
                ),
              );
            }),
          ],
          if (_loading && s.trades.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: paperColor),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaperStat extends StatelessWidget {
  final String label;
  final String value;

  const _PaperStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }
}
