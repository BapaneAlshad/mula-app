import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/daily_score_calculator.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDatabase;
  late MulaRepository repository;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    now = DateTime(2026, 10, 21, 8);
    appDatabase = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    repository = MulaRepository(appDatabase, now: () => now);
    await repository.initialize();
  });
  tearDown(() => appDatabase.close());

  Future<DbRow> top(String priority) async => (await repository.loadDay(now))
      .tasks.singleWhere((task) => task.text('priority') == priority);

  test('minimum mode has exactly seven persistent items and independent score', () async {
    var snapshot = await repository.loadDay(now);
    final normal = snapshot.tasks.first;
    await repository.setTaskStatus(normal.number('id'), 'Selesai');
    final normalScore = (await repository.loadDay(now)).score.number('totalScore');
    await repository.saveDayMode('2026-10-21', 'Minimum');
    snapshot = await repository.loadDay(now);
    expect(snapshot.tasks, hasLength(14));
    expect(snapshot.minimumTasks, hasLength(7));
    expect(snapshot.minimumTasks.map((task) => task.text('minimumKey')),
        ['prayer', 'water', 'movement', 'main', 'family', 'closing', 'sleep']);
    expect(snapshot.score.number('totalScore'), 0);
    for (final task in snapshot.minimumTasks) {
      await repository.setTaskStatus(task.number('id'), 'Selesai');
    }
    snapshot = await repository.loadDay(now);
    expect(snapshot.score.number('totalScore'), 100);
    expect(snapshot.minimumTasks.fold<int>(0, (sum, task) => sum + task.number('points')), 100);
    await repository.saveDayMode('2026-10-21', 'Normal');
    snapshot = await repository.loadDay(now);
    expect(snapshot.score.number('totalScore'), normalScore);
    expect(snapshot.tasks.first.text('status'), 'Selesai');
    await repository.saveDayMode('2026-10-21', 'Minimum');
    expect((await repository.loadDay(now)).score.number('totalScore'), 100);
  });

  test('task editor persists every field, moves unique priorities and validates reasons', () async {
    final oldTop = await top('Top 1');
    await repository.saveTask(date: '2026-10-21', title: 'Menguji fungsi login',
        description: 'Jalankan skenario login berhasil dan gagal.', category: 'Tim',
        deadline: '2026-10-22', estimatedMinutes: 35, energyLevel: 'Tinggi',
        priority: 'Top 1', pointWeight: 80,
        subtasks: [{'title': 'Login berhasil', 'done': false},
          {'title': 'Login gagal', 'done': false}]);
    var snapshot = await repository.loadDay(now);
    final edited = snapshot.tasks.singleWhere((task) => task.text('priority') == 'Top 1');
    expect(edited.text('title'), 'Menguji fungsi login');
    expect(edited.text('description'), contains('berhasil dan gagal'));
    expect(edited.text('deadline'), '2026-10-22');
    expect(edited.text('energyLevel'), 'Tinggi');
    expect(edited.number('pointWeight'), 80);
    expect(jsonDecode(edited.text('subtasksJson')), hasLength(2));
    expect(snapshot.tasks.singleWhere((task) => task['id'] == oldTop['id'])
        .text('priority'), 'Reguler');
    await repository.assignPriority(oldTop.number('id'), 'Top 1');
    snapshot = await repository.loadDay(now);
    expect(snapshot.tasks.where((task) => task.text('priority') == 'Top 1'), hasLength(1));
    await expectLater(repository.setTaskStatus(edited.number('id'), 'Dilewati'), throwsArgumentError);
    await expectLater(repository.setTaskStatus(edited.number('id'), 'Ditunda', reason: ' '), throwsArgumentError);
    await repository.setTaskStatus(edited.number('id'), 'Dilewati', reason: 'Menunggu akses pengujian');
    snapshot = await repository.loadDay(now);
    expect(snapshot.tasks.singleWhere((task) => task['id'] == edited['id'])
        .text('skippedReason'), 'Menunggu akses pengujian');
  });

  test('Top 2 focus has a soft gate and remembers Top 1 started after a reset', () async {
    final first = await top('Top 1');
    final second = await top('Top 2');
    await expectLater(repository.startFocus(taskId: second.number('id'),
        plannedSeconds: 300, mode: '5 menit'), throwsStateError);
    await repository.startFocus(taskId: second.number('id'), plannedSeconds: 300,
        mode: '5 menit', allowPriorityOverride: true);
    await repository.finishFocus(cancel: true);
    await repository.startFocus(taskId: first.number('id'), plannedSeconds: 300, mode: '5 menit');
    await repository.finishFocus(cancel: true);
    await repository.setTaskStatus(first.number('id'), 'Belum mulai');
    await repository.startFocus(taskId: second.number('id'), plannedSeconds: 300, mode: '5 menit');
    expect((await repository.loadDay(now)).activeFocus!.number('taskId'), second.number('id'));
  });

  test('new completed subtasks persist completed Top 1 and unlock its gate', () async {
    await repository.saveTask(date: '2026-10-21', title: 'Menguji satu fungsi login',
        description: 'Skenario berhasil.', category: 'Tim', estimatedMinutes: 25,
        energyLevel: 'Sedang', priority: 'Top 1', pointWeight: 10,
        subtasks: [{'title': 'Jalankan pengujian login', 'done': true}]);
    final first = await top('Top 1');
    expect(first.text('status'), 'Selesai');
    expect(first.text('completedAt'), isNotEmpty);
    expect(first.text('startedAt'), isNotEmpty);
    now = DateTime(2026, 10, 21, 11, 45);
    expect((await repository.loadDay(now)).valorantGate.flag('allowed'), isTrue);
  });

  test('swipe Undo restores checklist and timestamp but ignores later edits or expired Undo', () async {
    final task = (await repository.loadDay(now)).tasks.first;
    await repository.setChecklistItem(task.number('id'), 0, true);
    final previous = await repository.captureTaskState(task.number('id'));
    await repository.setTaskStatus(task.number('id'), 'Selesai');
    now = now.add(const Duration(seconds: 4));
    await repository.restoreTaskState(previous);
    var restored = (await repository.loadDay(now)).tasks.first;
    expect(restored.text('status'), previous.text('status'));
    expect(restored.text('subtasksJson'), previous.text('subtasksJson'));
    expect(restored['completedAt'], previous['completedAt']);
    final beforeSecondSwipe = await repository.captureTaskState(task.number('id'));
    await repository.setTaskStatus(task.number('id'), 'Selesai');
    await repository.assignPriority(task.number('id'), 'Top 3');
    await repository.restoreTaskState(beforeSecondSwipe);
    restored = (await repository.loadDay(now)).tasks.first;
    expect(restored.text('status'), 'Selesai');
    final expired = await repository.captureTaskState(task.number('id'));
    await repository.setTaskStatus(task.number('id'), 'Selesai');
    now = now.add(const Duration(seconds: 6));
    await repository.restoreTaskState(expired);
    expect((await repository.loadDay(now)).tasks.first.text('status'), 'Selesai');
  });

  test('planning deadline persists and starts Top 1 once using the resume timestamp', () async {
    await repository.startPlanning();
    final first = (await repository.loadDay(now)).planningSession!;
    now = now.add(const Duration(minutes: 10));
    await repository.startPlanning();
    expect((await repository.loadDay(now)).planningSession!['deadlineAt'], first['deadlineAt']);
    expect(await repository.completePlanningAndStartTop1(), isFalse);
    now = now.add(const Duration(minutes: 70));
    repository = MulaRepository(appDatabase, now: () => now);
    expect(await repository.completePlanningAndStartTop1(), isTrue);
    var snapshot = await repository.loadDay(now);
    expect(snapshot.planningSession!.text('status'), 'Dieksekusi');
    expect(snapshot.activeFocus!.number('taskId'), (await top('Top 1')).number('id'));
    expect(DateTime.parse(snapshot.activeFocus!.text('startedAt')), now.toUtc());
    expect(await repository.completePlanningAndStartTop1(), isFalse);
    snapshot = await repository.loadDay(now);
    expect(snapshot.activeFocus!.number('actualSeconds'), 0);
    expect(await (await appDatabase.database).query('focus_sessions'), hasLength(1));
  });

  test('planning ends another active session atomically and refuses a late start', () async {
    await repository.startPlanning();
    await repository.startFocus(plannedSeconds: 3600, mode: 'Fokus sementara');
    now = now.add(const Duration(minutes: 20));
    expect(await repository.completePlanningAndStartTop1(), isTrue);
    final rows = await (await appDatabase.database).query('focus_sessions', orderBy: 'id');
    expect(rows.first.text('status'), 'Dibatalkan');
    expect(rows.first.number('actualSeconds'), 1200);
    expect(rows.last.text('status'), 'Berjalan');
    now = DateTime(2026, 10, 22, 10);
    await expectLater(repository.startPlanning(), throwsStateError);
  });

  test('minimum mode cancels planning and a different day never auto-starts old planning', () async {
    await repository.startPlanning();
    await repository.saveDayMode('2026-10-21', 'Minimum');
    expect((await repository.loadDay(now)).planningSession!.text('status'), 'Dibatalkan');
    await expectLater(repository.startPlanning(), throwsStateError);
    now = now.add(const Duration(minutes: 25));
    expect(await repository.completePlanningAndStartTop1(), isFalse);
    expect((await repository.loadDay(now)).activeFocus, isNull);
    now = DateTime(2026, 10, 22, 8);
    await repository.startPlanning();
    now = DateTime(2026, 10, 23, 8);
    expect(await repository.completePlanningAndStartTop1(), isFalse);
    expect((await repository.loadDay(now)).activeFocus, isNull);
    final rows = await (await appDatabase.database).query('planning_sessions',
        where: 'date = ?', whereArgs: ['2026-10-22']);
    expect(rows.single.text('status'), 'Dibatalkan');
  });

  test('planning replaces an expired short Top 1 session with a fresh 25-minute session', () async {
    await repository.startPlanning();
    final first = await top('Top 1');
    now = now.add(const Duration(minutes: 1));
    await repository.startFocus(taskId: first.number('id'), plannedSeconds: 300, mode: '5 menit');
    now = now.add(const Duration(minutes: 30));
    expect(await repository.completePlanningAndStartTop1(), isTrue);
    final rows = await (await appDatabase.database).query('focus_sessions', orderBy: 'id');
    expect(rows, hasLength(2));
    expect(rows.first.text('status'), 'Selesai');
    expect(rows.first.number('actualSeconds'), 300);
    expect(DateTime.parse(rows.first.text('completedAt')), DateTime(2026, 10, 21, 8, 6).toUtc());
    expect(rows.last.text('status'), 'Berjalan');
    expect(rows.last.number('plannedSeconds'), 1500);
    expect(DateTime.parse(rows.last.text('startedAt')), now.toUtc());
  });

  test('VALORANT requires the time window and morning target, consumes one match', () async {
    now = DateTime(2026, 10, 21, 11, 45);
    await expectLater(repository.startValorant(), throwsStateError);
    await repository.setTaskStatus((await top('Top 1')).number('id'), 'Selesai');
    final session = await repository.startValorant();
    expect(DateTime.parse(session.text('alarmAt')).difference(
        DateTime.parse(session.text('startedAt'))), const Duration(minutes: 45));
    expect((await repository.loadDay(now)).valorantGate.flag('quotaUsed'), isTrue);
    await expectLater(repository.startValorant(), throwsStateError);
    now = DateTime(2026, 10, 21, 13);
    expect(await repository.confirmValorantClosed(), isFalse);
    expect((await repository.loadDay(now)).score.flag('valorantPenaltyNextDay'), isFalse);
    await expectLater(repository.startValorant(), throwsStateError);
  });

  test('a fully completed morning focus unlocks the match without completing Top 1', () async {
    now = DateTime(2026, 10, 21, 10);
    await repository.startFocus(plannedSeconds: 300, mode: '5 menit');
    now = now.add(const Duration(minutes: 5));
    await repository.finishFocus();
    now = DateTime(2026, 10, 21, 11, 45);
    expect((await repository.loadDay(now)).valorantGate.flag('allowed'), isTrue);
    await repository.startValorant();
  });

  test('unconfirmed offline match carries its penalty across midnight and adaptation protects today', () async {
    now = DateTime(2026, 10, 21, 11, 45);
    await repository.setTaskStatus((await top('Top 1')).number('id'), 'Selesai');
    await repository.startValorant();
    now = DateTime(2026, 10, 22, 11, 45);
    var snapshot = await repository.loadDay(now);
    expect(snapshot.valorantGate.flag('penalty'), isTrue);
    expect(snapshot.valorantSession!.text('date'), '2026-10-21');
    expect(await repository.confirmValorantClosed(), isTrue);
    await repository.setTaskStatus((await top('Top 1')).number('id'), 'Selesai');
    await expectLater(repository.startValorant(), throwsStateError);
    await expectLater(repository.saveDayMode('2026-10-22', 'Adaptasi', reason: 'Cemas'), throwsArgumentError);
    await repository.saveDayMode('2026-10-22', 'Adaptasi', reason: 'Sakit');
    snapshot = await repository.loadDay(now);
    expect(snapshot.score.flag('consequencesDisabled'), isTrue);
    expect(snapshot.score.flag('streakProtected'), isTrue);
    expect(snapshot.valorantGate.flag('penalty'), isFalse);
    expect(snapshot.streak, greaterThanOrEqualTo(1));
    await repository.startValorant();
    now = DateTime(2026, 10, 22, 13, 1);
    expect(await repository.confirmValorantClosed(), isFalse);
    expect((await repository.loadDay(now)).score.flag('valorantPenaltyNextDay'), isFalse);
    await repository.saveDayMode('2026-10-22', 'Normal');
    expect((await repository.loadDay(now)).score.flag('streakProtected'), isFalse);
  });

  test('alarm setup failure can refund only a freshly started match', () async {
    now = DateTime(2026, 10, 21, 11, 45);
    await repository.setTaskStatus((await top('Top 1')).number('id'), 'Selesai');
    final session = await repository.startValorant();
    await repository.rollbackValorantStart(session.number('id'));
    expect((await repository.loadDay(now)).valorantGate.flag('allowed'), isTrue);
    final second = await repository.startValorant();
    now = now.add(const Duration(minutes: 2));
    await expectLater(repository.rollbackValorantStart(second.number('id')), throwsStateError);
    expect((await repository.loadDay(now)).valorantGate.flag('quotaUsed'), isTrue);
  });

  test('point weights affect allocation while task focus still uses its estimated duration', () {
    final tasks = <DbRow>[
      {'id': 1, 'category': 'Tim', 'estimatedMinutes': 60, 'pointWeight': 3, 'status': 'Selesai'},
      {'id': 2, 'category': 'Tim', 'estimatedMinutes': 60, 'pointWeight': 1, 'status': 'Belum mulai'},
    ];
    expect(DailyScoreCalculator.taskPoints(tasks), {1: 26, 2: 9});
    final score = DailyScoreCalculator.calculate(tasks: tasks, sessions: const [], day: now, now: now);
    expect(score['workScore'], 26);
  });

  test('v1 migration keeps task, score and preference data and normalizes duplicate Top slots', () async {
    final directory = await Directory.systemTemp.createTemp('mula-migration-');
    final databasePath = path.join(directory.path, 'v1.db');
    AppDatabase? migrated;
    try {
      final old = await databaseFactoryFfi.openDatabase(databasePath,
          options: OpenDatabaseOptions(version: 1, singleInstance: false,
              onCreate: (database, version) async {
        await database.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
        await database.execute('CREATE TABLE daily_tasks (id INTEGER PRIMARY KEY, userId INTEGER, date TEXT, priority TEXT, title TEXT, status TEXT, points INTEGER)');
        await database.execute('CREATE TABLE daily_scores (id INTEGER PRIMARY KEY, userId INTEGER, date TEXT, totalScore INTEGER)');
        await database.execute('CREATE TABLE app_preferences (key TEXT PRIMARY KEY, value TEXT)');
        await database.insert('users', {'id': 1, 'name': 'Anggit'});
        for (final id in [1, 2]) {
          await database.insert('daily_tasks', {'id': id, 'userId': 1, 'date': '2026-10-21',
            'priority': 'Top 1', 'title': 'Hasil lama $id', 'status': 'Selesai', 'points': 7});
        }
        await database.insert('daily_scores', {'id': 1, 'userId': 1, 'date': '2026-10-21', 'totalScore': 42});
        await database.insert('app_preferences', {'key': 'sensitiveLock', 'value': 'true'});
      }));
      await old.close();
      migrated = AppDatabase(factory: databaseFactoryFfi, databasePath: databasePath, singleInstance: false);
      final database = await migrated.database;
      expect(await database.getVersion(), 2);
      final tasks = await database.query('daily_tasks', orderBy: 'id');
      expect(tasks, hasLength(2));
      expect(tasks.first.text('title'), 'Hasil lama 1');
      expect(tasks.first.text('status'), 'Selesai');
      expect(tasks.first.number('points'), 7);
      expect(tasks.first.text('priority'), 'Top 1');
      expect(tasks.last.text('priority'), 'Reguler');
      expect(tasks.first['pointWeight'], isNull);
      expect((await database.query('daily_scores')).single.number('totalScore'), 42);
      expect((await database.query('app_preferences')).single.text('value'), 'true');
      expect(await database.query('planning_sessions'), isEmpty);
      expect(await database.query('valorant_sessions'), isEmpty);
    } finally {
      await migrated?.close();
      await directory.delete(recursive: true);
    }
  });
}
