// Analysis, review, and trade setup result screens + API retry helpers.

part of '../main.dart';

// Analysis Report
class AnalysisReportScreen extends StatefulWidget {
  final String? coin;
  final Map<String, dynamic>? historyItem;
  final void Function(String coin, String report)? onNewAnalysis;

  const AnalysisReportScreen({super.key, this.coin, this.historyItem, this.onNewAnalysis});
  factory AnalysisReportScreen.fromHistory(Map<String, dynamic> item) => AnalysisReportScreen(coin: item['coin'], historyItem: item);
  @override
  State<AnalysisReportScreen> createState() => _AnalysisReportScreenState();
}

class _AnalysisReportScreenState extends State<AnalysisReportScreen> {
  String report = "Loading...";
  bool loading = true;
  late final String resolvedCoin;
  WebViewController? _chartController;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(
          (widget.coin ?? widget.historyItem?['coin'] ?? 'BTC').toString(),
        ) ??
        'BTC';
    if (widget.historyItem != null) {
      report = widget.historyItem!['report'];
      loading = false;
      _chartController = createTradeSetupTradingViewController(resolvedCoin, timeframe: '1h');
    } else {
      _fetchFromBackend();
    }
  }

  void _ensureChartController() {
    _chartController ??= createTradeSetupTradingViewController(resolvedCoin, timeframe: '1h');
  }

  Future<void> _fetchFromBackend() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final fluxFields = await _analyzeFluxFields(resolvedCoin, '1h');
      final response = await _postAnalyzeWithRetry(
        payload: {
          "coin": resolvedCoin,
          "mode": "analysis",
          "timeframe": "1h",
          "direction": "Smart Direction",
          "report_style": "professional",
          "system_prompt": grokSystemPrompt(mode: "analysis"),
          "refresh_price": true,
          "request_ts": DateTime.now().millisecondsSinceEpoch,
          ..._analyzeCitadelContext(),
          ...fluxFields,
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          report = data['report'] ?? "No report";
          loading = false;
          _ensureChartController();
        });
        if (widget.onNewAnalysis != null) {
          widget.onNewAnalysis!(resolvedCoin, report);
        }
      } else {
        debugPrint('[Analysis] HTTP ${response.statusCode}: ${response.body}');
        setState(() {
          errorMessage = "Unable to generate analysis right now. Please try again.";
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('[Analysis] Request failed: $e');
      setState(() {
        errorMessage = "Cannot connect to backend. Check API server and retry.";
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(resolvedCoin),
        actions: [
          if (!loading && errorMessage == null)
            IconButton(
              tooltip: 'Push to X',
              icon: const Icon(Icons.north_east),
              onPressed: () => XShareService.showComposeSheet(
                context,
                initialText: XShareService.formatAnalysisPost(
                  coin: resolvedCoin,
                  report: report,
                ),
                title: 'Share $resolvedCoin Analysis',
              ),
            ),
        ],
      ),
      floatingActionButton: loading || errorMessage != null
          ? null
          : CompactChatFab(
              heroTag: 'analysis_chat_$resolvedCoin',
              onPressed: () => openAiChat(context),
            ),
      body: loading
          ? const _PremiumAiLoadingPanel(
              title: 'Generating Analysis',
              subtitle: 'Fetching live price and building your Oracle report…',
            )
          : errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _fetchFromBackend,
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen + reportScrollBottomInset(context),
              ),
              child: Column(
                children: [
                  if (_chartController != null)
                    TradingViewChartPanel(
                      symbol: resolvedCoin,
                      controller: _chartController!,
                      tradeSetupTimeframe: '1h',
                    ),
                  const SizedBox(height: _AppSpacing.section),
                  OracleReportText(report),
                  const SizedBox(height: _AppSpacing.section),
                  PushToXButton(
                    initialText: XShareService.formatAnalysisPost(
                      coin: resolvedCoin,
                      report: report,
                    ),
                    sheetTitle: 'Share $resolvedCoin Analysis',
                  ),
                  const SizedBox(height: _AppSpacing.item),
                  SendToCitadelButton(
                    coin: resolvedCoin,
                    directionLabel: 'Smart Direction',
                    reportText: report,
                  ),
                ],
              ),
            ),
    );
  }
}

