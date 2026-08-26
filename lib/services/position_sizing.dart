/// Citadel-style sizing: margin = bankroll × risk%, notional = margin × leverage.
abstract final class PositionSizing {
  static double marginUsd(double capital, double riskPercent) {
    return capital.clamp(0.0, 1000000.0) * (riskPercent.clamp(0.1, 100.0) / 100.0);
  }

  static double notionalUsd(double capital, double riskPercent, double leverage) {
    return marginUsd(capital, riskPercent) * leverage.clamp(1.0, 100.0);
  }

  static double stopRiskUsd({
    required double capital,
    required double riskPercent,
    required double leverage,
    required double entry,
    required double sl,
  }) {
    if (entry.abs() < 1e-12) return 0;
    final stopPct = (entry - sl).abs() / entry.abs();
    return notionalUsd(capital, riskPercent, leverage) * stopPct;
  }

  static String formatUsd(double value) {
    final abs = value.abs();
    final sign = value < 0 ? '-' : '';
    if (abs >= 1000000) {
      final n = abs / 1000000;
      final decimals = (n - n.round()).abs() < 1e-9 ? 0 : 2;
      return '$sign\$${n.toStringAsFixed(decimals)}M';
    }
    if (abs >= 1000) {
      return '$sign\$${_withCommas(abs.round())}';
    }
    if (abs >= 100) return '$sign\$${abs.toStringAsFixed(0)}';
    if (abs >= 1) return '$sign\$${abs.toStringAsFixed(2)}';
    return '$sign\$${abs.toStringAsFixed(2)}';
  }

  static String _withCommas(int n) {
    final raw = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final fromEnd = raw.length - i;
      buf.write(raw[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  static String formulaLine({
    required double capital,
    required double riskPercent,
    required double leverage,
  }) {
    final riskLabel = riskPercent == riskPercent.roundToDouble()
        ? '${riskPercent.round()}'
        : riskPercent.toStringAsFixed(1);
    return '${formatUsd(capital)} × $riskLabel% × ${leverage.round()}x';
  }

  static String breakdownLine({
    required double capital,
    required double riskPercent,
    required double leverage,
    double? entry,
    double? sl,
  }) {
    final margin = marginUsd(capital, riskPercent);
    final notional = notionalUsd(capital, riskPercent, leverage);
    final base = '${formatUsd(margin)} margin / ${formatUsd(notional)} notional';
    if (entry == null || sl == null || entry.abs() < 1e-12) return base;
    final stop = stopRiskUsd(
      capital: capital,
      riskPercent: riskPercent,
      leverage: leverage,
      entry: entry,
      sl: sl,
    );
    return '$base · stop risk ${formatUsd(stop)}';
  }
}
