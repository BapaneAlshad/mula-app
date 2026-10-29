import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/data/schedule_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDatabase;
  late MulaRepository mula;
  late ScheduleRepository schedules;
  late DateTime now;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    now = DateTime(2026, 10, 29, 9);
    appDatabase = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    mula = MulaRepository(appDatabase, now: () => now);
    schedules = ScheduleRepository(appDatabase, now: () => now);
    await mula.initialize();
    await mula.loadDay(now);
  });
  tearDown(() => appDatabase.close());

  test('editing a recurring block preserves today and changes tomorrow only', () async {
    final original = (await mula.loadDay(now)).tasks.first;
    final templateId = original.number('sourceScheduleId');
    await mula.setTaskStatus(original.number('id'), 'Selesai');
    final before = await mula.loadDay(now);
    final beforeTask = before.tasks.first;
    await schedules.save(id: templateId, title: 'Aktivasi yang disesuaikan',
        startTime: '04:45', endTime: '05:30', category: 'Pribadi',
        days: [1, 2, 3, 4, 5, 6, 7], active: true,
        checklist: ['Minum air', 'Peregangan ringan']);
    // App restarts must not restore the seeder over an edited template.
    await mula.initialize();
    final after = await mula.loadDay(now);
    final preserved = after.tasks.singleWhere((task) => task.number('id') == original.number('id'));
    for (final field in ['title', 'description', 'category', 'startTime', 'endTime',
      'templateTitle', 'scheduleStartTime', 'scheduleEndTime', 'scheduleTitle',
      'estimatedMinutes', 'status', 'completedAt', 'subtasksJson', 'points']) {
      expect(preserved[field], beforeTask[field], reason: 'Today must preserve $field');
    }
    expect(after.score.number('totalScore'), before.score.number('totalScore'));
    expect(after.score.number('totalScore'), greaterThan(0));
    expect(after.templates.singleWhere((row) => row.number('id') == templateId)
        .text('effectiveFrom'), '2026-10-30');
    final tomorrow = await mula.loadDay(DateTime(2026, 10, 30));
    final changed = tomorrow.tasks.singleWhere((task) => task.number('sourceScheduleId') == templateId);
    expect(changed.text('title'), 'Aktivasi yang disesuaikan');
    expect(changed.text('startTime'), '04:45');
    expect(changed.text('endTime'), '05:30');
    expect(changed.text('category'), 'Pribadi');
    expect(changed.number('estimatedMinutes'), 45);
    expect(changed.text('description'), '04:45–05:30\nMinum air\nPeregangan ringan');
    expect(changed.text('status'), 'Belum mulai');
    expect(jsonDecode(changed.text('subtasksJson')),
        [{'title': 'Minum air', 'done': false}, {'title': 'Peregangan ringan', 'done': false}]);
    expect((await mula.loadDay(now)).score.number('totalScore'), before.score.number('totalScore'));
  });

  test('new transition block starts tomorrow and is not duplicated by seeding', () async {
    await schedules.save(title: 'Transisi pulang kerja', startTime: '16:00',
        endTime: '17:00', category: 'Pribadi', days: [1, 2, 3, 4, 5, 6, 7],
        active: true, checklist: ['Istirahat', 'Hadir bersama keluarga']);
    var today = await mula.loadDay(now);
    expect(today.tasks, hasLength(14));
    expect(today.tasks.where((task) => task.text('title') == 'Transisi pulang kerja'), isEmpty);
    expect(today.templates, hasLength(15));
    final template = today.templates.singleWhere((row) => row.text('title') == 'Transisi pulang kerja');
    expect(template.number('sortOrder'), greaterThanOrEqualTo(1000));
    await mula.initialize();
    final tomorrow = await mula.loadDay(DateTime(2026, 10, 30));
    expect(tomorrow.tasks, hasLength(15));
    final added = tomorrow.tasks.singleWhere((task) => task.number('sourceScheduleId') == template.number('id'));
    expect(added.text('startTime'), '16:00');
    expect(added.text('endTime'), '17:00');
    expect(added.number('estimatedMinutes'), 60);
    today = await mula.loadDay(now);
    expect(today.tasks, hasLength(14));
    expect(today.templates, hasLength(15));
  });

  test('overlap and invalid inputs reject without mutating templates or daily tasks', () async {
    final db = await appDatabase.database;
    final beforeTemplates = await db.query('schedule_templates', orderBy: 'id');
    final beforeTasks = await db.query('daily_tasks', orderBy: 'id');
    Future<void> save({String title = 'Blok baru', String start = '16:00',
      String end = '17:00', String category = 'Pribadi',
      List<int> days = const [1, 2, 3, 4, 5, 6, 7],
      List<String> checklist = const ['Satu langkah']}) => schedules.save(
        title: title, startTime: start, endTime: end, category: category,
        days: days, active: true, checklist: checklist);
    await expectLater(save(start: '15:59'), throwsStateError);
    await expectLater(save(end: '17:01'), throwsStateError);
    await expectLater(save(title: '  '), throwsArgumentError);
    await expectLater(save(start: '24:00'), throwsArgumentError);
    await expectLater(save(start: '9:00'), throwsArgumentError);
    await expectLater(save(start: '17:00', end: '16:00'), throwsArgumentError);
    await expectLater(save(start: '16:00', end: '16:00'), throwsArgumentError);
    await expectLater(save(category: 'Tidak valid'), throwsArgumentError);
    await expectLater(save(days: []), throwsArgumentError);
    await expectLater(save(days: [0, 8]), throwsArgumentError);
    await expectLater(save(days: [5, 5]), throwsArgumentError);
    await expectLater(save(checklist: ['']), throwsArgumentError);
    await expectLater(save(checklist: List<String>.filled(31, 'Langkah')), throwsArgumentError);
    await expectLater(schedules.save(id: 9999, title: 'Tidak ada', startTime: '16:00',
        endTime: '17:00', category: 'Pribadi', days: [5], active: false,
        checklist: []), throwsStateError);
    expect(await db.query('schedule_templates', orderBy: 'id'), beforeTemplates);
    expect(await db.query('daily_tasks', orderBy: 'id'), beforeTasks);
  });

  test('identical times on disjoint weekdays are allowed and seed matching dates', () async {
    await schedules.save(title: 'Transisi Jumat', startTime: '16:00', endTime: '17:00',
        category: 'Pribadi', days: [5], active: true, checklist: []);
    await schedules.save(title: 'Transisi Sabtu', startTime: '16:00', endTime: '17:00',
        category: 'Pribadi', days: [6], active: true, checklist: []);
    await expectLater(schedules.save(title: 'Tumpang tindih Jumat', startTime: '16:20',
        endTime: '16:40', category: 'Pribadi', days: [5], active: true,
        checklist: []), throwsStateError);
    final friday = await mula.loadDay(DateTime(2026, 10, 30));
    final saturday = await mula.loadDay(DateTime(2026, 10, 31));
    expect(friday.tasks.where((task) => task.text('title') == 'Transisi Jumat'), hasLength(1));
    expect(friday.tasks.where((task) => task.text('title') == 'Transisi Sabtu'), isEmpty);
    expect(saturday.tasks.where((task) => task.text('title') == 'Transisi Sabtu'), hasLength(1));
    expect(saturday.tasks.where((task) => task.text('title') == 'Transisi Jumat'), isEmpty);
  });

  test('disabling tomorrow retains today and survives repository initialization', () async {
    final before = await mula.loadDay(now);
    final original = before.tasks.first;
    await schedules.save(id: original.number('sourceScheduleId'), title: original.text('templateTitle'),
        startTime: original.text('startTime'), endTime: original.text('endTime'),
        category: original.text('category'), days: [1, 2, 3, 4, 5, 6, 7],
        active: false, checklist: ['Dinonaktifkan']);
    await mula.initialize();
    final today = await mula.loadDay(now);
    expect(today.tasks, hasLength(14));
    expect(today.tasks.singleWhere((task) => task.number('id') == original.number('id'))
        .text('description'), original.text('description'));
    expect(today.templates.singleWhere((row) => row.number('id') == original.number('sourceScheduleId'))
        .flag('isActive'), isFalse);
    final tomorrow = await mula.loadDay(DateTime(2026, 10, 30));
    expect(tomorrow.tasks, hasLength(13));
    expect(tomorrow.tasks.where((task) => task.number('sourceScheduleId') == original.number('sourceScheduleId')),
        isEmpty);
  });

  test('version two migration snapshots schedule identity without changing saved completion', () async {
    final directory = await Directory.systemTemp.createTemp('mula-schedule-migration-');
    final file = path.join(directory.path, 'v2.db');
    AppDatabase? migrated;
    try {
      final old = await databaseFactoryFfi.openDatabase(file,
          options: OpenDatabaseOptions(version: 2, singleInstance: false,
              onCreate: (database, version) async {
        await database.execute('CREATE TABLE schedule_templates (id INTEGER PRIMARY KEY, title TEXT, startTime TEXT, endTime TEXT)');
        await database.execute('CREATE TABLE daily_tasks (id INTEGER PRIMARY KEY, sourceScheduleId INTEGER, title TEXT, description TEXT, status TEXT, points INTEGER)');
        await database.execute('CREATE TABLE daily_scores (id INTEGER PRIMARY KEY, totalScore INTEGER)');
        await database.insert('schedule_templates', {'id': 7, 'title': 'Fokus pagi', 'startTime': '09:30', 'endTime': '10:30'});
        await database.insert('daily_tasks', {'id': 11, 'sourceScheduleId': 7,
          'title': 'Output yang sudah selesai', 'description': '09:30–10:30\nUji login',
          'status': 'Selesai', 'points': 15});
        await database.insert('daily_tasks', {'id': 12, 'sourceScheduleId': null,
          'title': 'Tugas mandiri', 'description': 'Tanpa jadwal', 'status': 'Belum mulai', 'points': 0});
        await database.insert('daily_scores', {'id': 1, 'totalScore': 45});
      }));
      await old.close();
      migrated = AppDatabase(factory: databaseFactoryFfi, databasePath: file, singleInstance: false);
      final database = await migrated.database;
      expect(await database.getVersion(), 3);
      final tasks = await database.query('daily_tasks', orderBy: 'id');
      expect(tasks.first.text('scheduleStartTime'), '09:30');
      expect(tasks.first.text('scheduleEndTime'), '10:30');
      expect(tasks.first.text('scheduleTitle'), 'Fokus pagi');
      expect(tasks.first.text('title'), 'Output yang sudah selesai');
      expect(tasks.first.text('description'), '09:30–10:30\nUji login');
      expect(tasks.first.text('status'), 'Selesai');
      expect(tasks.first.number('points'), 15);
      expect(tasks.last['scheduleStartTime'], isNull);
      expect((await database.query('daily_scores')).single.number('totalScore'), 45);
      expect((await database.query('schedule_templates')).single.text('effectiveFrom'), '');
    } finally {
      await migrated?.close();
      await directory.delete(recursive: true);
    }
  });
}
