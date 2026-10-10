import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_api_key_service.dart';

/// Paywall funnel events (paywall views → purchase starts → purchases).
///
/// Fire-and-forget: never throws and never blocks the UI. Events carry an
/// anonymous per-install id plus the event name and a few small properties —
/// no email, name, or other personal data.
abstract final class FunnelAnalytics {
  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );
  static const _installIdKey = 'funnel_install_id';

  static String? _installId;

  static Future<String> _id() async {
    if (_installId != null) return _installId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_installIdKey);
    if (id == null || id.isEmpty) {
      final rnd = Random.secure();
      id = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await prefs.setString(_installIdKey, id);
    }
    return _installId = id;
  }

  static void log(String event, [Map<String, Object?> props = const {}]) {
    unawaited(_send(event, props));
  }

  static Future<void> _send(String event, Map<String, Object?> props) async {
    try {
      final headers = await AppApiKeyService.backendHeaders();
      await http
          .post(
            Uri.parse('$_backendBaseUrl/analytics/event'),
            headers: headers,
            body: jsonEncode({
              'event': event,
              'install_id': await _id(),
              'props': props,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[Funnel] $event not sent: $e');
    }
  }
}
