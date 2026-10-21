import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/services/preference_mirror_service.dart';
import 'package:mula/services/reminder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase database;
  late ProviderContainer container;
  final now = DateTime(2026, 10, 21, 8);

  ProviderContainer openApp(PreferenceMirrorService mirror) {
    return ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      appNowProvider.overrideWithValue(() => now),
      clockProvider.overrideWithValue(now),
      reminderServiceProvider.overrideWithValue(_Reminders()),
      preferenceMirrorProvider.overrideWithValue(mirror),
    ]);
  }

  setUp(() {
    database = AppDatabase(factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath, singleInstance: false);
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('native getAll failure still opens SQLite and saves onboarding', () async {
    var loads = 0;
    container = openApp(PreferenceMirrorService(load: () async {
      loads++;
      throw PlatformException(
        code: 'native_error',
        message: 'java.lang.NoSuchMethodError: SharedPreferencesApiRegistrar.getAll',
      );
    }));

    final initial = await container.read(appControllerProvider.future);
    expect(initial.tasks, isNotEmpty);
    expect(initial.user.flag('onboardingCompleted'), isFalse);
    final controller = container.read(appControllerProvider.notifier);
    await controller.saveUser(
      name: 'Anggit', wakeTime: '04:30', sleepTime: '22:00',
      strictnessLevel: 'Seimbang', onboardingCompleted: true,
    );
    await controller.setSelectedTab(2);

    final saved = container.read(appControllerProvider).requireValue;
    expect(saved.user.flag('onboardingCompleted'), isTrue);
    expect(saved.preferences['selectedTab'], '2');
    expect(loads, 1);
    expect((await (await database.database).query('app_preferences',
      where: 'key = ?', whereArgs: ['selectedTab'])).single.text('value'), '2');
  });

  test('native write failure cannot interrupt focus and SQLite preferences survive restart', () async {
    final native = _FailingPreferences();
    container = openApp(PreferenceMirrorService(load: () async => native));
    await container.read(appControllerProvider.future);
    final controller = container.read(appControllerProvider.notifier);

    await controller.startFiveMinutes();

    final saved = container.read(appControllerProvider).requireValue;
    expect(saved.preferences['sanctuary'], 'true');
    expect(saved.preferences['sanctuaryDate'], '2026-10-21');
    expect(saved.preferences['selectedTab'], '1');
    expect(saved.activeFocus!.number('plannedSeconds'), 300);
    final sessionId = saved.activeFocus!.number('id');
    expect(native.writeAttempts, 1);

    container.dispose();
    container = openApp(PreferenceMirrorService(load: () async {
      throw PlatformException(code: 'native_error', message: 'getAll unavailable');
    }));
    final restored = await container.read(appControllerProvider.future);
    expect(restored.preferences['sanctuary'], 'true');
    expect(restored.preferences['sanctuaryDate'], '2026-10-21');
    expect(restored.preferences['selectedTab'], '1');
    expect(restored.activeFocus!.number('id'), sessionId);
    expect(restored.activeFocus!.number('plannedSeconds'), 300);
  });
}

class _FailingPreferences extends Fake implements SharedPreferences {
  int writeAttempts = 0;

  @override
  Future<bool> setString(String key, String value) async {
    writeAttempts++;
    throw PlatformException(code: 'native_error', message: 'Native preference write failed');
  }
}

class _Reminders extends ReminderService {
  @override
  Future<void> initialize() async {}

  @override
  Future<String> scheduleFocus(DbRow session, {bool requestPermission = true}) async =>
      'Alarm tes terpasang.';
}
