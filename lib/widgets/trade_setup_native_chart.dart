import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _kBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'https://ocoai-app-production.up.railway.app',
);

// ── Palette (premium neon / glowing) ──────────────────────────────────────────
const _kChartBg = Color(0xFF0F0F0F);
const _kGrid = Color(0xFF1E2836);
const _kHaUp = Color(0xFF26A69A);
const _kHaDown = Color(0xFFEF5350);
const _kDailyVwap = Color(0xFF00E5FF);
const _kPrevDayVwap = Color(0xFF448AFF);
const _kFib382 = Color(0xFFFF9800);
const _kFib50 = Color(0xFF00E676);
const _kFib618 = Color(0xFF26C6DA);
const _kFib786 = Color(0xFF2196F3);
const _kEntry = Color(0xFFFFFFFF);
const _kTp1 = Color(0xFF00E676);
const _kTp2 = Color(0xFF00FF88);
const _kSl = Color(0xFFFF5252);

class OhlcBar {
  final int timeSec;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const OhlcBar({
    required this.timeSec,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  factory OhlcBar.fromJson(List<dynamic> row) {
    return OhlcBar(
      timeSec: (row[0] as num).toInt(),
      open: (row[1] as num).toDouble(),
      high: (row[2] as num).toDouble(),
      low: (row[3] as num).toDouble(),
      close: (row[4] as num).toDouble(),
      volume: (row[5] as num).toDouble(),
    );
  }
}

class HaBar {
  final double open;
  final double high;
  final double low;
  final double close;

  const HaBar({
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });
}

class VwapSeries {
  final List<double> daily;
  final double? prevDayFinal;

  const VwapSeries({required this.daily, this.prevDayFinal});
}

class FibLevel {
  final double ratio;
  final double price;
  final Color color;
  final String label;

  const FibLevel({
    required this.ratio,
    required this.price,
    required this.color,
    required this.label,
  });
}

String klinesIntervalForTimeframe(String timeframe) {
  switch (timeframe.trim().toLowerCase()) {
    case '5m':
      return '5m';
    case '10m':
      return '15m';
    case '15m':
      return '15m';
    case '20m':
      return '30m';
    case '30m':
      return '30m';
    case '1h':
      return '1h';
    case '2h':
      return '2h';
    case '4h':
      return '4h';
    case '8h':
      return '8h';
    case '1d':
      return '1d';
    default:
      return '1h';
  }
}

Future<List<OhlcBar>> fetchTradeSetupKlines({
  required String coin,
  required String timeframe,
}) async {
  final sym = coin.trim().toUpperCase();
  final iv = klinesIntervalForTimeframe(timeframe);
  final uri = Uri.parse('$_kBackendBaseUrl/klines?coin=$sym&interval=$iv&limit=300');
  final response = await http.get(uri).timeout(const Duration(seconds: 15));
  if (response.statusCode != 200) {
    throw Exception('Klines ${response.statusCode}');
  }
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final rows = data['klines'] as List<dynamic>? ?? [];
  return rows.map((r) => OhlcBar.fromJson(r as List<dynamic>)).toList();
}

List<HaBar> toHeikinAshi(List<OhlcBar> bars) {
  final out = <HaBar>[];
  double? prevO;
  double? prevC;
  for (final b in bars) {
    final haC = (b.open + b.high + b.low + b.close) / 4;
    final haO = prevO == null ? (b.open + b.close) / 2 : (prevO + prevC!) / 2;
    out.add(HaBar(
      open: haO,
      high: math.max(b.high, math.max(haO, haC)),
      low: math.min(b.low, math.min(haO, haC)),
      close: haC,
    ));
    prevO = haO;
    prevC = haC;
  }
  return out;
}

VwapSeries computeVwap(List<OhlcBar> bars) {
  final daily = List<double>.filled(bars.length, 0);
  double pv = 0;
  double vol = 0;
  int? day;
  double? prevFinal;
  double? lastVwap;

  for (var i = 0; i < bars.length; i++) {
    final b = bars[i];
    final d = b.timeSec ~/ 86400;
    if (day != null && d != day) {
      prevFinal = lastVwap;
      pv = 0;
      vol = 0;
    }
    day = d;
    final tp = (b.high + b.low + b.close) / 3;
    pv += tp * b.volume;
    vol += b.volume;
    lastVwap = vol > 0 ? pv / vol : b.close;
    daily[i] = lastVwap;
  }
  return VwapSeries(daily: daily, prevDayFinal: prevFinal);
}

List<FibLevel> computeFibLevels(List<OhlcBar> bars) {
  final look = bars.length > 120 ? bars.sublist(bars.length - 120) : bars;
  if (look.isEmpty) return [];

  var hi = -double.infinity;
  var lo = double.infinity;
  var hiIdx = 0;
  var loIdx = 0;
  for (var i = 0; i < look.length; i++) {
    if (look[i].high > hi) {
      hi = look[i].high;
      hiIdx = i;
    }
    if (look[i].low < lo) {
      lo = look[i].low;
      loIdx = i;
    }
  }
  final range = hi - lo;
  if (range <= 0) return [];

  final upTrend = hiIdx > loIdx;
  const specs = <(double, Color, String)>[
    (0.382, _kFib382, 'Fib 0.382'),
    (0.5, _kFib50, 'Fib 0.5'),
    (0.618, _kFib618, 'Fib 0.618'),
    (0.786, _kFib786, 'Fib 0.786'),
  ];
  return specs
      .map((s) => FibLevel(
            ratio: s.$1,
            price: upTrend ? hi - range * s.$1 : lo + range * s.$1,
            color: s.$2,
            label: s.$3,
          ))
      .toList();
}

String formatChartPrice(double v) {
  if (v >= 1000) return v.toStringAsFixed(2);
  if (v >= 1) return v.toStringAsFixed(4);
  if (v >= 0.01) return v.toStringAsFixed(6);
  return v.toStringAsFixed(8);
}

/// Premium native Trade Setup chart — Heikin Ashi + VWAPs + Fib + trade levels.
class TradeSetupNativeChart extends StatefulWidget {
  final String symbol;
  final String timeframe;
  final double? entry;
  final double? tp1;
  final double? tp2;
  final double? sl;
  final double height;

  const TradeSetupNativeChart({
    super.key,
    required this.symbol,
    required this.timeframe,
    this.entry,
    this.tp1,
    this.tp2,
    this.sl,
    this.height = 420,
  });

  @override
  State<TradeSetupNativeChart> createState() => _TradeSetupNativeChartState();
}

class _TradeSetupNativeChartState extends State<TradeSetupNativeChart>
    with SingleTickerProviderStateMixin {
  List<OhlcBar> _bars = [];
  List<HaBar> _ha = [];
  VwapSeries? _vwap;
  List<FibLevel> _fibs = [];
  bool _loading = true;
  String? _error;
  Timer? _pollTimer;

  int _startIndex = 0;
  int _visibleCount = 72;
  double _baseScale = 1.0;
  double _pinchScale = 1.0;

  int? _tooltipIndex;
  late AnimationController _glowCtrl;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _load(initial: true);
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) => _load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final bars = await fetchTradeSetupKlines(
        coin: widget.symbol,
        timeframe: widget.timeframe,
      );
      if (!mounted) return;
      setState(() {
        _bars = bars;
        _ha = toHeikinAshi(bars);
        _vwap = computeVwap(bars);
        _fibs = computeFibLevels(bars);
        _loading = false;
        _error = null;
        if (initial && bars.length > _visibleCount) {
          _startIndex = bars.length - _visibleCount;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Chart data unavailable';
      });
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _baseScale = _pinchScale;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.scale != 1.0) {
      final next = (_baseScale * d.scale).clamp(0.45, 2.8);
      final newCount = (_visibleCount / next * _pinchScale).round().clamp(24, 280);
      setState(() {
        _pinchScale = next;
        _visibleCount = newCount;
        _clampStart();
      });
    } else if (d.focalPointDelta.dx.abs() > 0.5) {
      setState(() {
        _startIndex -= (d.focalPointDelta.dx / 6).round();
        _clampStart();
      });
    }
  }

