import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/data/wellbeing_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDatabase;
  late MulaRepository mula;
  late WellbeingRepository wellbeing;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    now = DateTime(2026, 10, 29, 9);
    appDatabase = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    mula = MulaRepository(appDatabase, now: () => now);
    wellbeing = WellbeingRepository(appDatabase, now: () => now);
    await mula.initialize();
    await mula.loadDay(now);
  });
  tearDown(() => appDatabase.close());

  test('anxiety draft resumes after recreation and saves one timestamp-based result', () async {
    final session = await wellbeing.startSession(8);
    final same = await wellbeing.startSession(2);
    expect(same.text('id'), session.text('id'));
    expect(same.number('before'), 8);
    await wellbeing.setGrounding(0, true);
    await wellbeing.setGrounding(3, true);
    now = now.add(const Duration(minutes: 3, seconds: 17));
    final recreated = WellbeingRepository(appDatabase, now: () => now);
    final restored = (await recreated.activeSession())!;
    expect(restored.text('phase'), 'grounding');
    expect(restored['grounding'], [true, false, false, true, false]);
    expect(DateTime.parse(restored.text('startedAt')),
        DateTime(2026, 10, 29, 9).toUtc());
    expect(await recreated.finishSession(restored.text('id'), 4), isTrue);
    expect(await recreated.finishSession(restored.text('id'), 4), isFalse);
    expect(await recreated.activeSession(), isNull);
    final db = await appDatabase.database;
    final rows = await db.query('anxiety_sessions');
    expect(rows, hasLength(1));
    expect(rows.single.number('durationSeconds'), 197);
    expect(rows.single.number('anxietyBefore'), 8);
    expect(rows.single.number('anxietyAfter'), 4);
    expect((await mula.loadDay(now)).score.number('anxietyScore'), 4);
  });

  test('invalid ratings or stale routes cannot overwrite the active session', () async {
    await expectLater(wellbeing.startSession(0), throwsArgumentError);
    final session = await wellbeing.startSession(7);
    await expectLater(wellbeing.finishSession(session.text('id'), 11), throwsArgumentError);
    expect(await wellbeing.finishSession('older-route', 4), isFalse);
    expect((await wellbeing.activeSession())!.number('before'), 7);
    await expectLater(wellbeing.setGrounding(5, true), throwsRangeError);
    expect(await (await appDatabase.database).query('anxiety_sessions'), isEmpty);
  });

  test('backwards clock changes cannot create negative anxiety duration', () async {
    final session = await wellbeing.startSession(6);
    now = now.subtract(const Duration(hours: 1));
    await wellbeing.finishSession(session.text('id'), 5);
    final rows = await (await appDatabase.database).query('anxiety_sessions');
    expect(rows.single.number('durationSeconds'), 0);
  });

  test('browsing historical dates does not seed days or rewrite saved scores', () async {
    final db = await appDatabase.database;
    await mula.saveReflection(date: '2026-10-29', moodScore: 8, anxietyScore: 4,
        notes: 'Satu output selesai', gratitudeNote: 'Keluarga', firstStepTomorrow: 'Buka pengujian');
    final before = await db.query('daily_scores');
    final tasksBefore = await db.query('daily_tasks');
    final older = await wellbeing.day(DateTime(2026, 9, 10));
    expect(older.score, isNull);
    expect(older.tasks, isEmpty);
    expect(older.focusSeconds, 0);
    final range = await wellbeing.history(DateTime(2026, 9), DateTime(2026, 10, 31));
    expect(range.scores, hasLength(1));
    final today = await wellbeing.day(now);
    expect(today.score!.text('notes'), 'Satu output selesai');
    expect(await db.query('daily_scores'), before);
    expect(await db.query('daily_tasks'), tasksBefore);
  });

  test('weekly focus merges overlaps, clips midnight and excludes running timers', () async {
    final db = await appDatabase.database;
    Future<void> focus(DateTime started, int actual, int planned, DateTime completed) async {
      await db.insert('focus_sessions', {
        'userId': 1, 'mode': 'Deep Work', 'plannedSeconds': planned,
        'actualSeconds': actual, 'status': 'Selesai',
        'startedAt': started.toUtc().toIso8601String(),
        'completedAt': completed.toUtc().toIso8601String(),
      });
    }
    await focus(DateTime(2026, 10, 28, 23, 50), 1200, 1500,
        DateTime(2026, 10, 29, 0, 10));
    await focus(DateTime(2026, 10, 29, 0, 5), 900, 900,
        DateTime(2026, 10, 29, 0, 20));
    // Badly inflated actualSeconds is bounded by both plan and wall time.
    await focus(DateTime(2026, 10, 29, 1), 5000, 900,
        DateTime(2026, 10, 29, 1, 5));
    await db.insert('focus_sessions', {
      'userId': 1, 'mode': 'Deep Work', 'plannedSeconds': 3000,
      'startedAt': DateTime(2026, 10, 29, 8).toUtc().toIso8601String(),
    });
    final previous = await wellbeing.day(DateTime(2026, 10, 28));
    final today = await wellbeing.day(DateTime(2026, 10, 29));
    expect(previous.focusSeconds, 600);
    expect(today.focusSeconds, 1500);
    final week = await wellbeing.history(DateTime(2026, 10, 23), now);
    expect(week.totalFocusSeconds, 2100);
    // Completing task checklists does not fabricate focus minutes.
    final firstTask = (await mula.loadDay(now)).tasks.first;
    await mula.setTaskStatus(firstTask.number('id'), 'Selesai');
    expect((await wellbeing.history(DateTime(2026, 10, 23), now)).totalFocusSeconds, 2100);
  });

  test('history range rejects unbounded or backwards requests', () async {
    await expectLater(wellbeing.history(now, now.subtract(const Duration(days: 1))), throwsArgumentError);
    await expectLater(wellbeing.history(DateTime(2020), now), throwsArgumentError);
  });
}
