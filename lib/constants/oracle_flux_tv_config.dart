/// Published Oracle Flux TradingView study IDs (Trade Setup + Analysis charts only).
///
/// Home / Charts tab uses [buildTradingViewHTML] — unchanged.
abstract final class OracleFluxTvConfig {
  /// Oracle Flux overlay indicator (published on TradingView).
  static const indicatorStudyId = String.fromEnvironment(
    'ORACLE_FLUX_INDICATOR_STUDY',
    defaultValue: 'PUB;FuZ3wAGW',
  );

  /// Oracle Flux oscillator pane (published on TradingView).
  static const oscillatorStudyId = String.fromEnvironment(
    'ORACLE_FLUX_OSCILLATOR_STUDY',
    defaultValue: 'PUB;JAI7kwOr',
  );

  /// JSON entries for widget `studies` — ONLY these two scripts, nothing else.
  static String oracleFluxStudiesJson() {
    return '''
            {"id": "${indicatorStudyId.trim()}"},
            {"id": "${oscillatorStudyId.trim()}"}''';
  }
}