  void _clampStart() {
    final maxStart = math.max(0, _bars.length - _visibleCount);
    _startIndex = _startIndex.clamp(0, maxStart);
  }

  ({double minY, double maxY}) _priceBounds(int start, int count) {
    final end = math.min(start + count, _bars.length);
    var minY = double.infinity;
    var maxY = -double.infinity;

    void consider(double v) {
      if (v > 0) {
        minY = math.min(minY, v);
        maxY = math.max(maxY, v);
      }
    }

    for (var i = start; i < end; i++) {
      consider(_ha[i].low);
      consider(_ha[i].high);
      if (_vwap != null) {
        consider(_vwap!.daily[i]);
      }
    }
    consider(_vwap?.prevDayFinal ?? 0);
    for (final f in _fibs) {
      consider(f.price);
    }
    consider(widget.entry ?? 0);
    consider(widget.tp1 ?? 0);
    consider(widget.tp2 ?? 0);
    consider(widget.sl ?? 0);

    if (!minY.isFinite || !maxY.isFinite) {
      return (minY: 0, maxY: 1);
    }
    final pad = (maxY - minY) * 0.08;
    return (minY: minY - pad, maxY: maxY + pad);
  }

  List<HorizontalLine> _horizontalLines(double glow) {
    final lines = <HorizontalLine>[];

    void addLevel({
      required double? price,
      required Color color,
      required String label,
      required double width,
      bool pulse = false,
    }) {
      if (price == null || price <= 0) return;
      final alpha = pulse ? 0.55 + glow * 0.45 : 0.85;
      lines.add(HorizontalLine(
        y: price,
        color: color.withValues(alpha: alpha),
        strokeWidth: width,
        dashArray: pulse ? [6, 4] : null,
        label: HorizontalLineLabel(
          show: true,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            shadows: [
              Shadow(color: color.withValues(alpha: 0.8), blurRadius: 8),
            ],
          ),
          labelResolver: (_) => label,
        ),
      ));
    }

