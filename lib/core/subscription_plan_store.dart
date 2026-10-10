// Subscription plan state and Free-tier limits.

part of '../main.dart';

abstract final class SubscriptionPlanStore {
  static const _planKey = 'subscription_plan';
  static const _homeChatHiddenKey = 'home_chat_fab_hidden';

  /// Public name of the single paid tier. Internally stored as `Expert`.
  static const proPlanName = 'Oracle Pro';

  static String currentPlan = 'Free';

  /// User-facing plan label (`Free`, `Oracle Pro`, or legacy `Premium`).
  static String get displayPlanName => displayNameFor(currentPlan);

  static String displayNameFor(String plan) {
    switch (plan.trim().toLowerCase()) {
      case 'expert':
      case 'top tier':
      case 'pro':
      case 'oracle pro':
        return proPlanName;
      case 'premium':
        return 'Premium (legacy)';
      default:
        return 'Free';
    }
  }

  static bool get hasExpertChatAccess {
    final plan = currentPlan.trim().toLowerCase();
    return plan == 'expert' || plan == 'top tier';
  }

  static bool get isExpert => hasExpertChatAccess;

  static bool get isPremium {
    final plan = currentPlan.trim().toLowerCase();
    return plan == 'premium';
  }

  static bool get isFree => !isPremium && !isExpert;

  static bool get isPremiumOrHigher => isPremium || isExpert;

  static bool get hasOracleVisionAccess => isPremiumOrHigher;

  static bool get hasOracleDeskAccess => isExpert;

  static bool get hasCitadelAccess => isExpert;

  static bool get hasAiChatAccess => isPremiumOrHigher;

  static bool get hasUnlimitedAiChat => isExpert;

  static const int freeWatchlistMax = 5;

  static const int freeTradeSetupsPerDay = 3;

  static const String freeTradeSetupTimeframe = '1d';

  static const Duration freeTradeSetupWindow = Duration(hours: 24);

  static const int premiumChatMessagesPerDay = 10;

  static const _premiumChatDayKey = 'premium_chat_day';

  static const _premiumChatCountKey = 'premium_chat_count';

  static String _localDayKey([DateTime? dt]) {
    final local = (dt ?? DateTime.now()).toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  static bool canAddWatchlistCoin(int currentCount) {
    if (!isFree) return true;
    return currentCount < freeWatchlistMax;
  }

  static bool isFreeAllowedTradeSetupTimeframe(String timeframe) {
    if (ProPreviewStore.isActive) return true;
    final tf = timeframe.trim().toLowerCase();
    return tf == '1d' || tf == 'daily' || tf == 'd1';
  }

  static int countTradeSetupsInWindow(List<Map<String, dynamic>> trades) {
    final cutoff = DateTime.now().subtract(freeTradeSetupWindow);
    return trades.where((t) {
      final created = DateTime.tryParse(t['createdAt']?.toString() ?? '');
      if (created == null) return false;
      return !created.isBefore(cutoff);
    }).length;
  }

  static bool canGenerateTradeSetup(List<Map<String, dynamic>> trades) {
    if (!isFree || ProPreviewStore.isActive) return true;
    return countTradeSetupsInWindow(trades) < freeTradeSetupsPerDay;
  }

  static bool canUseAlertType(String type) {
    if (type == 'Price' || type == 'guardian') return true;
    if (type == 'pulse') return isPremiumOrHigher;
    if (type == 'citadel') return isExpert;
    return !isFree;
  }

  static AlertTierPolicy get alertPolicy {
    if (isExpert) return AlertTierPolicy.expert;
    if (isPremiumOrHigher) return AlertTierPolicy.premium;
    return AlertTierPolicy.free;
  }

  static Future<bool> canSendChatMessage() async {
    if (isExpert) return true;
    if (!isPremium) return false;
    final prefs = await SharedPreferences.getInstance();
    final today = _localDayKey();
    final storedDay = prefs.getString(_premiumChatDayKey) ?? '';
    final count = storedDay == today ? (prefs.getInt(_premiumChatCountKey) ?? 0) : 0;
    return count < premiumChatMessagesPerDay;
  }

  static Future<void> recordPremiumChatMessage() async {
    if (!isPremium || isExpert) return;
    final prefs = await SharedPreferences.getInstance();
    final today = _localDayKey();
    final storedDay = prefs.getString(_premiumChatDayKey) ?? '';
    var count = storedDay == today ? (prefs.getInt(_premiumChatCountKey) ?? 0) : 0;
    count++;
    await prefs.setString(_premiumChatDayKey, today);
    await prefs.setInt(_premiumChatCountKey, count);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    currentPlan = prefs.getString(_planKey) ?? 'Free';
    await ProPreviewStore.load();
  }

  static Future<void> setPlan(String plan) async {
    currentPlan = plan;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_planKey, plan);
    await UserProfileStore.saveTier(plan);
  }

  static Future<bool> isHomeChatFabHidden() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_homeChatHiddenKey) ?? false;
  }

  static Future<void> setHomeChatFabHidden(bool hidden) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_homeChatHiddenKey, hidden);
  }
}

// ─── Oracle Citadel (Expert automated trading) ───────────────────────────────
