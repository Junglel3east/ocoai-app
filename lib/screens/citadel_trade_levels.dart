// ─── Oracle Citadel trade level extraction (parsing only — prompts unchanged) ─
//
// Mirrors backend parse_trade_levels: multiple regex + keyword fallbacks for
// Entry, Stop Loss, TP1, TP2, and R:R when AI wording varies slightly.
//
part of '../main.dart';

/// Parsed levels for Send-to-Citadel validation.
class CitadelParsedLevels {
  final double? entry;
  final double? tp1;
  final double? tp2;
  final double? sl;
  final double? rr;

  const CitadelParsedLevels({
    this.entry,
    this.tp1,
    this.tp2,
    this.sl,
    this.rr,
  });

  static const _labels = {
    'entry': 'Entry',
    'tp1': 'TP1',
    'tp2': 'TP2',
    'sl': 'Stop Loss',
  };

  /// Missing fields required by Oracle Citadel execute flow.
  List<String> get missingLabels {
    final out = <String>[];
    if (entry == null) out.add(_labels['entry']!);
    if (tp1 == null) out.add(_labels['tp1']!);
    if (tp2 == null) out.add(_labels['tp2']!);
    if (sl == null) out.add(_labels['sl']!);
    return out;
  }

  bool get isComplete => missingLabels.isEmpty;

  String? get userErrorMessage {
    if (isComplete) return null;
    return 'Could not find ${missingLabels.join(', ')} in this report. '
        'Add TRADE LEVELS: Entry at \$X, TP1 at \$X, TP2 at \$X, SL at \$X (R:R X.X:1).';
  }
}

String _normalizeReportForParsing(String input) {
  return input.replaceAll(RegExp(r'\*+'), '').replaceAll('—', '-').replaceAll('–', '-');
}

double? _parsePriceToken(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var cleaned = raw.trim().replaceAll(',', '').replaceAll(' ', '');
  cleaned = cleaned.replaceAll(RegExp(r'[^\d.]+$'), '');
  return double.tryParse(cleaned);
}

double? _firstMatchPrice(String text, List<RegExp> patterns) {
  for (final pattern in patterns) {
    final match = pattern.firstMatch(text);
    if (match != null) {
      final price = _parsePriceToken(match.group(1));
      if (price != null && price > 0) return price;
    }
  }
  return null;
}

/// Multi-pattern extraction — keep in sync with backend parse_trade_levels.
CitadelParsedLevels parseCitadelTradeLevels(String report) {
  final text = _normalizeReportForParsing(report);

  double? entry;
  double? tp1;
  double? tp2;
  double? sl;
  double? rr;

  // Canonical: Entry at $X, TP1 at $X, TP2 at $X, SL at $X
  final canonical = RegExp(
    r'entry\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
    r'.{0,120}?tp\s*[-_]?\s*1\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
    r'.{0,120}?tp\s*[-_]?\s*2\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
    r'.{0,120}?s(?:top\s*[-_]?\s*loss|l)\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
    caseSensitive: false,
    dotAll: true,
  );
  final canonMatch = canonical.firstMatch(text);
  if (canonMatch != null) {
    entry = _parsePriceToken(canonMatch.group(1));
    tp1 = _parsePriceToken(canonMatch.group(2));
    tp2 = _parsePriceToken(canonMatch.group(3));
    sl = _parsePriceToken(canonMatch.group(4));
  } else {
    // Alternate ordering: TP1, TP2, SL, then Entry
    final alt = RegExp(
      r'tp\s*[-_]?\s*1\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
      r'.{0,120}?tp\s*[-_]?\s*2\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
      r'.{0,120}?s(?:top\s*[-_]?\s*loss|l)\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)'
      r'.{0,120}?entry\s+at\s+\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
      dotAll: true,
    );
    final altMatch = alt.firstMatch(text);
    if (altMatch != null) {
      tp1 = _parsePriceToken(altMatch.group(1));
      tp2 = _parsePriceToken(altMatch.group(2));
      sl = _parsePriceToken(altMatch.group(3));
      entry = _parsePriceToken(altMatch.group(4));
    }
  }

  final entryPatterns = [
    RegExp(
      r'(?:^|[\n\r\*\-])\s*entry(?:\s+price|\s+zone|\s+level)?\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
      multiLine: true,
    ),
    RegExp(r'entry\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
    RegExp(r'buy\s+(?:at|@|:)\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
  ];
  final tp1Patterns = [
    RegExp(r'tp\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
    RegExp(
      r'take\s*[-_]?\s*profit\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ),
    RegExp(r'target\s*[-_]?\s*1\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
    RegExp(r't\.?p\.?\s*1\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
  ];
  final tp2Patterns = [
    RegExp(r'tp\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
    RegExp(
      r'take\s*[-_]?\s*profit\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ),
    RegExp(r'target\s*[-_]?\s*2\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
    RegExp(r't\.?p\.?\s*2\s*[=:]\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
  ];
  final slPatterns = [
    RegExp(
      r's(?:top\s*[-_]?\s*loss|l)\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ),
    RegExp(
      r'stop\s*[-_]?\s*loss\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
      caseSensitive: false,
    ),
    RegExp(r'invalidation\s*(?:at|@|:|is|=|-)?\s*\$?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', caseSensitive: false),
  ];

  entry ??= _firstMatchPrice(text, entryPatterns);
  tp1 ??= _firstMatchPrice(text, tp1Patterns);
  tp2 ??= _firstMatchPrice(text, tp2Patterns);
  sl ??= _firstMatchPrice(text, slPatterns);

  final rrPatterns = [
    RegExp(
      r'(?:r\s*:?\s*r|risk\s*[-:]?\s*reward)\s*(?:ratio)?\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)\s*:?\s*1',
      caseSensitive: false,
    ),
  ];
  rr = _firstMatchPrice(text, rrPatterns);

  if (rr == null && entry != null && tp1 != null && sl != null) {
    final risk = (entry - sl).abs();
    final reward = (tp1 - entry).abs();
    if (risk > 0) rr = reward / risk;
  }

  return CitadelParsedLevels(entry: entry, tp1: tp1, tp2: tp2, sl: sl, rr: rr);
}

/// Legacy single-key helper — delegates to [parseCitadelTradeLevels] field patterns.
double? extractTradeLevel(String input, List<String> keys) {
  final parsed = parseCitadelTradeLevels(input);
  final lowerKeys = keys.map((k) => k.toLowerCase()).toList();
  if (lowerKeys.any((k) => k.contains('entry'))) return parsed.entry;
  if (lowerKeys.any((k) => k.contains('tp1') || k.contains('take profit 1') || k.contains('target 1'))) {
    return parsed.tp1;
  }
  if (lowerKeys.any((k) => k.contains('tp2') || k.contains('take profit 2') || k.contains('target 2'))) {
    return parsed.tp2;
  }
  if (lowerKeys.any((k) => k.contains('sl') || k.contains('stop'))) return parsed.sl;
  return null;
}
