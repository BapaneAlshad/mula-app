import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local/app_database.dart';
import '../data/mula_repository.dart';
import '../domain/app_snapshot.dart';
import '../domain/focus_clock.dart';
import '../services/privacy_service.dart';
import '../services/reminder_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final repositoryProvider = Provider<MulaRepository>(
  (ref) => MulaRepository(ref.watch(databaseProvider)),
);
final reminderServiceProvider = Provider<ReminderService>((ref) => ReminderService());
final privacyServiceProvider = Provider<PrivacyService>((ref) => PrivacyService());
final thoughtsUnlockedProvider = StateProvider<bool>((ref) => false);

final _clockStreamProvider = StreamProvider<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(
    const Duration(seconds: 1), (_) => DateTime.now(),
  );
});

final clockProvider = Provider<DateTime>(
  (ref) => ref.watch(_clockStreamProvider).valueOrNull ?? DateTime.now(),
);

final appControllerProvider = AsyncNotifierProvider<AppController, AppSnapshot>(
  AppController.new,
);

class AppController extends AsyncNotifier<AppSnapshot> {
  late MulaRepository _repository;
  late ReminderService _reminders;
  SharedPreferences? _preferences;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;
  bool _refreshingClock = false;
  bool _autoFinishing = false;

  @override
  Future<AppSnapshot> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _repository = ref.watch(repositoryProvider);
    _reminders = ref.watch(reminderServiceProvider);
    _preferences = await SharedPreferences.getInstance();
    await _repository.initialize();
    ref.listen<DateTime>(clockProvider, _onTick);
    final snapshot = await _repository.loadDay(DateTime.now());
    await _restoreReminders(snapshot);
    return _repository.loadDay(DateTime.now());
  }

  Future<void> _restoreReminders(AppSnapshot snapshot) async {
    try {
      await _reminders.initialize();
      if (snapshot.preferences['reminders'] == 'true') {
        await _reminders.scheduleTemplates(snapshot.templates);
      }
      if (snapshot.activeFocus != null) {
        final message = await _reminders.scheduleFocus(
          snapshot.activeFocus!, requestPermission: false,
        );
        await _repository.savePreference('reminderStatus', message);
      }
    } catch (error) {
      await _repository.savePreference(
        'reminderStatus', 'Data tersimpan. Pengingat belum aktif: $error',
      );
    }
  }

  void _onTick(DateTime? previous, DateTime now) {
    if (_disposed) return;
    final snapshot = state.valueOrNull;
    if (snapshot == null) return;
    final session = snapshot.activeFocus;
    if (session != null && !_autoFinishing) {
      final startedAt = DateTime.tryParse(session.text('startedAt'));
      if (startedAt != null &&
          FocusClock(
            startedAt: startedAt, plannedSeconds: session.number('plannedSeconds'),
          ).isCompleteAt(now)) {
        _autoFinishing = true;
        unawaited(_autoComplete(session.number('id')).whenComplete(() {
          _autoFinishing = false;
        }).catchError((Object error, StackTrace stack) {
          debugPrint('Penyelesaian fokus akan dicoba ulang: $error');
        }));
      }
    }
    final changedDay = snapshot.date != _dayKey(now);
    final changedMinute = previous != null &&
        (previous.minute != now.minute || previous.hour != now.hour);
    if (!_refreshingClock && (changedDay || (session != null && changedMinute))) {
      _refreshingClock = true;
      unawaited(refresh().whenComplete(() {
        _refreshingClock = false;
      }).catchError((Object error, StackTrace stack) {
        debugPrint('Pembaruan harian akan dicoba ulang: $error');
      }));
    }
  }

  static String _dayKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Future<void> _reload() async {
    final snapshot = await _repository.loadDay(DateTime.now());
    if (!_disposed) state = AsyncData(snapshot);
  }

  /// Serialize writes while retaining the current screen during disk operations.
  Future<void> _mutate(Future<void> Function() mutation) {
    final operation = _pending.then((_) async {
      try {
        await mutation();
      } finally {
        await _reload();
      }
    });
    _pending = operation.catchError((Object error, StackTrace stack) {
      debugPrint('Operasi MULA gagal: $error');
    });
    return operation;
  }

  Future<void> refresh() => _mutate(() async {
    final snapshot = await _repository.loadDay(DateTime.now());
    if (state.valueOrNull?.date != snapshot.date &&
        snapshot.preferences['reminders'] == 'true') {
      await _restoreReminders(snapshot);
    }
  });

  Future<void> onResume() => _mutate(() async {
    final snapshot = await _repository.loadDay(DateTime.now());
    await _restoreReminders(snapshot);
  });

  Future<void> saveUser({
    required String name,
    required String wakeTime,
    required String sleepTime,
    required String strictnessLevel,
    required bool onboardingCompleted,
  }) => _mutate(() => _repository.saveUser(
    name: name, wakeTime: wakeTime, sleepTime: sleepTime,
    strictnessLevel: strictnessLevel, onboardingCompleted: onboardingCompleted,
  ));

  Future<void> setTaskStatus(int id, String status, {String? reason}) =>
      _mutate(() => _repository.setTaskStatus(id, status, reason: reason));

  Future<void> setChecklistItem(int taskId, int index, bool done) =>
      _mutate(() => _repository.setChecklistItem(taskId, index, done));

  Future<void> addTask({
    required String title,
    required String category,
    required String priority,
    required int estimatedMinutes,
  }) => _mutate(() => _repository.addTask(
    title: title, category: category, priority: priority,
    estimatedMinutes: estimatedMinutes, date: _dayKey(DateTime.now()),
  ));

  Future<void> overrideProject({required int taskId, required String project}) =>
      _mutate(() => _repository.overrideProject(taskId: taskId, project: project));

  Future<void> _writePreference(String key, String value) async {
    await _repository.savePreference(key, value);
    await _preferences?.setString(key, value);
  }

  Future<void> savePreference(String key, String value) =>
      _mutate(() => _writePreference(key, value));

  Future<void> setSelectedTab(int index) {
    if (index < 0 || index > 4) throw ArgumentError.value(index, 'index');
    return savePreference('selectedTab', '$index');
  }

  Future<void> setDayMode(String mode, {String? reason}) => _mutate(() async {
    await _repository.saveDayMode(_dayKey(DateTime.now()), mode, reason: reason);
    await _writePreference('sanctuary', mode == 'Normal' ? 'false' : 'true');
  });

  Future<void> enterSanctuary(String reason) => _mutate(() async {
    await _repository.saveDayMode(
      _dayKey(DateTime.now()), reason == 'Mode Hari Buruk' ? 'Minimum' : 'Adaptasi',
      reason: reason,
    );
    await _repository.recordAnxiety(
      mode: reason, durationSeconds: 0,
      anxietyBefore: state.valueOrNull?.score.number('anxietyScore', 5) ?? 5,
      anxietyAfter: state.valueOrNull?.score.number('anxietyScore', 5) ?? 5,
    );
    await _writePreference('sanctuary', 'true');
  });

  Future<void> exitSanctuary() => setDayMode('Normal');

  Future<void> addThought({
    required String content, required String type, required int intensity,
    required bool needsAction, required String nextAction,
  }) => _mutate(() => _repository.addThought(
    content: content, type: type, intensity: intensity,
    needsAction: needsAction, nextAction: nextAction,
  ));

  Future<void> setThoughtStatus(int id, String status) =>
      _mutate(() => _repository.setThoughtStatus(id, status));

  Future<void> saveReflection({
    required int moodScore, required int anxietyScore, required String notes,
    required String gratitudeNote, required String firstStepTomorrow,
  }) => _mutate(() => _repository.saveReflection(
    date: _dayKey(DateTime.now()), moodScore: moodScore,
    anxietyScore: anxietyScore, notes: notes, gratitudeNote: gratitudeNote,
    firstStepTomorrow: firstStepTomorrow,
  ));

  Future<void> startFocus({
    int? taskId, required int plannedSeconds, required String mode,
  }) => _mutate(() async {
    await _repository.startFocus(
      taskId: taskId, plannedSeconds: plannedSeconds, mode: mode,
    );
    final snapshot = await _repository.loadDay(DateTime.now());
    try {
      final message = await _reminders.scheduleFocus(snapshot.activeFocus!);
      await _writePreference('reminderStatus', message);
    } catch (error) {
      await _writePreference('reminderStatus', 'Timer aktif; alarm belum terpasang: $error');
    }
  });

  Future<void> finishFocus({bool cancel = false, String? reason}) =>
      _mutate(() async {
        final completed = await _repository.finishFocus(cancel: cancel, reason: reason);
        if (completed) await _reminders.cancelFocus();
      });

  Future<void> _autoComplete(int sessionId) => _mutate(() async {
    final snapshot = await _repository.loadDay(DateTime.now());
    if (snapshot.activeFocus?.number('id') != sessionId) return;
    // Native notification delivery remains independent from foreground ticks.
    await _repository.finishFocus(expectedSessionId: sessionId);
  });

  Future<void> configureReminders(bool enabled) => _mutate(() async {
    if (!enabled) {
      await _reminders.cancelSchedule();
      await _writePreference('reminders', 'false');
      return;
    }
    if (!await _reminders.requestAccess()) {
      await _writePreference('reminders', 'false');
      throw StateError('Izin notifikasi belum diberikan. Aktifkan di pengaturan Android.');
    }
    final snapshot = await _repository.loadDay(DateTime.now());
    await _reminders.scheduleTemplates(snapshot.templates);
    await _writePreference('reminders', 'true');
  });

  Future<void> setPrivacyLock(bool enabled) async {
    final authenticated = await ref.read(privacyServiceProvider).authenticate();
    if (!authenticated) throw StateError('Verifikasi perangkat dibatalkan.');
    await savePreference('privacyLock', '$enabled');
    ref.read(thoughtsUnlockedProvider.notifier).state = false;
  }

  Future<bool> unlockThoughts() async {
    final authenticated = await ref.read(privacyServiceProvider).authenticate();
    if (authenticated) {
      await savePreference('lastUnlockAt', DateTime.now().toIso8601String());
      ref.read(thoughtsUnlockedProvider.notifier).state = true;
    }
    return authenticated;
  }
}
