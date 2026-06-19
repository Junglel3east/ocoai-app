/// Public Oracle Flux TradingView study IDs — manual load only (Add Flux Tools button).
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

  /// TradingView widget expects published scripts as `PUB;<scriptId>`.
  static String tradingViewStudyId(String raw) {
    final id = raw.trim();
    if (id.isEmpty) return id;
    if (id.startsWith('PUB;')) return id;
    return 'PUB;$id';
  }

  /// JSON entries for widget `studies` — used only when user taps Add Flux Tools.
  static String oracleFluxStudiesJson() {
    final indicator = tradingViewStudyId(indicatorStudyId);
    final oscillator = tradingViewStudyId(oscillatorStudyId);
    return '''
            {"id": "$indicator"},
            {"id": "$oscillator"}''';
  }
}
