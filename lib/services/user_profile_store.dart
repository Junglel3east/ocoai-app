import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local profile persistence until a backend profile API is wired.
abstract final class UserProfileStore {
  static const _displayNameKey = 'profile_display_name';
  static const _emailKey = 'profile_email';
  static const _timezoneKey = 'profile_timezone';
  static const _memberSinceKey = 'profile_member_since';
  static const _avatarPathKey = 'profile_avatar_path';
  static const _tierKey = 'profile_tier';
  static const String _avatarFileName = 'profile_avatar.jpg';

  static const String defaultDisplayName = 'Oracle Trader';
  static const String defaultEmail = 'oracle.trader@example.com';
  static const String defaultTimezone = 'UTC';
  static const String defaultAvatarAsset = 'assets/images/app_logo.png';

  static String displayName = defaultDisplayName;
  static String email = defaultEmail;
  static String timezone = defaultTimezone;
  static String memberSince = 'January 2026';
  static String tier = 'Free';
  static String? avatarPath;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    displayName = prefs.getString(_displayNameKey) ?? defaultDisplayName;
    email = prefs.getString(_emailKey) ?? defaultEmail;
    timezone = prefs.getString(_timezoneKey) ?? defaultTimezone;
    memberSince = prefs.getString(_memberSinceKey) ?? memberSince;
    tier = prefs.getString(_tierKey) ?? tier;
    if (!prefs.containsKey(_memberSinceKey)) {
      memberSince = 'January 2026';
      await prefs.setString(_memberSinceKey, memberSince);
    }
    final savedPath = prefs.getString(_avatarPathKey);
    if (savedPath != null && File(savedPath).existsSync()) {
      avatarPath = savedPath;
    } else {
      avatarPath = null;
      if (savedPath != null) {
        await prefs.remove(_avatarPathKey);
      }
    }
  }

  static Future<void> saveTier(String value) async {
    tier = value.trim().isEmpty ? 'Free' : value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tierKey, tier);
  }

  static Future<void> setMemberSinceNow() async {
    final now = DateTime.now();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    memberSince = '${months[now.month - 1]} ${now.year}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_memberSinceKey, memberSince);
  }

  static Future<void> save({
    required String displayName,
    required String email,
    required String timezone,
  }) async {
    UserProfileStore.displayName = displayName.trim();
    UserProfileStore.email = email.trim();
    UserProfileStore.timezone = timezone.trim();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_displayNameKey, UserProfileStore.displayName);
    await prefs.setString(_emailKey, UserProfileStore.email);
    await prefs.setString(_timezoneKey, UserProfileStore.timezone);
  }

  /// Copies [sourcePath] into app documents and persists the path locally.
  static Future<String> saveAvatarFromPath(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final destPath = '${dir.path}/$_avatarFileName';
    await File(sourcePath).copy(destPath);
    avatarPath = destPath;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_avatarPathKey, destPath);
    return destPath;
  }

  static bool isValidEmail(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed);
  }
}

/// Where the trader actually executes — informs AI even if Citadel does not support that venue yet.
class TradingVenueOption {
  final String id;
  final String label;
  final String? note;

  const TradingVenueOption({required this.id, required this.label, this.note});
}

abstract final class TradingVenueStore {
  static const _prefKey = 'trading_venue_id';
  static const String autoId = 'auto';

  static const List<TradingVenueOption> options = [
    TradingVenueOption(
      id: autoId,
      label: 'Auto (best available)',
      note: 'AI uses the live feed chain. Citadel still executes on the linked exchange only.',
    ),
    TradingVenueOption(id: 'bitunix', label: 'Bitunix', note: 'Citadel live execution'),
    TradingVenueOption(id: 'blofin_demo', label: 'BloFin (Demo)', note: 'Citadel demo only'),
    TradingVenueOption(id: 'binance', label: 'Binance'),
    TradingVenueOption(id: 'bybit', label: 'Bybit'),
    TradingVenueOption(id: 'okx', label: 'OKX'),
    TradingVenueOption(id: 'kraken', label: 'Kraken'),
    TradingVenueOption(id: 'coinbase', label: 'Coinbase'),
    TradingVenueOption(id: 'hyperliquid', label: 'Hyperliquid'),
    TradingVenueOption(id: 'kucoin', label: 'KuCoin'),
    TradingVenueOption(id: 'gate', label: 'Gate.io'),
    TradingVenueOption(id: 'mexc', label: 'MEXC'),
    TradingVenueOption(id: 'bitget', label: 'Bitget'),
    TradingVenueOption(id: 'htx', label: 'HTX'),
    TradingVenueOption(id: 'phemex', label: 'Phemex'),
    TradingVenueOption(id: 'deribit', label: 'Deribit'),
  ];

  static String venueId = autoId;

  static TradingVenueOption get current {
    return options.firstWhere((o) => o.id == venueId, orElse: () => options.first);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = (prefs.getString(_prefKey) ?? autoId).trim().toLowerCase();
    venueId = options.any((o) => o.id == saved) ? saved : autoId;
  }

  static Future<void> save(String id) async {
    final next = id.trim().toLowerCase();
    venueId = options.any((o) => o.id == next) ? next : autoId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, venueId);
  }

  static Map<String, dynamic> analyzePayloadFields() {
    if (venueId == autoId) return const {};
    return {
      'trading_venue': venueId,
      'preferred_exchange': venueId,
    };
  }
}

/// Starting bankroll for War Room Performance Snapshot / AI Alpha.
abstract final class StartingCapitalStore {
  static const _prefKey = 'starting_capital_usd';
  /// Reject $0 — War Room sizing is meaningless without a positive bankroll.
  static const double minUsd = 100;
  static const double maxUsd = 1000000;
  static const double defaultUsd = 10000;

  static double capitalUsd = defaultUsd;
  static final ValueNotifier<double> notifier = ValueNotifier<double>(defaultUsd);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getDouble(_prefKey);
    capitalUsd = (raw ?? defaultUsd).clamp(minUsd, maxUsd);
    notifier.value = capitalUsd;
    // Migrate legacy $0 / sub-min saves so Alpha never runs on an empty bankroll.
    if (raw != null && raw < minUsd) {
      await prefs.setDouble(_prefKey, capitalUsd);
    }
  }

  static Future<void> save(double value) async {
    capitalUsd = value.clamp(minUsd, maxUsd);
    notifier.value = capitalUsd;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefKey, capitalUsd);
  }
}

/// Persisted Home / Desk watchlist (replaces session-only defaults after first run).
abstract final class WatchlistStore {
  static const _prefKey = 'watchlist_coins_v1';
  static const List<String> defaults = ['BTC', 'ETH', 'SOL', 'BNB'];

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefKey);
    if (raw == null || raw.isEmpty) return List<String>.from(defaults);
    final out = <String>[];
    for (final coin in raw) {
      final n = coin.trim().toUpperCase();
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    return out.isEmpty ? List<String>.from(defaults) : out;
  }

  static Future<void> save(List<String> coins) async {
    final out = <String>[];
    for (final coin in coins) {
      final n = coin.trim().toUpperCase();
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, out);
  }
}

/// One-time desk setup: venue, bankroll, four watchlist coins.
abstract final class FirstRunStore {
  static const _prefKey = 'first_run_setup_complete_v1';
  static bool completed = false;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    completed = prefs.getBool(_prefKey) ?? false;
  }

  static Future<void> markComplete() async {
    completed = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, true);
  }
}
