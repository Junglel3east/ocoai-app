import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Manages the per-install App API Key (X-API-Key) in secure storage.
abstract final class AppApiKeyService {
  static const _appKeyStorageKey = 'oco_app_api_key_v1';
  static const _appUserIdStorageKey = 'oco_app_user_id_v1';
  static const _citadelUserIdPref = 'citadel_user_id';
  static const _citadelApiKeyPref = 'citadel_api_key';

  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Stable Citadel user id derived from the signed-in email.
  static String userIdFromEmail(String email) {
    final normalized = email.trim().toLowerCase();
    final digest = sha256.convert(utf8.encode('oco_app_uid:$normalized')).toString();
    return 'usr_${digest.substring(0, 16)}';
  }

  static String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final encoded = base64Url.encode(bytes).replaceAll('=', '');
    return 'oco_${encoded.length > 32 ? encoded.substring(0, 32) : encoded}';
  }

  static Future<String?> getKey() => _storage.read(key: _appKeyStorageKey);

  static Future<String?> getUserId() => _storage.read(key: _appUserIdStorageKey);

  /// Persists Citadel user id when changed in Oracle Citadel Setup.
  static Future<void> syncUserId(String userId) async {
    final uid = userId.trim();
    if (uid.isEmpty) return;
    await _storage.write(key: _appUserIdStorageKey, value: uid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_citadelUserIdPref, uid);
  }

  /// Creates or loads the App API Key, syncs SharedPreferences for Oracle Citadel.
  static Future<String> ensureKey({String? email}) async {
    try {
      var key = await _storage.read(key: _appKeyStorageKey);
      if (key == null || key.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        key = prefs.getString(_citadelApiKeyPref);
        if (key == null || key.isEmpty) {
          key = _generateKey();
        }
        try {
          await _storage.write(key: _appKeyStorageKey, value: key);
        } catch (e) {
          debugPrint('[AppApiKey] secure storage write failed, using prefs: $e');
        }
      }
    } catch (e) {
      debugPrint('[AppApiKey] secure storage read failed, using prefs: $e');
      final prefs = await SharedPreferences.getInstance();
      var key = prefs.getString(_citadelApiKeyPref);
      if (key == null || key.isEmpty) {
        key = _generateKey();
        await prefs.setString(_citadelApiKeyPref, key);
      }
      await _syncToCitadelPrefs(
        (prefs.getString(_citadelUserIdPref) ?? 'demo_user').trim(),
        key,
      );
      return key;
    }

    final prefs = await SharedPreferences.getInstance();
    var key = await _storage.read(key: _appKeyStorageKey) ?? '';
    if (key.isEmpty) {
      key = prefs.getString(_citadelApiKeyPref) ?? _generateKey();
    }
    final prefUserId = (prefs.getString(_citadelUserIdPref) ?? 'demo_user').trim();

    String userId;
    if (email != null && email.isNotEmpty) {
      final emailUid = userIdFromEmail(email);
      userId = (prefUserId.isEmpty || prefUserId == 'demo_user') ? emailUid : prefUserId;
    } else {
      userId = (await _storage.read(key: _appUserIdStorageKey))?.trim() ?? '';
      if (userId.isEmpty) userId = prefUserId.isNotEmpty ? prefUserId : 'demo_user';
    }

    await _storage.write(key: _appUserIdStorageKey, value: userId);
    await _syncToCitadelPrefs(userId, key);

    registerWithBackend(userId: userId, apiKey: key);
    return key;
  }

  static Future<void> _syncToCitadelPrefs(String userId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_citadelUserIdPref, userId);
    await prefs.setString(_citadelApiKeyPref, apiKey);
  }

  /// Headers for backend requests that accept X-API-Key.
  static Future<Map<String, String>> backendHeaders({bool includeJsonContentType = true}) async {
    final key = await ensureKey();
    final headers = <String, String>{};
    if (includeJsonContentType) {
      headers['Content-Type'] = 'application/json';
    }
    if (key.isNotEmpty) {
      headers['X-API-Key'] = key;
    }
    return headers;
  }

  /// Registers the key with the backend (best-effort; does not block UI).
  static Future<void> registerWithBackend({
    required String userId,
    required String apiKey,
  }) async {
    final uid = userId.trim();
    final key = apiKey.trim();
    if (uid.isEmpty || key.isEmpty) return;

    final uri = Uri.parse('$_backendBaseUrl/app_api_key/register');
    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'X-API-Key': key,
            },
            body: jsonEncode({
              'user_id': uid,
              'app_api_key': key,
            }),
          )
          .timeout(const Duration(seconds: 15));
      debugPrint('[AppApiKey] register ${response.statusCode} user=$uid');
    } catch (e) {
      debugPrint('[AppApiKey] register failed: $e');
    }
  }
}
