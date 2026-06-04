import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../firebase_options.dart';

/// Notification categories used across FCM + local alerts.
enum OracleNotificationType {
  analysisReady('New Analysis Ready', 'oracle_analysis'),
  tradeSetupTriggered('Trade Setup Triggered', 'oracle_trade_setup'),
  alertHit('Alert Hit', 'oracle_alert'),
  dailyUpdate('On-Chain Oracle Daily Update', 'oracle_daily');

  final String title;
  final String channelId;
  const OracleNotificationType(this.title, this.channelId);
}

/// Handles FCM push + daily 7:30 AM CST local reminders.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const int dailyMorningNotificationId = 730;
  static const String _prefsPermissionAskedKey = 'notification_permission_requested';

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  bool _firebaseReady = false;
  bool _localReady = false;

  /// Set from [MainScreen] — opens Home and scrolls to Daily Analyses.
  VoidCallback? onOpenDailyAnalyses;

  bool _pendingOpenDailyAnalyses = false;

  bool get isFirebaseReady => _firebaseReady;
  bool get isLocalReady => _localReady;

  /// Wire Home navigation (call from MainScreen.initState).
  void registerDailyAnalysesNavigator(VoidCallback? navigator) {
    onOpenDailyAnalyses = navigator;
    if (navigator != null && _pendingOpenDailyAnalyses) {
      _pendingOpenDailyAnalyses = false;
      navigator();
    }
  }

  /// After navigator is registered, handle cold-start notification tap.
  Future<void> dispatchPendingDailyAnalysesNavigation() async {
    if (!_pendingOpenDailyAnalyses) return;
    if (onOpenDailyAnalyses != null) {
      _pendingOpenDailyAnalyses = false;
      onOpenDailyAnalyses!();
    }
  }

  static bool isDailyAnalysesNotificationType(String? typeName) {
    if (typeName == null) return false;
    switch (typeName) {
      case 'dailyUpdate':
      case 'daily_update':
      case 'analysisReady':
      case 'analysis_ready':
        return true;
      default:
        return false;
    }
  }

  /// Background FCM handler (must be top-level).
  @pragma('vm:entry-point')
  static Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    debugPrint('[FCM background] ${message.messageId} data=${message.data}');
  }

  Future<void> initialize() async {
    tz_data.initializeTimeZones();
    await _initLocalNotifications();
    await _initFirebase();
    await _requestPermissions();
    await scheduleDailyMorningAlert();
    await _subscribeDefaultTopics();
  }

  Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings = InitializationSettings(android: androidInit, iOS: darwinInit);

    await _local.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    final androidPlugin = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_channelFor(OracleNotificationType.dailyUpdate));
    await androidPlugin?.createNotificationChannel(_channelFor(OracleNotificationType.analysisReady));
    await androidPlugin?.createNotificationChannel(_channelFor(OracleNotificationType.tradeSetupTriggered));
    await androidPlugin?.createNotificationChannel(_channelFor(OracleNotificationType.alertHit));

    _localReady = true;
  }

  Future<void> _initFirebase() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
      _firebaseReady = true;

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);

      final initial = await _fcm.getInitialMessage();
      if (initial != null) {
        debugPrint('[FCM] Opened from terminated: ${initial.data}');
        final typeName = (initial.data['type'] ?? initial.data['notification_type'])?.toString();
        if (isDailyAnalysesNotificationType(typeName)) {
          _pendingOpenDailyAnalyses = true;
        }
      }

      debugPrint('[FCM] Token: ${await _fcm.getToken()}');
    } catch (e, st) {
      _firebaseReady = false;
      debugPrint('[NotificationService] Firebase unavailable (add google-services.json / Firebase config): $e');
      debugPrint('$st');
    }
  }

  Future<void> _requestPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAsked = prefs.getBool(_prefsPermissionAskedKey) ?? false;

    if (_firebaseReady) {
      final settings = await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      debugPrint('[FCM] Permission: ${settings.authorizationStatus}');
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
    } else if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      await _local
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }

    if (!alreadyAsked) {
      await prefs.setBool(_prefsPermissionAskedKey, true);
    }
  }

  Future<void> _subscribeDefaultTopics() async {
    if (!_firebaseReady) return;
    try {
      await _fcm.subscribeToTopic('daily_oracle_update');
      await _fcm.subscribeToTopic('oracle_alerts');
    } catch (e) {
      debugPrint('[FCM] Topic subscribe failed: $e');
    }
  }

  /// Schedules local reminder every day at 7:30 AM America/Chicago (CST/CDT).
  Future<void> scheduleDailyMorningAlert() async {
    if (!_localReady) return;

    final chicago = tz.getLocation('America/Chicago');
    final now = tz.TZDateTime.now(chicago);
    var scheduled = tz.TZDateTime(chicago, now.year, now.month, now.day, 7, 30);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    await _local.zonedSchedule(
      dailyMorningNotificationId,
      OracleNotificationType.dailyUpdate.title,
      'Your daily BTC, ETH, and SOL analysis is ready. Open the app for On-Chain Oracle insights.',
      scheduled,
      _detailsFor(OracleNotificationType.dailyUpdate),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: jsonEncode({'type': OracleNotificationType.dailyUpdate.name}),
    );

    debugPrint('[Notifications] Daily 7:30 AM CST scheduled → next: $scheduled');
  }

  // ─── Placeholder show helpers (FCM payloads or in-app triggers) ─────────────

  Future<void> showAnalysisReady({String coin = 'BTC', String? body}) async {
    await _showLocal(
      type: OracleNotificationType.analysisReady,
      title: OracleNotificationType.analysisReady.title,
      body: body ?? 'Your $coin market analysis report is ready to review.',
      payload: {'type': OracleNotificationType.analysisReady.name, 'coin': coin},
    );
  }

  Future<void> showTradeSetupTriggered({String coin = 'BTC', String? body}) async {
    await _showLocal(
      type: OracleNotificationType.tradeSetupTriggered,
      title: OracleNotificationType.tradeSetupTriggered.title,
      body: body ?? '$coin trade setup levels are active. Review Entry, SL, and targets.',
      payload: {'type': OracleNotificationType.tradeSetupTriggered.name, 'coin': coin},
    );
  }

  Future<void> showAlertHit({String coin = 'BTC', String? condition}) async {
    await _showLocal(
      type: OracleNotificationType.alertHit,
      title: OracleNotificationType.alertHit.title,
      body: condition ?? '$coin alert condition was met. Tap to view details.',
      payload: {'type': OracleNotificationType.alertHit.name, 'coin': coin},
    );
  }

  Future<void> showDailyUpdate({String? body}) async {
    await _showLocal(
      type: OracleNotificationType.dailyUpdate,
      title: OracleNotificationType.dailyUpdate.title,
      body: body ?? 'Morning briefing: check BTC, ETH, SOL daily reports in the app.',
      payload: {'type': OracleNotificationType.dailyUpdate.name},
    );
  }

  Future<void> _showLocal({
    required OracleNotificationType type,
    required String title,
    required String body,
    Map<String, String>? payload,
  }) async {
    if (!_localReady) return;
    final id = type.index + 100;
    await _local.show(
      id,
      title,
      body,
      _detailsFor(type),
      payload: payload != null ? jsonEncode(payload) : null,
    );
  }

  void _onForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    final data = message.data;
    final typeName = data['type'] ?? data['notification_type'];

    if (typeName != null) {
      _handleTypedPayload(typeName.toString(), data, notification?.title, notification?.body);
      return;
    }

    if (notification != null) {
      _local.show(
        message.hashCode,
        notification.title,
        notification.body,
        _detailsFor(OracleNotificationType.dailyUpdate),
        payload: jsonEncode(data),
      );
    }
  }

  void _onMessageOpenedApp(RemoteMessage message) {
    debugPrint('[FCM] Notification opened: ${message.data}');
    _maybeOpenDailyAnalysesFromPayload(message.data);
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[Notifications] Tapped payload: ${response.payload}');
    Map<String, dynamic>? data;
    final raw = response.payload;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          data = decoded;
        } else if (decoded is Map) {
          data = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        data = {'type': raw};
      }
    }
    _maybeOpenDailyAnalysesFromPayload(data);
  }

  void _maybeOpenDailyAnalysesFromPayload(Map<String, dynamic>? data) {
    if (data == null) return;
    final typeName = (data['type'] ?? data['notification_type'])?.toString();
    if (!isDailyAnalysesNotificationType(typeName)) return;
    if (onOpenDailyAnalyses != null) {
      onOpenDailyAnalyses!();
    } else {
      _pendingOpenDailyAnalyses = true;
    }
  }

  void _handleTypedPayload(
    String typeName,
    Map<String, dynamic> data,
    String? title,
    String? body,
  ) {
    final coin = (data['coin'] ?? 'BTC').toString();
    switch (typeName) {
      case 'analysisReady':
      case 'analysis_ready':
        showAnalysisReady(coin: coin, body: body);
        break;
      case 'tradeSetupTriggered':
      case 'trade_setup_triggered':
        showTradeSetupTriggered(coin: coin, body: body);
        break;
      case 'alertHit':
      case 'alert_hit':
        showAlertHit(coin: coin, condition: body);
        break;
      case 'dailyUpdate':
      case 'daily_update':
        showDailyUpdate(body: body ?? title);
        break;
      default:
        if (title != null || body != null) {
          _local.show(
            typeName.hashCode,
            title ?? 'On-Chain Oracle AI',
            body ?? '',
            _detailsFor(OracleNotificationType.dailyUpdate),
            payload: jsonEncode(data),
          );
        }
    }
  }

  AndroidNotificationChannel _channelFor(OracleNotificationType type) {
    return AndroidNotificationChannel(
      type.channelId,
      type.title,
      description: 'On-Chain Oracle AI — ${type.title}',
      importance: Importance.high,
    );
  }

  NotificationDetails _detailsFor(OracleNotificationType type) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        type.channelId,
        type.title,
        channelDescription: 'On-Chain Oracle AI — ${type.title}',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
