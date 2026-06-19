import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_api_key_service.dart';
import 'user_profile_store.dart';

/// Local email/password auth with secure storage and optional biometrics.
///
/// Credentials are mirrored to SharedPreferences so sign-in still works when
/// encrypted secure storage hangs or fails (common on sideload / Samsung builds).
abstract final class AuthService {
  static const _sessionKey = 'auth_session_active';
  static const _registeredEmailKey = 'auth_registered_email';
  static const _passwordHashKey = 'auth_password_hash';
  static const _rememberMeKey = 'auth_remember_me';
  static const _biometricKey = 'auth_biometric_enabled';
  static const _subscriptionPlanKey = 'subscription_plan';
  static const _salt = 'oco_oracle_auth_v1';
  static const _mirrorPrefix = 'auth_mirror_';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static final LocalAuthentication _localAuth = LocalAuthentication();

  static const Duration _secureTimeout = Duration(seconds: 10);

  static Future<String?> _secureRead(String key) async {
    try {
      final value = await _storage.read(key: key).timeout(_secureTimeout);
      if (value != null && value.isNotEmpty) return value;
    } catch (e) {
      debugPrint('[AuthService] secure read failed key=$key: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_mirrorPrefix$key');
  }

  static Future<void> _secureWrite(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_mirrorPrefix$key', value);
    try {
      await _storage.write(key: key, value: value).timeout(_secureTimeout);
    } catch (e) {
      debugPrint('[AuthService] secure write failed key=$key (prefs mirror ok): $e');
    }
  }

  static Future<void> _secureDelete(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_mirrorPrefix$key');
    try {
      await _storage.delete(key: key).timeout(_secureTimeout);
    } catch (e) {
      debugPrint('[AuthService] secure delete failed key=$key: $e');
    }
  }

  static Future<void> init() async {
    await UserProfileStore.load();
  }

  static String _hashPassword(String password) {
    final bytes = utf8.encode('$password::$_salt');
    return sha256.convert(bytes).toString();
  }

  static Future<bool> hasValidSession() async {
    final session = await _secureRead(_sessionKey);
    return session == 'true';
  }

  static Future<bool> isRememberMeEnabled() async {
    return (await _secureRead(_rememberMeKey)) == 'true';
  }

  static Future<bool> isBiometricEnabled() async {
    return (await _secureRead(_biometricKey)) == 'true';
  }

  static Future<String?> getRememberedEmail() async {
    if (!await isRememberMeEnabled()) return null;
    return await _secureRead(_registeredEmailKey);
  }

  static Future<bool> hasRegisteredAccount() async {
    final email = await _secureRead(_registeredEmailKey);
    final hash = await _secureRead(_passwordHashKey);
    return email != null && email.isNotEmpty && hash != null && hash.isNotEmpty;
  }

  static Future<bool> canUseBiometrics() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      return canCheck || supported;
    } catch (e) {
      debugPrint('[AuthService] biometric check failed: $e');
      return false;
    }
  }

  static Future<List<BiometricType>> availableBiometricTypes() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  static String biometricLabel(List<BiometricType> types) {
    if (types.contains(BiometricType.face)) return 'Face ID';
    if (types.contains(BiometricType.fingerprint)) return 'Fingerprint';
    if (types.contains(BiometricType.strong) || types.contains(BiometricType.weak)) {
      return 'Biometric';
    }
    return 'Biometric Login';
  }

  static Future<bool> authenticateWithBiometrics({String? reason}) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason ?? 'Sign in to On-Chain Oracle AI',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (e) {
      debugPrint('[AuthService] biometric auth failed: $e');
      return false;
    }
  }

  /// Opens the app after splash when session + biometrics are configured.
  static Future<bool> tryBiometricUnlock() async {
    if (!await hasRegisteredAccount()) return false;
    if (!await isRememberMeEnabled()) return false;
    if (!await isBiometricEnabled()) return false;
    if (!await canUseBiometrics()) return false;

    final ok = await authenticateWithBiometrics(
      reason: 'Unlock your Oracle account',
    );
    if (!ok) return false;

    await _secureWrite(_sessionKey, 'true');
    await _syncProfileFromStorage();
    final email = await _secureRead(_registeredEmailKey);
    if (email != null && email.isNotEmpty) {
      try {
        await AppApiKeyService.ensureKey(email: email).timeout(_secureTimeout);
      } catch (e) {
        debugPrint('[AuthService] ensureKey after biometric skipped: $e');
      }
    }
    return true;
  }

  static Future<AuthResult> signUp({
    required String email,
    required String password,
    required bool rememberMe,
    bool enableBiometric = false,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!UserProfileStore.isValidEmail(normalizedEmail)) {
      return AuthResult.failure('Enter a valid email address.');
    }
    if (password.length < 8) {
      return AuthResult.failure('Password must be at least 8 characters.');
    }

    final existing = await _secureRead(_registeredEmailKey);
    if (existing != null && existing.isNotEmpty) {
      return AuthResult.failure('An account already exists. Sign in instead.');
    }

    await _persistCredentials(
      email: normalizedEmail,
      password: password,
      rememberMe: rememberMe,
      enableBiometric: enableBiometric,
    );
    await UserProfileStore.setMemberSinceNow();
    await _activateSession(normalizedEmail);
    return AuthResult.success();
  }

  static Future<AuthResult> signIn({
    required String email,
    required String password,
    required bool rememberMe,
    bool enableBiometric = false,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!UserProfileStore.isValidEmail(normalizedEmail)) {
      return AuthResult.failure('Enter a valid email address.');
    }
    if (password.isEmpty) {
      return AuthResult.failure('Enter your password.');
    }

    final storedEmail = await _secureRead(_registeredEmailKey);
    final storedHash = await _secureRead(_passwordHashKey);

    if (storedEmail == null || storedHash == null) {
      return AuthResult.failure('No account found. Tap "Create one" below.');
    }
    if (storedEmail.toLowerCase() != normalizedEmail) {
      return AuthResult.failure('Email or password is incorrect.');
    }
    if (_hashPassword(password) != storedHash) {
      return AuthResult.failure('Email or password is incorrect.');
    }

    await _persistCredentials(
      email: normalizedEmail,
      password: password,
      rememberMe: rememberMe,
      enableBiometric: enableBiometric,
    );
    await _activateSession(normalizedEmail);
    return AuthResult.success();
  }

  static Future<AuthResult> signInWithBiometrics() async {
    if (!await hasRegisteredAccount()) {
      return AuthResult.failure('Sign in with email first to enable biometrics.');
    }
    if (!await isRememberMeEnabled()) {
      return AuthResult.failure('Enable Remember me to use biometric login.');
    }

    final ok = await authenticateWithBiometrics();
    if (!ok) {
      return AuthResult.failure('Biometric authentication cancelled.');
    }

    await _secureWrite(_sessionKey, 'true');
    await _syncProfileFromStorage();
    return AuthResult.success();
  }

  static Future<void> signOut() async {
    await _secureDelete(_sessionKey);
  }

  static Future<void> setBiometricEnabled(bool enabled) async {
    if (enabled) {
      await _secureWrite(_biometricKey, 'true');
    } else {
      await _secureDelete(_biometricKey);
    }
  }

  static Future<void> _persistCredentials({
    required String email,
    required String password,
    required bool rememberMe,
    required bool enableBiometric,
  }) async {
    await _secureWrite(_registeredEmailKey, email);
    await _secureWrite(_passwordHashKey, _hashPassword(password));

    if (rememberMe) {
      await _secureWrite(_rememberMeKey, 'true');
    } else {
      await _secureDelete(_rememberMeKey);
      await _secureDelete(_biometricKey);
    }

    if (rememberMe && enableBiometric && await canUseBiometrics()) {
      await _secureWrite(_biometricKey, 'true');
    } else {
      await _secureDelete(_biometricKey);
    }
  }

  static Future<String> _currentTier() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_subscriptionPlanKey) ?? 'Free';
  }

  static Future<void> _activateSession(String email) async {
    await _secureWrite(_sessionKey, 'true');

    final nameFromEmail = email.split('@').first;
    final displayName = nameFromEmail.isNotEmpty
        ? nameFromEmail[0].toUpperCase() + nameFromEmail.substring(1)
        : UserProfileStore.defaultDisplayName;

    final useExistingName = UserProfileStore.displayName != UserProfileStore.defaultDisplayName;
    await UserProfileStore.save(
      displayName: useExistingName ? UserProfileStore.displayName : displayName,
      email: email,
      timezone: UserProfileStore.timezone,
    );
    await UserProfileStore.saveTier(await _currentTier());
    try {
      await AppApiKeyService.ensureKey(email: email).timeout(_secureTimeout);
    } catch (e) {
      debugPrint('[AuthService] ensureKey after sign-in skipped: $e');
    }
  }

  static Future<void> _syncProfileFromStorage() async {
    final email = await _secureRead(_registeredEmailKey);
    if (email == null || email.isEmpty) return;
    await UserProfileStore.load();
    await UserProfileStore.save(
      displayName: UserProfileStore.displayName,
      email: email,
      timezone: UserProfileStore.timezone,
    );
    await UserProfileStore.saveTier(await _currentTier());
  }
}

class AuthResult {
  final bool ok;
  final String? message;

  const AuthResult._({required this.ok, this.message});

  factory AuthResult.success() => const AuthResult._(ok: true);

  factory AuthResult.failure(String message) => AuthResult._(ok: false, message: message);
}
