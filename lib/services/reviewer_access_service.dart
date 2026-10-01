import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'user_profile_store.dart';

/// Store-review access — Google Play / App Store reviewers must reach every
/// paid screen without billing info. The backend keeps the allow-list
/// (`REVIEWER_ACCESS_EMAILS` on Railway); a matching sign-in email is granted
/// Oracle Pro on this device. Rotate the list after each review.
abstract final class ReviewerAccessService {
  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );

  static const _planKey = 'subscription_plan';
  static const _grantedKey = 'reviewer_access_granted';
  static const _grantedPlan = 'Expert';

  /// Checks the allow-list for [email]; on match, unlocks Oracle Pro locally.
  /// Never throws — auth flow must not depend on this.
  static Future<bool> syncForEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    try {
      final uri = Uri.parse('$_backendBaseUrl/reviewer_access')
          .replace(queryParameters: {'email': normalized});
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      final granted = decoded is Map && decoded['granted'] == true;
      if (!granted) return false;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_planKey, _grantedPlan);
      await prefs.setBool(_grantedKey, true);
      await UserProfileStore.saveTier(_grantedPlan);
      debugPrint('[ReviewerAccess] Oracle Pro granted for store review');
      return true;
    } catch (e) {
      debugPrint('[ReviewerAccess] check skipped: $e');
      return false;
    }
  }

  static Future<bool> isGranted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_grantedKey) ?? false;
  }
}
