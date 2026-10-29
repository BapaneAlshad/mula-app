import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import '../application/app_controller.dart';
import '../data/local/app_database.dart';
import '../domain/app_snapshot.dart';

class AlarmDeviceStatus {
  const AlarmDeviceStatus({
    required this.notificationsAllowed,
    required this.exactAlarmsAllowed,
    required this.batteryUnrestricted,
    required this.testChannelAllowed,
    required this.doNotDisturb,
    required this.androidVersion,
    required this.device,
  });

  factory AlarmDeviceStatus.fromMap(Map<Object?, Object?> value) => AlarmDeviceStatus(
    notificationsAllowed: value['notificationsAllowed'] == true,
    exactAlarmsAllowed: value['exactAlarmsAllowed'] == true,
    batteryUnrestricted: value['batteryUnrestricted'] == true,
    testChannelAllowed: value['testChannelAllowed'] != false,
    doNotDisturb: value['doNotDisturb'] == true,
    androidVersion: '${value['androidVersion'] ?? ''}',
    device: '${value['device'] ?? 'Android'}',
  );

  final bool notificationsAllowed;
  final bool exactAlarmsAllowed;
  final bool batteryUnrestricted;
  final bool testChannelAllowed;
  final bool doNotDisturb;
  final String androidVersion;
  final String device;

  bool get canTest => notificationsAllowed && exactAlarmsAllowed && testChannelAllowed;
}

abstract interface class AlarmDiagnosticsPlatform {
  Future<AlarmDeviceStatus> inspect();
  Future<bool> requestNotifications();
  Future<void> openSettings(String kind);
  Future<void> scheduleTest(DateTime deadline);
  Future<void> cancelTest();
}

/// Uses the same native scheduled-notification path as focus and game alarms.
class AndroidAlarmDiagnosticsPlatform implements AlarmDiagnosticsPlatform {
  static const testNotificationId = 730001;
  static const _channel = MethodChannel('mula/device');
  final _notifications = FlutterLocalNotificationsPlugin();
  Future<void>? _initializing;

  Future<void> _initialize() => _initializing ??= _initializeNotifications();

