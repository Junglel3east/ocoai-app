import 'package:flutter_test/flutter_test.dart';

import 'package:on_chain_oracle_ai/main.dart';
import 'package:on_chain_oracle_ai/services/position_sizing.dart';

void main() {
  group('PositionSizing', () {
    test('margin is bankroll × risk%, notional is margin × leverage', () {
      expect(PositionSizing.marginUsd(1000, 5), closeTo(50, 1e-9));
      expect(PositionSizing.notionalUsd(1000, 5, 10), closeTo(500, 1e-9));
    });

    test('stop risk scales with stop distance', () {
      final risk = PositionSizing.stopRiskUsd(capital: 1000, riskPercent: 5, leverage: 10, entry: 100, sl: 95);
      expect(risk, closeTo(25, 1e-9));
      expect(PositionSizing.stopRiskUsd(capital: 1000, riskPercent: 5, leverage: 10, entry: 0, sl: 1), 0);
    });

    test('inputs are clamped to safe ranges', () {
      expect(PositionSizing.notionalUsd(1000, 5, 500), closeTo(5000, 1e-9), reason: 'leverage capped at 100x');
      expect(PositionSizing.marginUsd(-50, 5), 0);
    });

    test('formatUsd', () {
      expect(PositionSizing.formatUsd(1234567), r'$1.23M');
      expect(PositionSizing.formatUsd(12345), r'$12,345');
      expect(PositionSizing.formatUsd(-3.5), r'-$3.50');
    });
  });

  group('parseCitadelTradeLevels', () {
    test('canonical TRADE LEVELS line', () {
      final levels = parseCitadelTradeLevels(
        '**TRADE LEVELS**: Entry at \$64,250.5, TP1 (40%) at \$66,000, TP2 (60%) at \$68,500, '
        'SL at \$62,900 (R:R 2.1:1)',
      );
      expect(levels.isComplete, isTrue);
      expect(levels.entry, 64250.5);
      expect(levels.tp1, 66000);
      expect(levels.tp2, 68500);
      expect(levels.sl, 62900);
    });

    test('reports missing levels instead of guessing', () {
      final levels = parseCitadelTradeLevels('Entry at \$100, TP1 (40%) at \$110');
      expect(levels.isComplete, isFalse);
      expect(levels.missingLabels, containsAll(['TP2', 'Stop Loss']));
      expect(levels.userErrorMessage, isNotNull);
    });
  });
}
