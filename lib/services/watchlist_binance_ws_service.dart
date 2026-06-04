import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Live tick from Binance `<symbol>usdt@ticker` stream.
class BinanceWatchlistTick {
  final String symbol;
  final double priceUsd;
  final double change24hPct;

  const BinanceWatchlistTick({
    required this.symbol,
    required this.priceUsd,
    required this.change24hPct,
  });
}

/// Binance combined stream for Home Watchlist real-time prices.
///
/// Endpoint: wss://stream.binance.com:9443/stream?streams=btcusdt@ticker/...
/// Disconnect via [disconnect] when the watchlist widget is disposed.
class WatchlistBinanceWsService {
  WatchlistBinanceWsService({
    required this.onTick,
    this.onConnected,
    this.onFailed,
  });

  final void Function(BinanceWatchlistTick tick) onTick;
  final void Function()? onConnected;
  final void Function(Object error)? onFailed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _connected = false;
  bool _announcedConnected = false;

  static const _baseUrl = 'wss://stream.binance.com:9443/stream';

  /// Maps app symbol → Binance USDT stream name (without @ticker).
  static String? usdtStreamBase(String symbol) {
    final upper = symbol.trim().toUpperCase();
    if (upper.isEmpty) return null;
    // Polygon rebrand: app may use POL; Binance pair is POLUSDT (or MATICUSDT legacy).
    if (upper == 'MATIC') return 'maticusdt';
    return '${upper}usdt'.toLowerCase();
  }

  /// Whether this symbol has a standard Binance USDT ticker stream.
  static bool supportsSymbol(String symbol) => usdtStreamBase(symbol) != null;

  /// Connect (or reconnect) to ticker streams for [symbols]. No-op if list is empty.
  Future<void> connect(List<String> symbols) async {
    await disconnect();

    final streamToSymbol = <String, String>{};
    for (final raw in symbols) {
      final upper = raw.trim().toUpperCase();
      final base = usdtStreamBase(upper);
      if (base == null) continue;
      streamToSymbol['$base@ticker'] = upper;
    }

    if (streamToSymbol.isEmpty) {
      onFailed?.call(StateError('No Binance USDT streams for watchlist'));
      return;
    }

    final streamsParam = streamToSymbol.keys.join('/');
    final uri = Uri.parse('$_baseUrl?streams=$streamsParam');

    try {
      _announcedConnected = false;
      _channel = WebSocketChannel.connect(uri);
      _connected = false;

      _subscription = _channel!.stream.listen(
        (message) => _handleMessage(message),
        onError: (Object error) {
          _connected = false;
          onFailed?.call(error);
        },
        onDone: () {
          _connected = false;
          onFailed?.call(StateError('Binance watchlist socket closed'));
        },
        cancelOnError: true,
      );
    } catch (e) {
      _connected = false;
      onFailed?.call(e);
      await disconnect();
    }
  }

  void _handleMessage(dynamic message) {
    try {
      final decoded = jsonDecode(message as String);
      if (decoded is! Map<String, dynamic>) return;

      final Map<String, dynamic> payload;
      if (decoded['data'] is Map<String, dynamic>) {
        payload = decoded['data'] as Map<String, dynamic>;
      } else {
        payload = decoded;
      }

      final pair = payload['s']?.toString();
      if (pair == null || !pair.endsWith('USDT')) return;

      final price = double.tryParse(payload['c']?.toString() ?? '');
      final changePct = double.tryParse(payload['P']?.toString() ?? '');
      if (price == null || price <= 0 || changePct == null) return;

      if (!_announcedConnected) {
        _announcedConnected = true;
        _connected = true;
        onConnected?.call();
      }

      final symbol = pair.substring(0, pair.length - 4);
      onTick(
        BinanceWatchlistTick(
          symbol: symbol,
          priceUsd: price,
          change24hPct: changePct,
        ),
      );
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  /// Close socket and cancel listener — call from [State.dispose].
  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
  }

  bool get isConnected => _connected;
}
