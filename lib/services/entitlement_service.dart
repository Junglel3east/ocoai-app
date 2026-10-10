import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_api_key_service.dart';
import 'reviewer_access_service.dart';
import 'user_profile_store.dart';

/// Server-side subscription truth. Purchases are verified with Google by the
/// backend; on launch / sign-in the app adopts the server's answer so a plan
/// can't be unlocked by editing on-device storage.
///
/// Safe by default: when the backend reports `configured: false`, or the
/// network fails, nothing changes on the device.
abstract final class EntitlementService {
  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );

  static const _planKey = 'subscription_plan';
  static const _timeout = Duration(seconds: 12);

  /// Product ids Google Play reported as owned during this app session.
  static final Set<String> _ownedThisSession = {};

  /// Sends a Play purchase token to the backend for verification. Never throws.
  static Future<void> verifyPurchase({
    required String productId,
    required String purchaseToken,
  }) async {
    _ownedThisSession.add(productId);
    if (purchaseToken.isEmpty) return;
    try {
      final response = await http
          .post(
            Uri.parse('$_backendBaseUrl/billing/verify'),
            headers: await AppApiKeyService.backendHeaders(),
            body: jsonEncode({'purchase_token': purchaseToken, 'product_id': productId}),
          )
          .timeout(_timeout);
      final body = _decode(response.body);
      if (body?['invalid_token'] == true) _ownedThisSession.remove(productId);
      debugPrint('[Entitlement] verify ${response.statusCode} active=${body?['active']}');
    } catch (e) {
      debugPrint('[Entitlement] verify skipped: $e');
    }
  }

  /// Adopts the backend's entitlement. Returns the plan now stored on device.
  static Future<String?> sync() async {
    try {
      final response = await http
          .get(
            Uri.parse('$_backendBaseUrl/billing/entitlement'),
            headers: await AppApiKeyService.backendHeaders(includeJsonContentType: false),
          )
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = _decode(response.body);
      if (body == null || body['configured'] != true) return null;

      if (body['active'] == true) {
        final plan = (body['plan'] as String?) ?? 'Expert';
        await _setPlan(plan);
        return plan;
      }
      // Play said "owned" this session — the backend just hasn't caught up yet.
      if (_ownedThisSession.isNotEmpty) return null;
      if (await ReviewerAccessService.isGranted()) return null;

      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getString(_planKey) ?? 'Free';
      if (current != 'Free') {
        debugPrint('[Entitlement] server reports no active subscription — reverting to Free');
        await _setPlan('Free');
      }
      return 'Free';
    } catch (e) {
      debugPrint('[Entitlement] sync skipped: $e');
      return null;
    }
  }

  static Future<void> _setPlan(String plan) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_planKey, plan);
    await UserProfileStore.saveTier(plan);
  }

  static Map<String, dynamic>? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