  Future<void> _initializeNotifications() async {
    timezone_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
    await _notifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_mula'),
    ));
  }

  @override
  Future<AlarmDeviceStatus> inspect() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>('alarmDiagnostics');
    if (result == null) throw StateError('Status alarm Android belum tersedia.');
    return AlarmDeviceStatus.fromMap(result);
  }

  @override
  Future<bool> requestNotifications() async {
    await _initialize();
    return await _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> openSettings(String kind) async {
    final method = switch (kind) {
      'exact' => 'openAlarmSettings',
      'notifications' => 'openNotificationSettings',
      'battery' => 'openBatterySettings',
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    await _channel.invokeMethod<void>(method);
  }

  @override
  Future<void> scheduleTest(DateTime deadline) async {
    await _initialize();
    final status = await inspect();
    if (!status.canTest) throw StateError('Aktifkan notifikasi, kanal uji, dan alarm presisi dahulu.');
    await cancelTest();
    await _notifications.zonedSchedule(
      testNotificationId,
      'Uji alarm MULA',
      'Jika alarm ini terdengar saat layar terkunci, buka MULA dan catat hasil uji.',
      tz.TZDateTime.from(deadline, tz.local),
      const NotificationDetails(android: AndroidNotificationDetails(
        'mula_alarm_test', 'Uji alarm MULA',
        channelDescription: 'Pengujian alarm saat layar HP terkunci',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.private,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
      )),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'alarm-test',
    );
  }

  @override
  Future<void> cancelTest() async {
    await _initialize();
    await _notifications.cancel(testNotificationId);
  }
}

class AlarmDiagnosticsState {
  const AlarmDiagnosticsState({required this.test, this.deviceStatus, this.deviceError});
  final DbRow? test;
  final AlarmDeviceStatus? deviceStatus;
  final String? deviceError;
  DateTime? get dueAt => DateTime.tryParse(test?.text('dueAt') ?? '');
  bool get awaitingResult => test?.text('status') == 'scheduled';
  bool isDue(DateTime now) => dueAt != null && !now.isBefore(dueAt!);
}

class AlarmDiagnosticsService {
  AlarmDiagnosticsService(this._database, this._platform, {DateTime Function()? now})
      : _now = now ?? DateTime.now;
  final AppDatabase _database;
  final AlarmDiagnosticsPlatform _platform;
  final DateTime Function() _now;
  static const stateKey = 'alarmTestState';

  Future<void> _save(String key, String value) async {
    await (await _database.database).insert('app_preferences', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<AlarmDiagnosticsState> load() async {
    final rows = await (await _database.database).query('app_preferences',
        where: 'key = ?', whereArgs: [stateKey]);
    DbRow? test;
    if (rows.isNotEmpty) {
      try {
        final decoded = jsonDecode(rows.single.text('value'));
        if (decoded is Map<String, dynamic>) test = Map<String, Object?>.from(decoded);
      } on FormatException {
        test = {'status': 'invalid', 'error': 'Catatan uji lama tidak dapat dibaca. Jalankan uji baru.'};
      }
    }
    AlarmDeviceStatus? status;
    String? error;
    try {
      status = await _platform.inspect();
      await _save('alarmTestLastCheck', _now().toUtc().toIso8601String());
    } catch (failure) {
      error = 'Pemeriksaan perangkat belum tersedia: $failure';
    }
    return AlarmDiagnosticsState(test: test, deviceStatus: status, deviceError: error);
  }

  Future<void> startTest() async {
    final status = await _platform.inspect();
    if (!status.canTest) throw StateError('Aktifkan notifikasi, kanal uji, dan alarm presisi dahulu.');
    final startedAt = _now();
    final deadline = startedAt.add(const Duration(minutes: 1));
    final record = <String, Object?>{
      'status': 'scheduling',
      'scheduledAt': startedAt.toUtc().toIso8601String(),
      'dueAt': deadline.toUtc().toIso8601String(),
      'device': status.device,
      'androidVersion': status.androidVersion,
    };
    await _save(stateKey, jsonEncode(record));
    try {
      await _platform.scheduleTest(deadline);
      await _save(stateKey, jsonEncode({...record, 'status': 'scheduled'}));
    } catch (error) {
      try { await _platform.cancelTest(); } catch (_) { /* Original setup error is retained. */ }
      await _save(stateKey, jsonEncode({...record, 'status': 'failed', 'error': '$error'}));
      rethrow;
    }
  }

  Future<void> cancelTest() async {
    final current = await load();
    await _platform.cancelTest();
    await _save(stateKey, jsonEncode({
      ...?current.test,
      'status': 'cancelled',
      'cancelledAt': _now().toUtc().toIso8601String(),
    }));
  }

  Future<void> recordResult(bool received) async {
    final current = await load();
    if (!current.awaitingResult || !current.isDue(_now())) {
      throw StateError('Tunggu hingga waktu uji lewat sebelum mencatat hasil.');
    }
    await _platform.cancelTest();
    await _save(stateKey, jsonEncode({
      ...current.test!,
      'status': received ? 'received' : 'notReceived',
      'confirmedAt': _now().toUtc().toIso8601String(),
      'confirmedBy': 'user',
    }));
  }

  Future<void> requestNotifications() async {
    final allowed = await _platform.requestNotifications();
    await _save('alarmTestNotificationRequest', '${_now().toUtc().toIso8601String()}:$allowed');
  }

  Future<void> openSettings(String kind) async {
    await _platform.openSettings(kind);
    await _save('alarmTestLastSettings', '${_now().toUtc().toIso8601String()}:$kind');
  }
}

final alarmDiagnosticsPlatformProvider = Provider<AlarmDiagnosticsPlatform>(
    (ref) => AndroidAlarmDiagnosticsPlatform());
final alarmDiagnosticsServiceProvider = Provider<AlarmDiagnosticsService>((ref) =>
    AlarmDiagnosticsService(ref.watch(databaseProvider), ref.watch(alarmDiagnosticsPlatformProvider),
        now: ref.watch(appNowProvider)));
final alarmDiagnosticsProvider = AsyncNotifierProvider<AlarmDiagnosticsController, AlarmDiagnosticsState>(
    AlarmDiagnosticsController.new);

class AlarmDiagnosticsController extends AsyncNotifier<AlarmDiagnosticsState> {
  late AlarmDiagnosticsService _service;
  Future<void> _pending = Future<void>.value();

  @override
  Future<AlarmDiagnosticsState> build() async {
    _service = ref.watch(alarmDiagnosticsServiceProvider);
    return _service.load();
  }

  Future<void> _run(Future<void> Function() action) {
    final operation = _pending.then((_) async {
      try { await action(); } finally { state = AsyncData(await _service.load()); }
    });
    _pending = operation.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return operation;
  }

  Future<void> refresh() => _run(() async { await _service.load(); });
  Future<void> startTest() => _run(_service.startTest);
  Future<void> cancelTest() => _run(_service.cancelTest);
  Future<void> recordResult(bool received) => _run(() => _service.recordResult(received));
  Future<void> requestNotifications() => _run(_service.requestNotifications);
  Future<void> openSettings(String kind) => _run(() => _service.openSettings(kind));
}
