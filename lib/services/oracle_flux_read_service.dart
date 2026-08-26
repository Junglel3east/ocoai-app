import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Latest FluxRead v1 snapshot from Railway (TradingView webhook ingest).
/// The in-app TradingView widget cannot read Pine values — Analyze uses this instead.
abstract final class OracleFluxReadService {
  static const _timeout = Duration(seconds: 6);

  static String normalizeTf(String raw) {
    final t = raw.trim().toLowerCase();
    switch (t) {
      case '1':
      case '1m':
        return '1m';
      case '5':
      case '5m':
        return '5m';
      case '15':
      case '15m':
        return '15m';
      case '30':
      case '30m':
        return '30m';
      case '60':
      case '1h':
        return '1h';
      case '240':
      case '4h':
        return '4h';
      case 'd':
      case '1d':
        return '1d';
      default:
        return t.isEmpty ? '1h' : t;
    }
  }

  /// Latest merged overlay + oscillator read, or null if none / timeout.
  static Future<Map<String, dynamic>?> latestFor({
    required String coin,
    required String timeframe,
    required String backendBaseUrl,
  }) async {
    final symbol = coin.trim().toUpperCase();
    if (symbol.isEmpty) return null;
    final tf = normalizeTf(timeframe);
    final uri = Uri.parse('$backendBaseUrl/flux_read').replace(
      queryParameters: {'coin': symbol, 'timeframe': tf},
    );
    try {
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic> || data['success'] != true) return null;
      final flux = data['oracle_flux'];
      if (flux is Map<String, dynamic> && flux.isNotEmpty) return flux;
    } catch (e) {
      debugPrint('[FluxRead] latestFor $symbol $tf failed: $e');
    }
    return null;
  }
}
