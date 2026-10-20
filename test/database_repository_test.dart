import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDatabase;
  late MulaRepository repository;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    now = DateTime(2026, 10, 21, 9, 30);
    appDatabase = AppDatabase(
        factory: databaseFactoryFfi, databasePath: inMemoryDatabasePath);
    repository = MulaRepository(appDatabase, now: () => now);
    await repository.initialize();
  });
  tearDown(() => appDatabase.close());

  test('seed and daily creation are idempotent and preserve user edits', () async {
    var snapshot = await repository.loadDay(now);
    expect(snapshot.templates, hasLength(14));
    expect(snapshot.tasks, hasLength(14));
    expect(snapshot.user.text('name'), 'Anggit');
    expect(snapshot.user.text('wakeTime'), '04:30');
    final id = snapshot.tasks.first.number('id');
    await repository.setTaskStatus(id, 'Selesai');
    await repository.saveUser(name: 'Anggit Baru', wakeTime: '05:00',
        sleepTime: '21:30', strictnessLevel: 'Lembut', onboardingCompleted: true);
    await repository.initialize();
    snapshot = await repository.loadDay(now);
    expect(snapshot.templates, hasLength(14));
    expect(snapshot.tasks, hasLength(14));
    expect(snapshot.tasks.first.text('status'), 'Selesai');
    expect(snapshot.user.text('name'), 'Anggit Baru');
    expect(snapshot.user.flag('onboardingCompleted'), isTrue);
    expect(snapshot.score.number('totalScore'), greaterThan(0));
    await expectLater(repository.saveUser(name: 'Anggit', wakeTime: '06:00',
        sleepTime: '06:00', strictnessLevel: 'Lembut', onboardingCompleted: true),
        throwsArgumentError);
  });

  test('project rotation and deadline override only change the selected day', () async {
    final monday = await repository.loadDay(DateTime(2026, 10, 19));
    final tuesday = await repository.loadDay(DateTime(2026, 10, 20));
    final sunday = await repository.loadDay(DateTime(2026, 10, 25));
    DbRow project(AppSnapshot snapshot, String start) =>
        snapshot.tasks.singleWhere((task) => task.text('startTime') == start);
    expect(project(monday, '13:00').text('title'), contains('RUMA App'));
    expect(project(tuesday, '13:00').text('title'), contains('Sidangode'));
    expect(project(monday, '20:00').text('title'), contains('Sidangode'));
    expect(project(tuesday, '20:45').text('title'), contains('Personal branding'));
    expect(project(sunday, '13:00').text('title'), contains('istirahat'));
    expect(project(sunday, '20:45').text('title'), contains('istirahat'));
    await repository.overrideProject(
        taskId: project(monday, '13:00').number('id'), project: 'Deadline pelanggan');
    final edited = await repository.loadDay(DateTime(2026, 10, 19));
    expect(project(edited, '13:00').text('title'), contains('Deadline pelanggan'));
    expect(project(await repository.loadDay(DateTime(2026, 10, 20)), '13:00')
        .text('title'), contains('Sidangode'));
    expect(monday.templates.singleWhere((row) => row.text('startTime') == '13:00')
        .text('title'), 'Deep Work Proyek');
    await expectLater(repository.overrideProject(
        taskId: monday.tasks.first.number('id'), project: 'Tidak sah'), throwsArgumentError);
  });

  test('checklist completion, undo and all-task completion recompute scores', () async {
    var snapshot = await repository.loadDay(now);
    final first = snapshot.tasks.first;
    final checklist = jsonDecode(first.text('subtasksJson')) as List;
    for (var index = 0; index < checklist.length; index++) {
      await repository.setChecklistItem(first.number('id'), index, true);
    }
    snapshot = await repository.loadDay(now);
    expect(snapshot.tasks.first.text('status'), 'Selesai');
    final completedScore = snapshot.score.number('totalScore');
    await repository.setChecklistItem(first.number('id'), 0, false);
    snapshot = await repository.loadDay(now);
    expect(snapshot.tasks.first.text('status'), 'Sedang berjalan');
    expect(snapshot.tasks.first['completedAt'], isNull);
    expect(snapshot.score.number('totalScore'), lessThanOrEqualTo(completedScore));
    for (final task in snapshot.tasks) {
      await repository.setTaskStatus(task.number('id'), 'Selesai');
    }
    snapshot = await repository.loadDay(now);
    expect(snapshot.score.number('morningScore'), 20);
    expect(snapshot.score.number('workScore'), 35);
    expect(snapshot.score.number('healthFamilyScore'), 25);
    expect(snapshot.score.number('sideJobScore'), 20);
    expect(snapshot.score.number('totalScore'), 100);
    expect(snapshot.tasks.fold<int>(0, (sum, task) => sum + task.number('points')), 100);
    await repository.setTaskStatus(first.number('id'), 'Belum mulai');
    snapshot = await repository.loadDay(now);
    final resetChecklist = jsonDecode(snapshot.tasks.first.text('subtasksJson')) as List;
    expect(resetChecklist.every((item) => item['done'] == false), isTrue);
    expect(snapshot.score.number('totalScore'), lessThan(100));
  });

  test('focus survives reload, uses timestamps and ignores stale alarm completion', () async {
    final initial = await repository.loadDay(now);
    final task = initial.tasks.singleWhere((row) => row.text('startTime') == '09:30');
    await repository.startFocus(taskId: task.number('id'), plannedSeconds: 3000, mode: '50/10');
    final active = (await repository.loadDay(now)).activeFocus!;
    expect(DateTime.parse(active.text('startedAt')).isUtc, isTrue);
    now = now.add(const Duration(minutes: 70));
    expect(await repository.finishFocus(expectedSessionId: active.number('id')), isTrue);
    var snapshot = await repository.loadDay(now);
    expect(snapshot.activeFocus, isNull);
    final database = await appDatabase.database;
    final sessions = await database.query('focus_sessions');
    expect(sessions.single.number('actualSeconds'), 3000);
    expect(sessions.single.text('status'), 'Selesai');
    await repository.startFocus(plannedSeconds: 1500, mode: '25/5');
    expect(await repository.finishFocus(expectedSessionId: active.number('id')), isFalse);
    snapshot = await repository.loadDay(now);
    expect(snapshot.activeFocus, isNotNull);
    await expectLater(repository.startFocus(plannedSeconds: 300, mode: '5 menit'),
        throwsStateError);
    now = now.add(const Duration(minutes: 5));
    expect(await repository.finishFocus(cancel: true, reason: 'Perlu kembali ke keluarga'),
        isTrue);
    expect(await repository.finishFocus(), isFalse);
    expect((await repository.loadDay(now)).activeFocus, isNull);
    final cancelled = (await database.query('focus_sessions', orderBy: 'id DESC')).first;
    expect(cancelled.text('status'), 'Dibatalkan');
    expect(cancelled.number('actualSeconds'), 300);
  });

  test('thoughts, reflection, anxiety and settings persist after reloading', () async {
    await repository.addThought(content: 'Cek brief besok', type: 'Tugas',
        intensity: 4, needsAction: true, nextAction: 'Buka brief pagi');
    var snapshot = await repository.loadDay(now);
    await repository.setThoughtStatus(snapshot.thoughts.single.number('id'), 'Ditinjau');
    await repository.saveReflection(date: '2026-10-21', moodScore: 7, anxietyScore: 4,
        notes: 'Terlalu banyak rapat', gratitudeNote: 'Makan bersama',
        firstStepTomorrow: 'Buka proyek RUMA');
    await repository.recordAnxiety(mode: 'Pernapasan', durationSeconds: 90,
        anxietyBefore: 7, anxietyAfter: 3);
    await repository.savePreference('sensitiveLock', 'true');
    await repository.saveDayMode('2026-10-21', 'Minimum', reason: 'Istirahat');
    snapshot = await repository.loadDay(now);
    expect(snapshot.thoughts.single.text('status'), 'Ditinjau');
    expect(snapshot.score.number('moodScore'), 7);
    expect(snapshot.score.number('anxietyScore'), 3);
    expect(snapshot.score.text('gratitudeNote'), 'Makan bersama');
    expect(snapshot.score.text('dayMode'), 'Minimum');
    expect(snapshot.preferences['sensitiveLock'], 'true');
    final database = await appDatabase.database;
    expect(await database.query('anxiety_sessions'), hasLength(1));
  });

  test('SQLite enforces foreign keys, ranges and one task per source/day', () async {
    final snapshot = await repository.loadDay(now);
    final database = await appDatabase.database;
    expect((await database.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
    expect((await database.rawQuery('PRAGMA busy_timeout')).single.values.single, 5000);
    await expectLater(database.insert('thought_parkings', {
      'userId': 999, 'content': 'invalid', 'type': 'Ide', 'intensity': 4,
      'createdAt': now.toIso8601String(),
    }), throwsA(isA<DatabaseException>()));
    await expectLater(database.insert('anxiety_sessions', {
      'userId': 1, 'mode': 'Napas', 'durationSeconds': 60,
      'anxietyBefore': 11, 'anxietyAfter': 1, 'completedAt': now.toIso8601String(),
    }), throwsA(isA<DatabaseException>()));
    final task = Map<String, Object?>.from(snapshot.tasks.first)
      ..remove('id') ..remove('startTime') ..remove('endTime')
      ..remove('templateTitle') ..remove('sortOrder');
    await expectLater(database.insert('daily_tasks', task),
        throwsA(isA<DatabaseException>()));
  });
}
