/// Public Oracle Flux TradingView study IDs — manual load only (Indicators button).
///
/// Analysis / Trade Setup charts start with no extra scripts. Home tab uses [buildTradingViewHTML].
abstract final class OracleFluxTvConfig {
  /// Oracle Flux overlay indicator (public on TradingView).
  static const indicatorStudyId = String.fromEnvironment(
    'ORACLE_FLUX_INDICATOR_STUDY',
    defaultValue: 'mQP80cUC',
  );

  /// Oracle Flux oscillator pane (public on TradingView).
  static const oscillatorStudyId = String.fromEnvironment(
    'ORACLE_FLUX_OSCILLATOR_STUDY',
    defaultValue: 'mUlI6Xj4',
  );

  static const indicatorLabel = 'Oracle Flux';
  static const indicatorSubtitle = 'Main Indicator';
  static const oscillatorLabel = 'Oracle Flux Oscillator';
  static const oscillatorSubtitle = 'Momentum & Money Flow pane';

  /// TradingView widget expects published scripts as `PUB;<scriptId>`.
  static String tradingViewStudyId(String raw) {
    final id = raw.trim();
    if (id.isEmpty) return id;
    if (id.startsWith('PUB;')) return id;
    return 'PUB;$id';
  }

  /// JSON entries for widget `studies` — only selected scripts (manual Indicators panel).
  static String oracleFluxStudiesJson({
    bool includeIndicator = false,
    bool includeOscillator = false,
  }) {
    final lines = <String>[];
    if (includeIndicator) {
      lines.add('{"id": "${tradingViewStudyId(indicatorStudyId)}"}');
    }
    if (includeOscillator) {
      lines.add('{"id": "${tradingViewStudyId(oscillatorStudyId)}"}');
    }
    return lines.join(',\n            ');
  }
}
