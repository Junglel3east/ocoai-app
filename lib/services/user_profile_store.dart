import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local profile persistence until a backend profile API is wired.
abstract final class UserProfileStore {
  static const _displayNameKey = 'profile_display_name';
  static const _emailKey = 'profile_email';
  static const _timezoneKey = 'profile_timezone';
  static const _memberSinceKey = 'profile_member_since';
  static const _avatarPathKey = 'profile_avatar_path';
  static const String _avatarFileName = 'profile_avatar.jpg';

  static const String defaultDisplayName = 'Oracle Trader';
  static const String defaultEmail = 'oracle.trader@example.com';
  static const String defaultTimezone = 'UTC';
  static const String defaultAvatarAsset = 'assets/images/app_logo.png';

  static String displayName = defaultDisplayName;
  static String email = defaultEmail;
  static String timezone = defaultTimezone;
  static String memberSince = 'January 2026';
  static String? avatarPath;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    displayName = prefs.getString(_displayNameKey) ?? defaultDisplayName;
    email = prefs.getString(_emailKey) ?? defaultEmail;
    timezone = prefs.getString(_timezoneKey) ?? defaultTimezone;
    memberSince = prefs.getString(_memberSinceKey) ?? memberSince;
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