/// Renders Oracle Analyze / Trade Setup reports — bold headings without raw `**` markers.
class OracleReportText extends StatelessWidget {
  final String report;

  const OracleReportText(this.report, {super.key});

  static final _headingLine = RegExp(r'^\*\*(.+?)\*\*\s*$');
  static final _boldInline = RegExp(r'\*\*(.+?)\*\*');

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: 16, height: 1.65, color: Colors.grey[100]);
    return SelectableText.rich(
      TextSpan(style: base, children: _buildSpans(report, base)),
    );
  }

  static List<InlineSpan> _buildSpans(String raw, TextStyle base) {
    final out = <InlineSpan>[];
    final lines = raw.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) out.add(const TextSpan(text: '\n'));
      final line = lines[i];
      final heading = _headingLine.firstMatch(line);
      if (heading != null) {
        out.add(
          TextSpan(
            text: heading.group(1),
            style: base.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 17,
              color: const Color(0xFF00BFFF),
            ),
          ),
        );
        continue;
      }
      out.addAll(_inlineSpans(line, base));
    }
    return out;
  }

  static List<InlineSpan> _inlineSpans(String line, TextStyle base) {
    final out = <InlineSpan>[];
    var start = 0;
    for (final match in _boldInline.allMatches(line)) {
      if (match.start > start) {
        out.add(TextSpan(text: line.substring(start, match.start)));
      }
      out.add(
        TextSpan(
          text: match.group(1),
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
      start = match.end;
    }
    if (start < line.length) {
      out.add(TextSpan(text: line.substring(start)));
    }
    if (out.isEmpty) out.add(const TextSpan(text: ''));
    return out;
  }
}

// Review Report — Telegram-bot style review via POST /review
class ReviewReportScreen extends StatefulWidget {
  final Map<String, dynamic> historyItem;

  const ReviewReportScreen({super.key, required this.historyItem});

  @override
  State<ReviewReportScreen> createState() => _ReviewReportScreenState();
}

class _ReviewReportScreenState extends State<ReviewReportScreen> {
  String? reviewText;
  bool loading = true;
  String? errorMessage;
  late final String resolvedCoin;
  late final String storedReport;
  late final bool isTradeSetup;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(widget.historyItem['coin']?.toString() ?? 'BTC') ?? 'BTC';
    storedReport = (widget.historyItem['report'] ?? '').toString();
    isTradeSetup = widget.historyItem['source'] == 'trade_setup';
    _fetchReview();
  }

  Future<void> _fetchReview() async {
    setState(() {
      loading = true;
      errorMessage = null;
      reviewText = null;
    });

    if (isPlaceholderStoredReport(storedReport)) {
      setState(() {
        errorMessage = isTradeSetup
            ? 'No saved report for this trade — run Trade Setup again to generate a fresh report.'
            : 'No stored report found for this item.';
        loading = false;
      });
      return;
    }

    try {
      final response = await _postReviewWithRetry(
        coin: resolvedCoin,
        previousReport: storedReport,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          reviewText = (data['review'] ?? data['report'] ?? '').toString();
          if (reviewText!.trim().isEmpty) {
            errorMessage = "Backend returned an empty review.";
            reviewText = null;
          }
          loading = false;
        });
      } else {
        setState(() {
          errorMessage = "Unable to generate review (${response.statusCode}). Please try again.";
          loading = false;
        });
      }
    } catch (_) {
      setState(() {
        errorMessage = "Cannot connect to backend. Check API server and retry.";
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = isTradeSetup
        ? "Review of $resolvedCoin Trade"
        : "Review of $resolvedCoin Analysis";

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text("Review"),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      floatingActionButton: CompactChatFab(
        heroTag: 'review_chat_$resolvedCoin',
        onPressed: () => openAiChat(context),
      ),
      body: loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00BFFF)),
                  SizedBox(height: 16),
                  Text("Generating review...", style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : errorMessage != null
              ? _AppEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Something went wrong',
                  subtitle: errorMessage!,
                  action: ElevatedButton(
                    onPressed: _fetchReview,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BFFF),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Retry'),
                  ),
                )
              : SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.all(_AppSpacing.screen),
                  child: _FadeIn(
                    child: _ReviewFormattedContent(
                      title: title,
                      reviewText: reviewText!,
                    ),
                  ),
                ),
    );
  }
}

