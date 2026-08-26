// Curated Learning lessons — static copy so Free can read without Grok.

class OracleAcademyLesson {
  final String id;
  final String title;
  final String subtitle;
  final String body;

  const OracleAcademyLesson({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.body,
  });
}

abstract final class OracleAcademyLessons {
  static const List<OracleAcademyLesson> all = [
    OracleAcademyLesson(
      id: 'risk',
      title: 'Risk, R, and standing down',
      subtitle: 'Invalidation is the trade. Size is the job.',
      body: '''
Every setup in this app is built around R — how much you lose if you are wrong.

• Risk is the distance from entry to stop, in dollars of the position — not a vibe.
• Reward / risk on TP1 should clear about 2:1. If it does not, stand down. Flat is a position.
• Starting capital in Settings is the bankroll War Room uses. Risk % × leverage = how hard one stop hits the account.
• Invalidation is a price and a structure break, not “I feel it.” If Daily VWAP and the order block both fail, you are out.

NFA / DYOR — education only. Never size a live trade from a lesson.
''',
    ),
    OracleAcademyLesson(
      id: 'vwap',
      title: 'Daily VWAP — premium vs discount',
      subtitle: 'Where price is relative to the day’s volume-weighted mean.',
      body: '''
On-Chain Oracle AI reads Daily VWAP and Previous Day VWAP — not session VWAP jargon.

• Price above Daily VWAP = premium. Continuation longs want a reclaim + hold, not a chase into the high.
• Price below Daily VWAP = discount. Shorts want rejection of a reclaim, not a dump-low market order.
• A rip far above VWAP is extended. Vision will tell you to wait for a pullback to VWAP / support instead of FOMO.
• A flush far below VWAP on a bullish Daily is often a sweep. Wait for reclaim before you call a new short trend.

If the report and the VWAP fight each other, name the veto. Do not average into it.
''',
    ),
    OracleAcademyLesson(
      id: 'structure',
      title: 'Structure: sweep, BOS, FVG, order block',
      subtitle: 'The lexicon the daily reports actually use.',
      body: '''
This desk does not sell RSI chips. The language is market structure.

• Liquidity sweep / grab — price runs stops beyond equal highs or lows, then reverses.
• BOS (break of structure) — a close that confirms the new swing. CHOCH is the first opposing break.
• Order block — last opposing candle before displacement. Mitigation is the retest.
• FVG — fair value gap left by displacement. Often the magnet for a pullback.
• Inducement — the fake break that loads liquidity before the real move.

Trade Setup prints Entry / TP1 / TP2 / SL from this map. If those lines are missing, stand down and regenerate — do not invent them.
''',
    ),
    OracleAcademyLesson(
      id: 'pump-dump',
      title: 'Long vs short after a pump or dump',
      subtitle: 'What Oracle Vision is supposed to do after +15% days.',
      body: '''
Green 24h is not automatically a long. Red 24h is not automatically a short.

• After a pump: do not chase. Longs wait for pullback to support or Daily VWAP. A tactical short only if the Daily is actually bearish and you get rejection.
• After a dump: do not panic-short the low. Shorts wait for a bounce into resistance. A long only with sweep + reclaim of the level that broke.
• Mild bounce inside a bearish Daily is bear-rally fuel, not a squeeze long.

Oracle Vision tags these as Pullback to support or Bounce to resistance and caps conviction versus a clean trend day. That is the point of the desk.
''',
    ),
    OracleAcademyLesson(
      id: 'session',
      title: 'A session in this app',
      subtitle: 'Daily → Vision → Setup → close.',
      body: '''
1. Home — read Daily Oracle Bias and today’s BTC/ETH (and SOL/XRP) reports. That is the HTF vote.
2. Oracle Vision — what the market is doing live. If something is extended, wait. If it is aligned and not stretched, take it to Trade Setup.
3. Trade Setup — get the one-liner: Entry, TP1 (40%), TP2 (60%), SL, R:R. Save it. Set Guardians if you want alerts.
4. War Room / Desk — size from bankroll. Close the trade at a real exit so AI Alpha is honest.
5. Citadel is optional execute (Bitunix live / BloFin demo). Skip it until you understand steps 1–4.

NFA / DYOR. This is a workflow, not a signal service.
''',
    ),
  ];

  static OracleAcademyLesson? byId(String id) {
    for (final lesson in all) {
      if (lesson.id == id) return lesson;
    }
    return null;
  }
}
