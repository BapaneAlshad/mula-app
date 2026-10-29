import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/local/default_schedule_seeder.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/services/alarm_diagnostics_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase database;
  late _AlarmPlatform platform;
  late AlarmDiagnosticsService service;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    database = AppDatabase(factory: databaseFactoryFfi, databasePath: inMemoryDatabasePath,
        singleInstance: false);
    await DefaultScheduleSeeder.seed(await database.database);
    now = DateTime.utc(2026, 10, 29, 3);
    platform = _AlarmPlatform();
    service = AlarmDiagnosticsService(database, platform, now: () => now);
  });
  tearDown(() => database.close());

  test('test alarm uses a persistent deadline and never confirms delivery automatically', () async {
    await service.startTest();
    expect(platform.deadlines.single, now.add(const Duration(minutes: 1)));
    final beforeRestart = await service.load();
    expect(beforeRestart.test!.text('status'), 'scheduled');
    expect(beforeRestart.isDue(now), isFalse);
    expect(beforeRestart.test!['confirmedAt'], isNull);
    await expectLater(service.recordResult(true), throwsStateError);
    now = now.add(const Duration(minutes: 3));
    final recreated = AlarmDiagnosticsService(database, platform, now: () => now);
    final afterRestart = await recreated.load();
    expect(afterRestart.isDue(now), isTrue);
    expect(afterRestart.test!.text('status'), 'scheduled');
    expect(afterRestart.test!['confirmedAt'], isNull);
    await recreated.recordResult(true);
    final result = (await recreated.load()).test!;
    expect(result.text('status'), 'received');
    expect(result.text('confirmedBy'), 'user');
    expect(result.text('confirmedAt'), now.toIso8601String());
    expect(platform.cancelled, 1);
  });

  test('denied alarm access schedules nothing and does not replace previous result', () async {
    await service.startTest();
    now = now.add(const Duration(minutes: 1));
    await service.recordResult(false);
    platform.allowed = false;
    await expectLater(service.startTest(), throwsStateError);
    expect(platform.deadlines, hasLength(1));
    expect((await service.load()).test!.text('status'), 'notReceived');
  });

  test('partial native scheduling failure is cancelled and remains an explicit failure', () async {
    platform.failSchedule = true;
    await expectLater(service.startTest(), throwsStateError);
    final state = await service.load();
    expect(state.test!.text('status'), 'failed');
    expect(state.test!.text('error'), contains('schedule failed'));
    expect(state.awaitingResult, isFalse);
    expect(platform.cancelled, 1);
  });

  test('cancelling a test persists cancellation and prevents recording a result', () async {
    await service.startTest();
    await service.cancelTest();
    now = now.add(const Duration(minutes: 2));
    expect((await service.load()).test!.text('status'), 'cancelled');
    await expectLater(service.recordResult(true), throwsStateError);
  });

  test('device inspection and settings actions persist audit without claiming a grant', () async {
    platform.allowed = false;
    await service.requestNotifications();
    await service.openSettings('exact');
    final current = await service.load();
    expect(current.deviceStatus!.canTest, isFalse);
    final rows = await (await database.database).query('app_preferences');
    final prefs = {for (final row in rows) row.text('key'): row.text('value')};
    expect(prefs['alarmTestNotificationRequest'], endsWith(':false'));
    expect(prefs['alarmTestLastSettings'], endsWith(':exact'));
    expect(prefs['alarmTestLastCheck'], now.toIso8601String());
    expect(prefs[AlarmDiagnosticsService.stateKey], isNull);
    expect(platform.settings, ['exact']);
  });

  test('native inspection failure retains prior persisted user result', () async {
    await service.startTest();
    now = now.add(const Duration(minutes: 1));
    await service.recordResult(false);
    platform.failInspect = true;
    final current = await service.load();
    expect(current.deviceStatus, isNull);
    expect(current.deviceError, contains('inspect failed'));
    expect(current.test!.text('status'), 'notReceived');
    final row = (await (await database.database).query('app_preferences',
        where: 'key = ?', whereArgs: [AlarmDiagnosticsService.stateKey])).single;
    expect((jsonDecode(row.text('value')) as Map)['confirmedBy'], 'user');
  });
}

class _AlarmPlatform implements AlarmDiagnosticsPlatform {
  bool allowed = true;
  bool failSchedule = false;
  bool failInspect = false;
  int cancelled = 0;
  final deadlines = <DateTime>[];
  final settings = <String>[];

  @override
  Future<AlarmDeviceStatus> inspect() async {
    if (failInspect) throw StateError('inspect failed');
    return AlarmDeviceStatus(notificationsAllowed: allowed, exactAlarmsAllowed: allowed,
        batteryUnrestricted: false, testChannelAllowed: true, doNotDisturb: false,
        androidVersion: '15', device: 'Test Android');
  }

  @override
  Future<bool> requestNotifications() async => allowed;
  @override
  Future<void> openSettings(String kind) async { settings.add(kind); }
  @override
  Future<void> scheduleTest(DateTime deadline) async {
    deadlines.add(deadline);
    if (failSchedule) throw StateError('schedule failed');
  }
  @override
  Future<void> cancelTest() async { cancelled++; }
}
