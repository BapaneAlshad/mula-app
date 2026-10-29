import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/services/backup_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase appDatabase;
  late MulaRepository repository;
  late _MemoryDocuments documents;
  late BackupService backups;
  final now = DateTime(2026, 10, 29, 10);

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    appDatabase = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    repository = MulaRepository(appDatabase, now: () => now);
    await repository.initialize();
    await repository.loadDay(now);
    documents = _MemoryDocuments();
    backups = BackupService(appDatabase, documents: documents, now: () => now);
  });
  tearDown(() => appDatabase.close());

  test('versioned JSON round-trip restores all ten tables after saving recovery file', () async {
    var day = await repository.loadDay(now);
    final taskId = day.tasks.first.number('id');
    await repository.setTaskStatus(taskId, 'Selesai');
    await repository.addThought(content: 'Catatan pribadi', type: 'Ide', intensity: 4,
        needsAction: true, nextAction: 'Tulis satu paragraf');
    await repository.saveReflection(date: day.date, moodScore: 8, anxietyScore: 3,
        notes: 'Sudah kembali', gratitudeNote: 'Keluarga', firstStepTomorrow: 'Buka editor');
    await repository.savePreference('alarmTestState', '{"status":"scheduled"}');
    await repository.savePreference('lastUnlockAt', now.toIso8601String());
    expect(await backups.exportBackup(), isTrue);
    final exported = documents.saved.single;
    final preview = await backups.inspect(exported);
    expect(preview.counts.keys, hasLength(10));
    expect(preview.counts['thought_parkings'], 1);
    await repository.saveUser(name: 'Sebelum dipulihkan', wakeTime: '05:00', sleepTime: '22:30',
        strictnessLevel: 'Tegas', onboardingCompleted: true);
    await repository.setTaskStatus(taskId, 'Belum mulai');
    await backups.restoreBackup(preview);
    day = await repository.loadDay(now);
    expect(day.user.text('name'), 'Anggit');
    expect(day.tasks.first.text('status'), 'Selesai');
    expect(day.thoughts.single.text('content'), 'Catatan pribadi');
    expect(day.score.text('gratitudeNote'), 'Keluarga');
    expect(day.preferences.containsKey('alarmTestState'), isFalse);
    expect(day.preferences.containsKey('lastUnlockAt'), isFalse);
    expect(day.preferences['lastRestoreAt'], now.toUtc().toIso8601String());
    expect(documents.saved, hasLength(2));
    final recovery = jsonDecode(documents.saved.last) as Map;
    expect((((recovery['tables'] as Map)['users'] as List).single as Map)['name'], 'Sebelum dipulihkan');
  });

  test('canceling save leaves preferences unchanged and canceling recovery never replaces data', () async {
    final preview = await backups.inspect(await backups.encodeBackup());
    documents.allowSave = false;
    expect(await backups.exportBackup(), isFalse);
    expect((await repository.loadDay(now)).preferences.containsKey('lastBackupAt'), isFalse);
    await repository.saveUser(name: 'Tetap milikku', wakeTime: '04:30', sleepTime: '22:00',
        strictnessLevel: 'Lembut', onboardingCompleted: true);
    await expectLater(backups.restoreBackup(preview), throwsStateError);
    expect((await repository.loadDay(now)).user.text('name'), 'Tetap milikku');
  });

  test('constraint failure after deletes rolls back every table and retains recovery document', () async {
    final document = jsonDecode(await backups.encodeBackup()) as Map<String, dynamic>;
    final tables = document['tables'] as Map<String, dynamic>;
    final tasks = tables['daily_tasks'] as List;
    final first = tasks.first as Map<String, dynamic>;
    first['status'] = 'Status tidak sah';
    final preview = await backups.inspect(jsonEncode(document));
    await expectLater(backups.restoreBackup(preview), throwsA(anything));
    final day = await repository.loadDay(now);
    expect(day.tasks, hasLength(14));
    expect(day.tasks.first.text('status'), 'Belum mulai');
    expect(day.templates, hasLength(14));
    expect(documents.saved, hasLength(1));
    expect(day.preferences.containsKey('lastRestoreAt'), isFalse);
  });

  test('invalid format, future schema, unknown tables and columns are rejected before save', () async {
    final valid = await backups.encodeBackup();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (document) => document['schemaVersion'] = 999,
      (document) => (document['tables'] as Map)['sqlite_master'] = <Object?>[],
      (document) => (((document['tables'] as Map)['users'] as List).single as Map)['injectedColumn'] = 'x',
      (document) => (((document['tables'] as Map)['daily_tasks'] as List).first as Map).remove('status'),
      (document) => (((document['tables'] as Map)['users'] as List).single as Map)['id'] = 2,
      (document) => (((document['tables'] as Map)['daily_tasks'] as List).first as Map)['subtasksJson'] = '{"broken":true}',
    ]) {
      final document = jsonDecode(valid) as Map<String, dynamic>;
      mutate(document);
      await expectLater(backups.inspect(jsonEncode(document)), throwsFormatException);
    }
    await expectLater(backups.inspect('not JSON'), throwsFormatException);
    expect(documents.saved, isEmpty);
  });

  test('running sessions block export and restore without touching local data', () async {
    final preview = await backups.inspect(await backups.encodeBackup());
    await repository.startFocus(plannedSeconds: 300, mode: 'Langkah kecil');
    await expectLater(backups.exportBackup(), throwsStateError);
    await expectLater(backups.restoreBackup(preview), throwsStateError);
    expect((await repository.loadDay(now)).activeFocus, isNotNull);
    expect(documents.saved, isEmpty);
    await repository.finishFocus(cancel: true, reason: 'Membuat cadangan');
    await repository.savePreference('anxietySession', '{"startedAt":"2026-10-29T03:00:00Z"}');
    await expectLater(backups.encodeBackup(), throwsStateError);
  });

  test('a write during the recovery picker aborts restore and preserves the newer data', () async {
    final preview = await backups.inspect(await backups.encodeBackup());
    documents.beforeSave = () => repository.addThought(content: 'Datang saat pemilih berkas terbuka',
        type: 'Ide', intensity: 4, needsAction: false, nextAction: '');
    await expectLater(backups.restoreBackup(preview), throwsStateError);
    final day = await repository.loadDay(now);
    expect(day.thoughts.single.text('content'), 'Datang saat pemilih berkas terbuka');
    expect(day.tasks, hasLength(14));
    expect(day.preferences.containsKey('lastRestoreAt'), isFalse);
    final recovery = jsonDecode(documents.saved.single) as Map;
    expect((recovery['tables'] as Map)['thought_parkings'], isEmpty);
  });

  test('oversize documents and canceled picker do not change the database', () async {
    expect(await backups.inspectBackup(), isNull);
    await expectLater(backups.inspect('x' * (BackupService.maxBytes + 1)), throwsFormatException);
    expect((await repository.loadDay(now)).user.text('name'), 'Anggit');
  });
}

class _MemoryDocuments implements BackupDocuments {
  bool allowSave = true;
  String? nextOpen;
  Future<void> Function()? beforeSave;
  final saved = <String>[];

  @override
  Future<String?> open() async => nextOpen;

  @override
  Future<bool> save(String filename, String contents) async {
    if (!allowSave) return false;
    await beforeSave?.call();
    saved.add(contents);
    return true;
  }
}
