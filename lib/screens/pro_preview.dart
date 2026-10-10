// One-time Oracle Pro preview — Free users try any symbol / timeframe before being asked to pay.

part of '../main.dart';

abstract final class ProPreviewStore {
  static const _startedKey = 'pro_preview_started_ms';
  static const window = Duration(minutes: 30);

  static DateTime? _startedAt;
  static bool _loaded = false;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_startedKey);
    _startedAt = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    _loaded = true;
  }

  /// Unlocks analysis gates (symbols, timeframes, setup count) — not Citadel or chat.
  static bool get isActive =>
      _startedAt != null && DateTime.now().difference(_startedAt!) < window;

  static bool get isAvailable => _loaded && _startedAt == null;

  static Future<void> start() async {
    _startedAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_startedKey, _startedAt!.millisecondsSinceEpoch);
  }
}

/// Offers the one-time preview at a Pro gate. Returns true when the user starts it.
Future<bool> offerProPreview(BuildContext context, {required String feature}) async {
  await ProPreviewStore.load();
  if (!ProPreviewStore.isAvailable || !SubscriptionPlanStore.isFree || !context.mounted) {
    return false;
  }
  FunnelAnalytics.log('pro_preview_offer', {'feature': feature});
  const gold = Color(0xFFFFB74D);
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.auto_awesome, color: gold, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text('Try Oracle Pro free', style: TextStyle(fontWeight: FontWeight.w700))),
        ],
      ),
      content: Text(
        '$feature is part of Oracle Pro. Your first look is on us:\n\n'
        '30 minutes of any symbol, any timeframe, and unlimited trade setups. '
        'No payment, no sign-up for a trial. One time only.',
        style: TextStyle(height: 1.45, color: Colors.grey[400]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'plans'),
          child: Text('See Oracle Pro', style: TextStyle(color: Colors.grey[400])),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'start'),
          style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
          child: const Text('Start free preview', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (!context.mounted) return false;
  if (choice == 'plans') {
    Navigator.push(context, _premiumPageRoute((_) => const SubscriptionPlanScreen(source: 'pro_preview_offer')));
    return false;
  }
  if (choice != 'start') return false;
  await ProPreviewStore.start();
  FunnelAnalytics.log('pro_preview_start', {'feature': feature});
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Oracle Pro preview active for 30 minutes — explore anything.'),
        backgroundColor: Color(0xFF43A047),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return true;
}