/// Parses Telegram-style review text into structured sections for display.
class _ParsedReview {
  final String? score;
  final String? whatGotRight;
  final String? whatDidnt;
  final String? currentStatus;
  final String fallbackBody;

  const _ParsedReview({
    this.score,
    this.whatGotRight,
    this.whatDidnt,
    this.currentStatus,
    required this.fallbackBody,
  });

  factory _ParsedReview.fromText(String text) {
    final scoreMatch = RegExp(r'Score:\s*([\d.]+)\s*/\s*10', caseSensitive: false).firstMatch(text);
    final score = scoreMatch?.group(1);

    String? extractSection(String source, List<String> headers) {
      for (final header in headers) {
        final pattern = RegExp(
          r'(?:^|\n)\s*[*#\-]*\s*' +
              RegExp.escape(header) +
              r'\s*[*#:\-]*\s*\n([\s\S]*?)(?=\n\s*[*#\-]*\s*(?:What|Current|Score|$)|$)',
          caseSensitive: false,
        );
        final match = pattern.firstMatch(source);
        if (match != null) {
          final body = match.group(1)?.trim();
          if (body != null && body.isNotEmpty) return body;
        }
      }
      return null;
    }

    return _ParsedReview(
      score: score,
      whatGotRight: extractSection(text, ['What got right', 'What went right', 'What was right']),
      whatDidnt: extractSection(text, ["What didn't", "What did not", "What went wrong", "What was wrong"]),
      currentStatus: extractSection(text, ['Current Status', 'Current status', 'Status']),
      fallbackBody: text.trim(),
    );
  }

  bool get hasStructuredSections =>
      whatGotRight != null || whatDidnt != null || currentStatus != null;
}

class _ReviewFormattedContent extends StatelessWidget {
  final String title;
  final String reviewText;

  const _ReviewFormattedContent({
    required this.title,
    required this.reviewText,
  });

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedReview.fromText(reviewText);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1A1A1A),
                const Color(0xFF00BFFF).withValues(alpha: 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              if (parsed.score != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    "Score: ${parsed.score}/10",
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00BFFF),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (parsed.hasStructuredSections) ...[
          if (parsed.whatGotRight != null)
            _ReviewSectionCard(
              title: "What Got Right",
              body: parsed.whatGotRight!,
              icon: Icons.check_circle_outline,
              accentColor: const Color(0xFF00E676),
            ),
          if (parsed.whatDidnt != null)
            _ReviewSectionCard(
              title: "What Didn't",
              body: parsed.whatDidnt!,
              icon: Icons.cancel_outlined,
              accentColor: const Color(0xFFFF5252),
            ),
          if (parsed.currentStatus != null)
            _ReviewSectionCard(
              title: "Current Status",
              body: parsed.currentStatus!,
              icon: Icons.insights_outlined,
              accentColor: const Color(0xFF00BFFF),
            ),
        ] else
          _ReviewSectionCard(
            title: "Review",
            body: parsed.fallbackBody,
            icon: Icons.rate_review_outlined,
            accentColor: const Color(0xFF00BFFF),
          ),
      ],
    );
  }
}

class _ReviewSectionCard extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  final Color accentColor;

  const _ReviewSectionCard({
    required this.title,
    required this.body,
    required this.icon,
    required this.accentColor,
  });

  List<String> _bulletLines(String text) {
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.replaceFirst(RegExp(r'^[-•*]\s*'), ''))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final bullets = _bulletLines(body);
    final useBullets = bullets.length > 1 || body.contains(RegExp(r'^\s*[-•*]', multiLine: true));

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (useBullets)
            ...bullets.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        line,
                        style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[300]),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Text(
              body,
              style: TextStyle(fontSize: 14, height: 1.6, color: Colors.grey[300]),
            ),
        ],
      ),
    );
  }
}

