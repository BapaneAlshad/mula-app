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
import 'schedule_reminder_planner.dart';

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

@pragma('vm:entry-point')
Future<void> planningAlarmCallback(int alarmId, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final database = AppDatabase(singleInstance: false);
  try {
    final repository = MulaRepository(database);
    await repository.initialize();
    final snapshot = await repository.loadDay(DateTime.now());
    if (snapshot.planningSession?.number('id') != params['sessionId']) return;
    if (await repository.completePlanningAndStartTop1()) {
      await repository.savePreference('selectedTab', '1');
      final focus = (await repository.loadDay(DateTime.now())).activeFocus;
      if (focus != null) {
        await ReminderService().scheduleFocus(focus, requestPermission: false);
      }
    }
  } finally {
    await database.close();
  }
}

@pragma('vm:entry-point')
Future<void> valorantCutoffCallback(int alarmId, Map<String, dynamic> params) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final database = AppDatabase(singleInstance: false);
  try {
    final repository = MulaRepository(database);
    await repository.initialize();
    // Overdue, unconfirmed sessions are reconciled transactionally on every load.
    await repository.loadDay(DateTime.now());
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
  static const planningNotificationId = 710001;
  static const planningAlarmId = 710002;
  static const valorantNotificationId = 720001;
  static const valorantCutoffNotificationId = 720002;
  static const valorantCutoffAlarmId = 720003;

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

  Future<void> scheduleTemplates(List<DbRow> templates, {
    String strictness = 'Seimbang', List<DbRow> todayTasks = const [],
    bool includeToday = true,
  }) async {
    await initialize();
    if (!_isAndroid) return;
    final now = tz.TZDateTime.now(tz.local);
    final plan = ScheduleReminderPlanner.plan(templates,
        now: now, strictness: strictness, todayTasks: todayTasks, includeToday: includeToday);
    // Validate capacity before cancelling the existing working reminders.
    await cancelSchedule();
    final mode = await _canScheduleExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    for (final reminder in plan) {
        await _notifications.zonedSchedule(
          reminder.id,
          reminder.title,
          reminder.body,
          tz.TZDateTime.from(reminder.at, tz.local),
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
          payload: 'schedule',
        );
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

  Future<void> schedulePlanning(DbRow session, {bool requestPermission = false}) async {
    await initialize();
    if (!_isAndroid) return;
    await cancelPlanning();
    final allowed = requestPermission
        ? await requestAccess()
        : (await _android?.areNotificationsEnabled() ?? false);
    if (!allowed) return;
    final deadline = DateTime.parse(session.text('deadlineAt'));
    if (!deadline.isAfter(DateTime.now())) return;
    final exact = await _canScheduleExact;
    await _notifications.zonedSchedule(
      planningNotificationId,
      'Perencanaan cukup. Jalankan Top 1 🌱',
      'Batas 20 menit selesai. Mulai satu tindakan konkret selama 25 menit.',
      tz.TZDateTime.from(deadline, tz.local),
      _focusDetails,
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'planning',
    );
    if (exact && await AndroidAlarmManager.initialize()) {
      await AndroidAlarmManager.oneShotAt(
        deadline, planningAlarmId, planningAlarmCallback,
        exact: true, wakeup: true, allowWhileIdle: true, rescheduleOnReboot: true,
        params: <String, dynamic>{'sessionId': session.number('id')},
      );
    }
  }

  Future<void> cancelPlanning() async {
    await initialize();
    if (!_isAndroid) return;
    await _notifications.cancel(planningNotificationId);
    await AndroidAlarmManager.cancel(planningAlarmId);
  }

  /// Do not spend the daily match quota unless an exact native alarm is available.
  Future<void> requireGameAlarmAccess() async {
    await initialize();
    if (!_isAndroid) throw StateError('Alarm bermain tersedia pada perangkat Android.');
    final allowed = await requestAccess();
    if (!allowed || !await _canScheduleExact) {
      throw StateError('Aktifkan izin notifikasi dan alarm presisi Android sebelum bermain. Kuota belum dipakai.');
    }
  }

  Future<void> scheduleValorant(DbRow session, {bool requestPermission = false}) async {
    await initialize();
    if (!_isAndroid) throw StateError('Alarm bermain memerlukan Android.');
    if (requestPermission) await requireGameAlarmAccess();
    final allowed = await _android?.areNotificationsEnabled() ?? false;
    if (!allowed || !await _canScheduleExact) {
      throw StateError('Alarm VALORANT memerlukan izin notifikasi dan alarm presisi.');
    }
    await cancelValorant();
    final now = DateTime.now();
    final alarmAt = DateTime.parse(session.text('alarmAt'));
    final cutoffAt = DateTime.parse(session.text('cutoffAt'));
    for (final alarm in <({int id, DateTime time, String title, String body})>[
      (id: valorantNotificationId, time: alarmAt,
        title: '45 menit selesai. Tutup VALORANT.',
        body: 'Kembali ke MULA dan konfirmasi game sudah ditutup.'),
      (id: valorantCutoffNotificationId, time: cutoffAt,
        title: 'Pukul 13.00: kembali bekerja',
        body: 'Tutup game dan konfirmasi di MULA. Konfirmasi terlambat mengunci jatah besok.'),
    ]) {
      if (!alarm.time.isAfter(now)) continue;
      await _notifications.zonedSchedule(
        alarm.id, alarm.title, alarm.body,
        tz.TZDateTime.from(alarm.time, tz.local), _gameDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'valorant',
      );
    }
    if (cutoffAt.isAfter(now) && await AndroidAlarmManager.initialize()) {
      await AndroidAlarmManager.oneShotAt(
        cutoffAt, valorantCutoffAlarmId, valorantCutoffCallback,
        exact: true, wakeup: true, allowWhileIdle: true, rescheduleOnReboot: true,
        params: <String, dynamic>{'sessionId': session.number('id')},
      );
    }
  }

  static const _gameDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'mula_valorant', 'Batas bermain VALORANT',
      channelDescription: 'Alarm 45 menit dan pengingat kembali bekerja pukul 13.00',
      importance: Importance.max, priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.private,
      playSound: true, enableVibration: true,
    ),
  );

  Future<void> cancelValorant() async {
    await initialize();
    if (!_isAndroid) return;
    await _notifications.cancel(valorantNotificationId);
    await _notifications.cancel(valorantCutoffNotificationId);
    await AndroidAlarmManager.cancel(valorantCutoffAlarmId);
  }
}
