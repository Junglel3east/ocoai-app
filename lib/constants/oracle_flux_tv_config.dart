/// Published Oracle Flux TradingView study IDs — manual load only (Add Flux Tools button).
///
/// Analysis / Trade Setup charts start with no extra scripts. Home tab uses [buildTradingViewHTML].
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

  /// JSON entries for widget `studies` — used only when user taps Add Flux Tools.
  static String oracleFluxStudiesJson() {
    return '''
            {"id": "${indicatorStudyId.trim()}"},
            {"id": "${oscillatorStudyId.trim()}"}''';
  }
}
