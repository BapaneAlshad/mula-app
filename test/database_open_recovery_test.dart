import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/mula_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('failed open is retried and successful database remains shared', () async {
    final factory = _FailOnceFactory();
    final appDatabase = AppDatabase(factory: factory,
        databasePath: inMemoryDatabasePath, singleInstance: false);
    addTearDown(appDatabase.close);

    final first = appDatabase.database;
    final concurrent = appDatabase.database;
    await Future.wait([
      expectLater(first, throwsStateError),
      expectLater(concurrent, throwsStateError),
    ]);
    expect(factory.openAttempts, 1);

    final repository = MulaRepository(appDatabase,
        now: () => DateTime(2026, 10, 21, 8));
    await repository.initialize();
    final snapshot = await repository.loadDay(DateTime(2026, 10, 21, 8));
    final opened = await appDatabase.database;
    expect(factory.openAttempts, 2);
    expect(identical(await appDatabase.database, opened), isTrue);
    expect(snapshot.user.text('name'), 'Anggit');
    expect(snapshot.tasks, hasLength(14));
    expect(snapshot.templates, hasLength(14));
    expect((await opened.rawQuery('PRAGMA foreign_keys')).single['foreign_keys'], 1);
    expect((await opened.rawQuery('PRAGMA busy_timeout')).single['timeout'], 5000);

    await repository.savePreference('selectedTab', '3');
    expect((await repository.loadDay(DateTime(2026, 10, 21, 8)))
        .preferences['selectedTab'], '3');
    expect(factory.openAttempts, 2);
  });
}

class _FailOnceFactory extends Fake implements DatabaseFactory {
  int openAttempts = 0;

  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) async {
    openAttempts++;
    if (openAttempts == 1) throw StateError('Transient database open failure');
    return databaseFactoryFfi.openDatabase(path, options: options);
  }
}
