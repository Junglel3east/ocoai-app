import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Sends uncaught Flutter / Dart errors to the backend (`POST /analytics/crash`).
///
/// No personal data: error text, a trimmed stack trace, app version, and OS.
/// Each distinct error is sent once per app session, at most [_maxPerSession].
abstract final class CrashReporter {
  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://ocoai-app-production.up.railway.app',
  );
  static const _maxPerSession = 20;
  static const _maxStackLines = 25;

  static final Set<int> _sent = {};
  static String _appVersion = '';

  static void install({required String appVersion}) {
    _appVersion = appVersion;
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      report(details.exception, details.stack, fatal: false, context: details.context?.toString());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack, fatal: true);
      return true;
    };
  }

  static void report(Object error, StackTrace? stack, {bool fatal = false, String? context}) {
    if (kDebugMode) return;
    final stackLines = (stack?.toString() ?? '').split('\n').take(_maxStackLines).join('\n');
    final key = Object.hash(error.runtimeType, stackLines.split('\n').take(3).join());
    if (_sent.length >= _maxPerSession || !_sent.add(key)) return;
    unawaited(_send({
      'error': error.toString().substring(0, error.toString().length.clamp(0, 500)),
      'type': error.runtimeType.toString(),
      'stack': stackLines,
      'fatal': fatal,
      if (context != null) 'context': context.substring(0, context.length.clamp(0, 200)),
      'app_version': _appVersion,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    }));
  }

  static Future<void> _send(Map<String, Object?> payload) async {
    try {
      await http
          .post(
            Uri.parse('$_backendBaseUrl/analytics/crash'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}
