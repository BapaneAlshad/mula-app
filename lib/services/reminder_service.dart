import 'dart:convert';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import '../data/local/app_database.dart';
import '../data/mula_repository.dart';
import '../domain/app_snapshot.dart';

/// Runs in a separate engine: the database, not an in-memory timer, owns a session.
@pragma('vm:entry-point')
Future<void> focusAlarmCallback(int alarmId, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final database = AppDatabase(singleInstance: false);
  try {
    final repository = MulaRepository(database);
    await repository.initialize();
    final snapshot = await repository.loadDay(DateTime.now());
    final session = snapshot.activeFocus;
    if (session == null || session.number('id') != params['sessionId']) return;
    final startedAt = DateTime.tryParse(session.text('startedAt'));
    if (startedAt == null ||
        DateTime.now().difference(startedAt).inSeconds <
            session.number('plannedSeconds')) {
      return;
    }
    // Delivery belongs to the native notification receiver. This callback only
    // reconciles SQLite; the plugin's dispatcher does not await async callbacks.
    await repository.finishFocus(expectedSessionId: session.number('id'));
  } finally {
    await database.close();
  }
}

class ReminderService {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  Future<void>? _initializing;
  static const focusAlarmId = 700002;
  static const focusNotificationId = 700001;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    timezone_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
    if (!_isAndroid) return;
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_mula'),
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _notifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> requestAccess() async {
    await initialize();
    if (!_isAndroid) return false;
    final allowed = await _android?.requestNotificationsPermission() ?? false;
    if (allowed) {
      await _android?.requestExactAlarmsPermission();
    }
    return allowed;
  }

  Future<bool> get _canScheduleExact async =>
      await _android?.canScheduleExactNotifications() ?? false;

  Future<void> scheduleTemplates(List<DbRow> templates) async {
    await initialize();
    if (!_isAndroid) return;
    await cancelSchedule();
    final mode = await _canScheduleExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    final now = tz.TZDateTime.now(tz.local);
    for (final template in templates.where((row) => row.flag('isActive'))) {
      final time = template.text('startTime').split(':');
      final hour = int.parse(time[0]);
      final minute = int.parse(time[1]);
      final weekdays = (jsonDecode(template.text('daysOfWeek', '[1,2,3,4,5,6,7]'))
              as List<dynamic>)
          .map((value) => int.parse('$value'));
      for (final weekday in weekdays) {
        var next = tz.TZDateTime(
          tz.local, now.year, now.month, now.day, hour, minute,
        );
        while (next.weekday != weekday || !next.isAfter(now)) {
          next = tz.TZDateTime(
            tz.local, next.year, next.month, next.day + 1, hour, minute,
          );
        }
        await _notifications.zonedSchedule(
          10000 + template.number('id') * 10 + weekday,
          template.text('title'),
          'Kembali ke blok berikutnya. Mulai dari satu langkah kecil.',
          next,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'mula_schedule', 'Blok harian MULA',
              channelDescription: 'Pengingat jadwal Anggit setiap hari',
              importance: Importance.high,
              priority: Priority.high,
              visibility: NotificationVisibility.private,
            ),
          ),
          androidScheduleMode: mode,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          payload: 'schedule',
        );
      }
    }
  }

  Future<void> cancelSchedule() async {
    await initialize();
    if (!_isAndroid) return;
    final pending = await _notifications.pendingNotificationRequests();
    for (final notification in pending) {
      if (notification.payload == 'schedule') {
        await _notifications.cancel(notification.id);
      }
    }
  }

  /// Returns the delivery mode so a permission limitation remains visible.
  Future<String> scheduleFocus(DbRow session, {bool requestPermission = true}) async {
    await initialize();
    if (!_isAndroid) return 'Timer aktif; alarm tersedia pada Android.';
    await cancelFocus();
    final allowed = requestPermission
        ? await requestAccess()
        : (await _android?.areNotificationsEnabled() ?? false);
    if (!allowed) return 'Timer aktif. Izin notifikasi belum diberikan.';
    final expiresAt = DateTime.parse(session.text('startedAt')).add(
      Duration(seconds: session.number('plannedSeconds')),
    );
    if (!expiresAt.isAfter(DateTime.now())) return 'Sesi telah mencapai target.';
    final exact = await _canScheduleExact;
    // Native delivery does not depend on the Dart background engine staying alive.
    await _notifications.zonedSchedule(
      focusNotificationId,
      'Satu langkah selesai 🌱',
      'Blok fokusmu mencapai target. Ambil jeda tanpa HP.',
      tz.TZDateTime.from(expiresAt, tz.local),
      _focusDetails,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'focus',
    );
    if (exact) {
      try {
        final initialized = await AndroidAlarmManager.initialize();
        if (initialized) {
          final scheduled = await AndroidAlarmManager.oneShotAt(
            expiresAt,
            focusAlarmId,
            focusAlarmCallback,
            exact: true,
            wakeup: true,
            allowWhileIdle: true,
            rescheduleOnReboot: true,
            params: <String, dynamic>{'sessionId': session.number('id')},
          );
          if (scheduled) return 'Alarm presisi aktif, termasuk saat layar terkunci.';
        }
      } on PlatformException catch (error) {
        debugPrint('AlarmManager fallback: ${error.code}');
      }
    }
    return exact
        ? 'Pengingat fokus presisi aktif.'
        : 'Timer aktif. Pengingat dapat terlambat tanpa izin alarm presisi.';
  }

  static const _focusDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'mula_focus', 'Selesai fokus',
      channelDescription: 'Alarm akhir sesi fokus',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.private,
    ),
  );

  Future<void> cancelFocus() async {
    await initialize();
    if (!_isAndroid) return;
    await AndroidAlarmManager.cancel(focusAlarmId);
    await _notifications.cancel(focusNotificationId);
  }
}
