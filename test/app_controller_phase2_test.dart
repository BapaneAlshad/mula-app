import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late ProviderContainer container;
  late _Reminders reminders;
  late AppController controller;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 10, 21, 8);
    database = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    reminders = _Reminders();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      appNowProvider.overrideWithValue(() => now),
      clockProvider.overrideWithValue(now),
      reminderServiceProvider.overrideWithValue(reminders),
    ]);
    await container.read(appControllerProvider.future);
    controller = container.read(appControllerProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  AppSnapshot snapshot() => container.read(appControllerProvider).requireValue;

  Future<void> unlockGame() async {
    now = DateTime(2026, 10, 21, 11, 45);
    final first = snapshot().tasks.singleWhere((task) => task.text('priority') == 'Top 1');
    await controller.setTaskStatus(first.number('id'), 'Selesai');
    expect(snapshot().valorantGate.flag('allowed'), isTrue);
  }

  test('planning expiration refresh starts Top 1 and signals a single persisted handoff', () async {
    final top1 = snapshot().tasks.singleWhere((task) => task.text('priority') == 'Top 1');
    await controller.startPlanning();
    final planningDeadline = snapshot().planningSession!.text('deadlineAt');
    expect(reminders.planningScheduled, hasLength(1));
    expect(snapshot().activeFocus, isNull);

    now = now.add(const Duration(minutes: 20));
    await controller.refresh();
    final current = snapshot();
    expect(current.planningSession!.text('deadlineAt'), planningDeadline);
    expect(current.planningSession!.text('status'), 'Dieksekusi');
    expect(current.activeFocus!.number('taskId'), top1.number('id'));
    expect(current.activeFocus!.number('plannedSeconds'), 1500);
    expect(DateTime.parse(current.activeFocus!.text('startedAt')), now.toUtc());
    expect(current.tasks.singleWhere((task) => task['id'] == top1['id']).text('status'), 'Sedang berjalan');
    expect(current.preferences['selectedTab'], '1');
    expect((await SharedPreferences.getInstance()).getString('selectedTab'), '1');
    expect(container.read(planningHandoffProvider), 1);
    expect(reminders.planningCancelled, 1);
    expect(reminders.focusScheduled.single.number('taskId'), top1.number('id'));

    await controller.refresh();
    expect(container.read(planningHandoffProvider), 1);
    expect(await (await database.database).query('focus_sessions'), hasLength(1));
  });

  test('completion Undo within five seconds restores partial checklist and score', () async {
    final task = snapshot().tasks.first;
    final id = task.number('id');
    await controller.setChecklistItem(id, 0, true);
    final before = snapshot();
    final original = before.tasks.singleWhere((task) => task.number('id') == id);
    expect(original.text('status'), 'Sedang berjalan');
    final undo = await controller.completeTaskWithUndo(id);
    final completed = snapshot().tasks.singleWhere((task) => task.number('id') == id);
    expect(completed.text('status'), 'Selesai');
    expect((jsonDecode(completed.text('subtasksJson')) as List<dynamic>)
        .every((item) => (item as Map<String, dynamic>)['done'] == true), isTrue);
    expect(snapshot().score.number('totalScore'), greaterThan(before.score.number('totalScore')));

    now = now.add(const Duration(seconds: 4));
    await controller.restoreTask(undo);
    final restored = snapshot().tasks.singleWhere((task) => task.number('id') == id);
    expect(restored.text('status'), original.text('status'));
    expect(restored.text('subtasksJson'), original.text('subtasksJson'));
    expect(restored['completedAt'], original['completedAt']);
    expect(snapshot().score.number('totalScore'), before.score.number('totalScore'));
  });

  test('completion Undo rejects the exact five second boundary and retains completion', () async {
    final id = snapshot().tasks.first.number('id');
    final undo = await controller.completeTaskWithUndo(id);
    now = now.add(const Duration(seconds: 5));
    await expectLater(controller.restoreTask(undo), throwsStateError);
    expect(snapshot().tasks.singleWhere((task) => task.number('id') == id).text('status'), 'Selesai');
  });

  test('denied native alarm permission leaves match quota available', () async {
    await unlockGame();
    reminders.denyGamePermission = true;
    await expectLater(controller.startValorant(), throwsStateError);
    expect(reminders.permissionChecks, 1);
    expect(reminders.valorantScheduled, isEmpty);
    expect(snapshot().score.flag('valorantUsed'), isFalse);
    expect(snapshot().valorantGate.flag('allowed'), isTrue);
    expect(await (await database.database).query('valorant_sessions'), isEmpty);
  });

  test('alarm setup failure cancels partial alarms and refunds quota for retry', () async {
    await unlockGame();
    reminders.failGameSchedule = true;
    await expectLater(controller.startValorant(), throwsStateError);
    expect(reminders.valorantScheduled, hasLength(1));
    expect(reminders.valorantCancelled, 1);
    expect(snapshot().score.flag('valorantUsed'), isFalse);
    expect(snapshot().valorantGate.flag('allowed'), isTrue);
    expect(await (await database.database).query('valorant_sessions'), isEmpty);

    reminders.failGameSchedule = false;
    await controller.startValorant();
    expect(snapshot().score.flag('valorantUsed'), isTrue);
    expect(snapshot().valorantSession, isNotNull);
    expect(reminders.valorantScheduled, hasLength(2));
    expect(DateTime.parse(reminders.valorantScheduled.last.text('alarmAt'))
        .difference(DateTime.parse(reminders.valorantScheduled.last.text('startedAt'))), const Duration(minutes: 45));
    expect(await (await database.database).query('valorant_sessions'), hasLength(1));
  });
}

class _Reminders extends ReminderService {
  int initialized = 0;
  int planningCancelled = 0;
  int valorantCancelled = 0;
  int permissionChecks = 0;
  bool denyGamePermission = false;
  bool failGameSchedule = false;
  final List<DbRow> planningScheduled = [];
  final List<DbRow> focusScheduled = [];
  final List<DbRow> valorantScheduled = [];

  @override
  Future<void> initialize() async {
    initialized++;
  }

  @override
  Future<void> schedulePlanning(DbRow session, {bool requestPermission = false}) async {
    planningScheduled.add(Map<String, Object?>.from(session));
  }

  @override
  Future<void> cancelPlanning() async {
    planningCancelled++;
  }

  @override
  Future<String> scheduleFocus(DbRow session, {bool requestPermission = true}) async {
    focusScheduled.add(Map<String, Object?>.from(session));
    return 'Alarm tes terpasang.';
  }

  @override
  Future<void> requireGameAlarmAccess() async {
    permissionChecks++;
    if (denyGamePermission) throw StateError('Izin alarm ditolak.');
  }

  @override
  Future<void> scheduleValorant(DbRow session, {bool requestPermission = false}) async {
    valorantScheduled.add(Map<String, Object?>.from(session));
    if (failGameSchedule) throw StateError('Alarm native gagal dipasang.');
  }

  @override
  Future<void> cancelValorant() async {
    valorantCancelled++;
  }
}