    addLevel(
      price: _vwap?.prevDayFinal,
      color: _kPrevDayVwap,
      label: 'PREV DAY VWAP',
      width: 2.5,
    );
    for (final f in _fibs) {
      addLevel(price: f.price, color: f.color, label: f.label, width: 1.2);
    }
    addLevel(price: widget.entry, color: _kEntry, label: 'ENTRY', width: 2.5, pulse: true);
    addLevel(price: widget.tp1, color: _kTp1, label: 'TP1 40%', width: 2.2, pulse: true);
    addLevel(price: widget.tp2, color: _kTp2, label: 'TP2 60%', width: 2.2, pulse: true);
    addLevel(price: widget.sl, color: _kSl, label: 'STOP LOSS', width: 2.5, pulse: true);

    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _glowCtrl,
        builder: (context, _) {
          final glow = _glowCtrl.value;
          return _buildBody(glow);
        },
      ),
    );
  }

  Widget _buildBody(double glow) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: _kDailyVwap),
        ),
      );
    }
    if (_error != null || _bars.isEmpty) {
      return Center(
        child: Text(_error ?? 'No data', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
      );
    }

    final start = _startIndex;
    final count = math.min(_visibleCount, _bars.length - start);
    final bounds = _priceBounds(start, count);
    final minX = 0.0;
    final maxX = (count - 1).toDouble();

    final candleSpots = <CandlestickSpot>[];
    final vwapSpots = <FlSpot>[];
    for (var i = 0; i < count; i++) {
      final idx = start + i;
      final ha = _ha[idx];
      candleSpots.add(CandlestickSpot(
        x: i.toDouble(),
        open: ha.open,
        high: ha.high,
        low: ha.low,
        close: ha.close,
      ));
      if (_vwap != null) {
        vwapSpots.add(FlSpot(i.toDouble(), _vwap!.daily[idx]));
      }
    }

    final bodyWidth = math.max(2.0, 7.0 - count / 40);

    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: Stack(
        children: [
          // VWAP curve + labeled horizontal levels (behind candles)
          Padding(
            padding: const EdgeInsets.only(right: 52, top: 8, bottom: 28, left: 4),
            child: LineChart(
              LineChartData(
                minX: minX,
                maxX: maxX,
                minY: bounds.minY,
                maxY: bounds.maxY,
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                clipData: const FlClipData.all(),
                lineTouchData: const LineTouchData(enabled: false),
                extraLinesData: ExtraLinesData(
                  horizontalLines: _horizontalLines(glow),
                ),
                lineBarsData: vwapSpots.isEmpty
                    ? const []
                    : [
                        LineChartBarData(
                          spots: vwapSpots,
                          isCurved: false,
                          color: _kDailyVwap.withValues(alpha: 0.92),
                          barWidth: 3,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: _kDailyVwap.withValues(alpha: 0.06),
                          ),
                          shadow: Shadow(
                            color: _kDailyVwap.withValues(alpha: 0.35 + glow * 0.25),
                            blurRadius: 10,
                          ),
                        ),
                      ],
              ),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            ),
          ),
          // Heikin Ashi candles on top
          Padding(
            padding: const EdgeInsets.only(right: 52, top: 8, bottom: 28, left: 4),
            child: CandlestickChart(
              CandlestickChartData(
                backgroundColor: Colors.transparent,
                candlestickSpots: candleSpots,
                minX: minX,
                maxX: maxX,
                minY: bounds.minY,
                maxY: bounds.maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: (bounds.maxY - bounds.minY) / 5,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: _kGrid.withValues(alpha: 0.55),
                    strokeWidth: 0.6,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: _kGrid.withValues(alpha: 0.8)),
                ),
                titlesData: FlTitlesData(
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48,
                      interval: (bounds.maxY - bounds.minY) / 5,
                      getTitlesWidget: (v, _) => Text(
                        formatChartPrice(v),
                        style: TextStyle(color: Colors.grey[600], fontSize: 9),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: math.max(1, count / 5).toDouble(),
                      getTitlesWidget: (v, _) {
                        final i = start + v.round();
                        if (i < 0 || i >= _bars.length) return const SizedBox.shrink();
                        final dt = DateTime.fromMillisecondsSinceEpoch(_bars[i].timeSec * 1000, isUtc: true);
                        return Text(
                          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 8),
                        );
                      },
                    ),
                  ),
                  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                candlestickTouchData: CandlestickTouchData(
                  enabled: true,
                  touchCallback: (event, response) {
                    if (!event.isInterestedForInteractions) {
                      setState(() => _tooltipIndex = null);
                      return;
                    }
                    final idx = response?.touchedSpot?.spotIndex;
                    setState(() => _tooltipIndex = idx);
                  },
                ),
                candlestickPainter: DefaultCandlestickPainter(
                  candlestickStyleProvider: (spot, _) {
                    final up = spot.close >= spot.open;
                    final color = up ? _kHaUp : _kHaDown;
                    return CandlestickStyle(
                      lineColor: color,
                      lineWidth: 1,
                      bodyStrokeColor: color,
                      bodyStrokeWidth: 0.8,
                      bodyFillColor: color,
                      bodyWidth: bodyWidth,
                      bodyRadius: 1.2,
                    );
                  },
                ),
              ),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            ),
          ),
          // Header legend
          Positioned(
            top: 10,
            left: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.symbol.toUpperCase()}/USDT · ${widget.timeframe}',
                  style: const TextStyle(
                    color: Color(0xFFEAEAEA),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Color(0x6600BFFF), blurRadius: 10)],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _LegendDot(color: _kDailyVwap, label: 'Daily VWAP'),
                    const SizedBox(width: 8),
                    _LegendDot(color: _kPrevDayVwap, label: 'Prev VWAP'),
                    const SizedBox(width: 8),
                    _LiveDot(),
                  ],
                ),
              ],
            ),
          ),
          // Tooltip
          if (_tooltipIndex != null && _tooltipIndex! >= 0 && _tooltipIndex! < count)
            Positioned(
              top: 48,
              right: 58,
              child: _CandleTooltip(
                bar: _bars[start + _tooltipIndex!],
                ha: _ha[start + _tooltipIndex!],
                vwap: _vwap?.daily[start + _tooltipIndex!],
              ),
            ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 8, letterSpacing: 0.3)),
      ],
    );
  }
}

