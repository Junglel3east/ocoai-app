import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const _kCitadelBaseUrl = String.fromEnvironment(
  'CITADEL_BASE_URL',
  defaultValue: 'https://ocoai-app-production.up.railway.app',
);

/// Live BloFin position — normalized by backend /citadel/positions.
class CitadelLivePosition {
  final String positionId;
  final String instId;
  final String coin;
  final String direction;
  final double entryPrice;
  final double markPrice;
  final double size;
  final double leverage;
  final double unrealizedPnl;
  final double unrealizedPnlPct;
  final double liquidationPrice;
  final String marginMode;
  final String positionSide;

  const CitadelLivePosition({
    required this.positionId,
    required this.instId,
    required this.coin,
    required this.direction,
    required this.entryPrice,
    required this.markPrice,
    required this.size,
    required this.leverage,
    required this.unrealizedPnl,
    required this.unrealizedPnlPct,
    required this.liquidationPrice,
    required this.marginMode,
    required this.positionSide,
  });

  bool get isLong => direction.toLowerCase() == 'long';
  bool get isProfit => unrealizedPnl > 0;

  factory CitadelLivePosition.fromJson(Map<String, dynamic> json) {
    double d(dynamic v, [double fallback = 0]) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? fallback;
    }

    return CitadelLivePosition(
      positionId: json['positionId']?.toString() ?? '',
      instId: json['instId']?.toString() ?? '',
      coin: json['coin']?.toString().toUpperCase() ?? '',
      direction: json['direction']?.toString().toLowerCase() ?? 'long',
      entryPrice: d(json['entryPrice']),
      markPrice: d(json['markPrice']),
      size: d(json['size']),
      leverage: d(json['leverage'], 1),
      unrealizedPnl: d(json['unrealizedPnl']),
      unrealizedPnlPct: d(json['unrealizedPnlPct']),
      liquidationPrice: d(json['liquidationPrice']),
      marginMode: json['marginMode']?.toString() ?? 'cross',
      positionSide: json['positionSide']?.toString() ?? 'net',
    );
  }
}

class CitadelTpslOrder {
  final String tpslId;
  final String instId;
  final double? tpTriggerPrice;
  final double? slTriggerPrice;
  final String state;

  const CitadelTpslOrder({
    required this.tpslId,
    required this.instId,
    this.tpTriggerPrice,
    this.slTriggerPrice,
    required this.state,
  });

  factory CitadelTpslOrder.fromJson(Map<String, dynamic> json) {
    double? opt(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return CitadelTpslOrder(
      tpslId: json['tpslId']?.toString() ?? '',
      instId: json['instId']?.toString() ?? '',
      tpTriggerPrice: opt(json['tpTriggerPrice']),
      slTriggerPrice: opt(json['slTriggerPrice']),
      state: json['state']?.toString() ?? '',
    );
  }
}

class CitadelCloseResult {
  final bool success;
  final String coin;
  final double realizedPnl;
  final bool win;
  final bool loss;
  final String? userMessage;

  const CitadelCloseResult({
    required this.success,
    required this.coin,
    required this.realizedPnl,
    required this.win,
    required this.loss,
    this.userMessage,
  });
}

/// Citadel Live Positions API — BloFin open trades via Railway proxy.
abstract final class CitadelPositionsService {
  static Map<String, String> _headers(String appApiKey) => {
        'Content-Type': 'application/json',
        'X-API-Key': appApiKey,
      };

  static String? _userMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['user_message']?.toString() ?? decoded['detail']?.toString();
      }
    } catch (_) {}
    return null;
  }

  static Future<List<CitadelLivePosition>> fetchPositions({
    required String userId,
    required String appApiKey,
  }) async {
    final uri = Uri.parse('$_kCitadelBaseUrl/citadel/positions').replace(
      queryParameters: {'user_id': userId},
    );
    final response = await http
        .get(uri, headers: _headers(appApiKey))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      debugPrint('[CitadelPositions] fetch failed ${response.statusCode}');
      return [];
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return [];
    final rows = decoded['positions'];
    if (rows is! List) return [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(CitadelLivePosition.fromJson)
        .toList();
  }

  static Future<CitadelCloseResult> closePosition({
    required String userId,
    required String appApiKey,
    required CitadelLivePosition position,
    bool flash = false,
  }) async {
    final path = flash ? 'citadel/flash_close' : 'citadel/close_position';
    final uri = Uri.parse('$_kCitadelBaseUrl/$path');
    final response = await http
        .post(
          uri,
          headers: _headers(appApiKey),
          body: jsonEncode({
            'user_id': userId,
            'inst_id': position.instId,
            'margin_mode': position.marginMode,
            'position_side': position.positionSide,
            'unrealized_pnl': position.unrealizedPnl,
          }),
        )
        .timeout(const Duration(seconds: 45));
    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    if (response.statusCode == 200 && body['success'] == true) {
      final pnl = (body['realized_pnl'] as num?)?.toDouble() ?? position.unrealizedPnl;
      return CitadelCloseResult(
        success: true,
        coin: body['coin']?.toString().toUpperCase() ?? position.coin,
        realizedPnl: pnl,
        win: pnl > 0,
        loss: pnl < 0,
      );
    }
    return CitadelCloseResult(
      success: false,
      coin: position.coin,
      realizedPnl: 0,
      win: false,
      loss: false,
      userMessage: _userMessage(response) ?? 'Could not close position (${response.statusCode}).',
    );
  }

  static Future<String?> setTrailingStop({
    required String userId,
    required String appApiKey,
    required CitadelLivePosition position,
    required double callbackPct,
  }) async {
    final uri = Uri.parse('$_kCitadelBaseUrl/citadel/trailing_stop');
    final response = await http
        .post(
          uri,
          headers: _headers(appApiKey),
          body: jsonEncode({
            'user_id': userId,
            'inst_id': position.instId,
            'direction': position.direction,
            'mark_price': position.markPrice,
            'callback_pct': callbackPct,
            'size': position.size.toString(),
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 200) return null;
    return _userMessage(response) ?? 'Trailing stop failed (${response.statusCode}).';
  }

  static Future<List<CitadelTpslOrder>> fetchTpslDetails({
    required String userId,
    required String appApiKey,
    String? instId,
  }) async {
    final params = <String, String>{'user_id': userId};
    if (instId != null && instId.isNotEmpty) params['inst_id'] = instId;
    final uri = Uri.parse('$_kCitadelBaseUrl/citadel/tpsl_details').replace(
      queryParameters: params,
    );
    final response = await http
        .get(uri, headers: _headers(appApiKey))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return [];
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return [];
    final rows = decoded['orders'];
    if (rows is! List) return [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(CitadelTpslOrder.fromJson)
        .toList();
  }
}