Future<http.Response> _postReviewWithRetry({
  required String coin,
  required String previousReport,
  int attempts = 3,
}) async {
  Object? lastError;
  final payload = {
    "coin": coin,
    "previous_report": previousReport,
    ...TradingVenueStore.analyzePayloadFields(),
  };

  for (int i = 0; i < attempts; i++) {
    try {
      final uri = Uri.parse('$kBackendBaseUrl/review');
      debugPrint('[HTTP POST] $uri coin=$coin (attempt ${i + 1}/$attempts)');
      final response = await http
          .post(
            uri,
            headers: {
              "Content-Type": "application/json",
              "Cache-Control": "no-cache, no-store, must-revalidate",
              "Pragma": "no-cache",
              "Expires": "0",
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 90));
      debugPrint('[HTTP POST] $uri → ${response.statusCode}');
      if (response.statusCode >= 500 && i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        continue;
      }
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] review attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception("Unknown review request error");
}

// Trade Setup result screen with chart + full report
class TradeSetupResultScreen extends StatefulWidget {
  final String coin;
  final String timeframe;
  final String direction;
  final Function(Map<String, dynamic>) onTradeSetupGenerated;
  /// Oracle Vision prefill — passed to backend for confluence-aware levels.
  final int? convictionPct;

  const TradeSetupResultScreen({
    super.key,
    required this.coin,
    required this.timeframe,
    required this.direction,
    required this.onTradeSetupGenerated,
    this.convictionPct,
  });

  @override
  State<TradeSetupResultScreen> createState() => _TradeSetupResultScreenState();
}

class _TradeSetupResultScreenState extends State<TradeSetupResultScreen> {
  String report = "Loading...";
  bool loading = true;
  bool _saved = false;
  late final String resolvedCoin;
  WebViewController? _chartController;
  String? errorMessage;
  double? _entry;
  double? _tp1;
  double? _tp2;
  double? _sl;

  @override
  void initState() {
    super.initState();
    resolvedCoin = CoinAccessPolicy.normalizeCoinSymbol(widget.coin) ?? widget.coin.trim().toUpperCase();
    // Clear stale Citadel error snackbars from prior sends (e.g. IP whitelist) on this scaffold.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
    });
    _fetchTradeSetup();
  }

  void _ensureChartController() {
    _chartController ??= createTradeSetupTradingViewController(
      resolvedCoin,
      timeframe: widget.timeframe,
    );
  }

  Future<void> _fetchTradeSetup() async {
    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      final visionHint = widget.convictionPct != null
          ? '\n\nOracle Vision pulse: ${widget.convictionPct}% ${widget.direction} confluence on ${widget.timeframe}. '
              'Honor bias when grading Daily VWAP, structure, and Entry/SL/TP1 (40%)/TP2 (60%).'
          : '';
      final fluxFields = await _analyzeFluxFields(resolvedCoin, widget.timeframe);
      final response = await _postAnalyzeWithRetry(
        payload: {
          "coin": resolvedCoin,
          "mode": "tradesetup",
          "timeframe": widget.timeframe,
          "direction": widget.direction,
          "report_style": "professional",
          "system_prompt": grokSystemPrompt(mode: "tradesetup") + visionHint,
          "refresh_price": true,
          "request_ts": DateTime.now().millisecondsSinceEpoch,
          if (widget.convictionPct != null) "vision_confluence_pct": widget.convictionPct,
          ..._analyzeCitadelContext(),
          ...fluxFields,
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final fetchedReport = (data['report'] ?? 'No report').toString();
        setState(() {
          report = fetchedReport;
          loading = false;
          _ensureChartController();
        });
        _saveTradeSetupIfNeeded(fetchedReport);
      } else {
        debugPrint('[TradeSetup] HTTP ${response.statusCode}: ${response.body}');
        setState(() {
          errorMessage = "Failed to generate trade setup (${response.statusCode}). Please try again.";
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('[TradeSetup] Request failed: $e');
      setState(() {
        errorMessage = "Cannot connect to backend. Please retry in a moment.";
        loading = false;
      });
    }
  }

  void _saveTradeSetupIfNeeded(String reportText) {
    if (_saved) return;
    if (isPlaceholderStoredReport(reportText)) return;
    _saved = true;
    final parsed = parseCitadelTradeLevels(reportText);
    _entry = parsed.entry;
    _tp1 = parsed.tp1;
    _tp2 = parsed.tp2;
    _sl = parsed.sl;
    widget.onTradeSetupGenerated({
      "coin": resolvedCoin,
      "report": reportText,
      "timeframe": widget.timeframe,
      "direction": widget.direction,
      "entry": _entry,
      "tp1": _tp1,
      "tp2": _tp2,
      "sl": _sl,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("$resolvedCoin Trade Setup")),
      floatingActionButton: loading || errorMessage != null
          ? null
          : CompactChatFab(
              heroTag: 'tradesetup_chat_$resolvedCoin',
              onPressed: () => openAiChat(context),
            ),
      body: loading
          ? const _PremiumAiLoadingPanel(
              title: 'Generating Trade Setup',
              subtitle: 'Building levels, R:R, and confluence for your plan…',
            )
          : errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(errorMessage!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _fetchTradeSetup,
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
          : SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen,
                _AppSpacing.screen + reportScrollBottomInset(context),
              ),
              child: Column(
                children: [
                  if (_chartController != null)
                    TradingViewChartPanel(
                      symbol: resolvedCoin,
                      controller: _chartController!,
                      tradeSetupTimeframe: widget.timeframe,
                      premiumFrame: true,
                    ),
                  const SizedBox(height: _AppSpacing.section),
                  OracleReportText(report),
                  const SizedBox(height: _AppSpacing.section),
                  SendToCitadelButton(
                    coin: resolvedCoin,
                    directionLabel: widget.direction,
                    reportText: report,
                    entry: _entry,
                    stopLoss: _sl,
                    tp1: _tp1,
                    tp2: _tp2,
                  ),
                ],
              ),
            ),
    );
  }
}

Future<http.Response> _postAnalyzeWithRetry({
  required Map<String, dynamic> payload,
  int attempts = 3,
}) async {
  Object? lastError;
  final uri = Uri.parse('$kBackendBaseUrl/analyze');
  final body = jsonEncode(payload);
  final authHeaders = await AppApiKeyService.backendHeaders();
  debugPrint('[HTTP POST] $uri mode=${payload['mode']} coin=${payload['coin']}');

  for (int i = 0; i < attempts; i++) {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              ...authHeaders,
              "Cache-Control": "no-cache, no-store, must-revalidate",
              "Pragma": "no-cache",
              "Expires": "0",
            },
            body: body,
          )
          // Grok can take up to ~90s — 15s timeout caused false "Cannot connect" errors.
          .timeout(const Duration(seconds: 90));
      debugPrint('[HTTP POST] $uri → ${response.statusCode} (attempt ${i + 1}/$attempts)');
      if (response.statusCode >= 500 && i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
        continue;
      }
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] $uri attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception("Unknown analyze request error");
}

Future<http.Response> _postChatWithRetry({
  required String message,
  required List<Map<String, String>> history,
  required String systemPrompt,
  int attempts = 3,
}) async {
  Object? lastError;
  final uri = Uri.parse('$kBackendBaseUrl/chat');
  final payload = {
    'message': message,
    'history': history,
    'system_prompt': systemPrompt,
    'request_ts': DateTime.now().millisecondsSinceEpoch,
    ...TradingVenueStore.analyzePayloadFields(),
  };
  final body = jsonEncode(payload);
  debugPrint('[HTTP POST] $uri chat message length=${message.length}');

  for (int i = 0; i < attempts; i++) {
    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Cache-Control': 'no-cache, no-store, must-revalidate',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 90));
      return response;
    } catch (e) {
      lastError = e;
      debugPrint('[HTTP POST] $uri attempt ${i + 1} failed: $e');
      if (i < attempts - 1) {
        await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
  }
  throw lastError ?? Exception('Unknown chat request error');
}