class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: Color.lerp(const Color(0xFF00E676), const Color(0xFF00E676).withValues(alpha: 0.3), _c.value),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: const Color(0xFF00E676).withValues(alpha: 0.7), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Text('LIVE', style: TextStyle(color: Colors.grey[500], fontSize: 8, letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

class _CandleTooltip extends StatelessWidget {
  final OhlcBar bar;
  final HaBar ha;
  final double? vwap;

  const _CandleTooltip({required this.bar, required this.ha, this.vwap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2332).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF00BFFF).withValues(alpha: 0.12), blurRadius: 12),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('O ${formatChartPrice(ha.open)}  H ${formatChartPrice(ha.high)}',
              style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
          Text('L ${formatChartPrice(ha.low)}  C ${formatChartPrice(ha.close)}',
              style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
          if (vwap != null)
            Text('VWAP ${formatChartPrice(vwap!)}',
                style: const TextStyle(color: _kDailyVwap, fontSize: 10, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

/// Glowing frame wrapper + fullscreen for Trade Setup native chart.
class TradeSetupChartPanel extends StatelessWidget {
  final String symbol;
  final String timeframe;
  final double? entry;
  final double? tp1;
  final double? tp2;
  final double? sl;
  final double height;

  const TradeSetupChartPanel({
    super.key,
    required this.symbol,
    required this.timeframe,
    this.entry,
    this.tp1,
    this.tp2,
    this.sl,
    this.height = 420,
  });

  void _openFullScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => TradeSetupFullScreenChart(
          symbol: symbol,
          timeframe: timeframe,
          entry: entry,
          tp1: tp1,
          tp2: tp2,
          sl: sl,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: _kChartBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00BFFF).withValues(alpha: 0.10),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Stack(
          children: [
            TradeSetupNativeChart(
              symbol: symbol,
              timeframe: timeframe,
              entry: entry,
              tp1: tp1,
              tp2: tp2,
              sl: sl,
              height: height,
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openFullScreen(context),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.fullscreen, color: Colors.white70, size: 22),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TradeSetupFullScreenChart extends StatelessWidget {
  final String symbol;
  final String timeframe;
  final double? entry;
  final double? tp1;
  final double? tp2;
  final double? sl;

  const TradeSetupFullScreenChart({
    super.key,
    required this.symbol,
    required this.timeframe,
    this.entry,
    this.tp1,
    this.tp2,
    this.sl,
  });

  @override
  Widget build(BuildContext context) {
    final sym = symbol.trim().toUpperCase();
    return Scaffold(
      backgroundColor: _kChartBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('$sym/USDT · $timeframe'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: TradeSetupNativeChart(
          symbol: symbol,
          timeframe: timeframe,
          entry: entry,
          tp1: tp1,
          tp2: tp2,
          sl: sl,
          height: MediaQuery.sizeOf(context).height - kToolbarHeight - MediaQuery.paddingOf(context).vertical,
        ),
      ),
    );
  }
}
