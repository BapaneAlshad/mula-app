import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/mula_repository.dart';
import '../data/schedule_repository.dart';
import '../domain/app_snapshot.dart';
import '../domain/focus_clock.dart';
import '../services/preference_mirror_service.dart';
import '../services/privacy_service.dart';
import '../services/reminder_service.dart';
import '../services/backup_service.dart';
import '../services/alarm_diagnostics_service.dart';
import '../features/wellbeing/application/wellbeing_providers.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final appNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final repositoryProvider = Provider<MulaRepository>((ref) => MulaRepository(
  ref.watch(databaseProvider), now: ref.watch(appNowProvider),
));
final reminderServiceProvider = Provider<ReminderService>((ref) => ReminderService());
final privacyServiceProvider = Provider<PrivacyService>((ref) => PrivacyService());
final preferenceMirrorProvider = Provider<PreferenceMirrorService>((ref) => PreferenceMirrorService());
final backupServiceProvider = Provider<BackupService>((ref) => BackupService(
  ref.watch(databaseProvider), now: ref.watch(appNowProvider),
));
final thoughtsUnlockedProvider = StateProvider<bool>((ref) => false);
final planningHandoffProvider = StateProvider<int>((ref) => 0);

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
  late PreferenceMirrorService _preferenceMirror;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;
  bool _refreshingClock = false;
  bool _autoFinishing = false;
  DateTime Function() _now = DateTime.now;

  @override
  Future<AppSnapshot> build() async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _repository = ref.watch(repositoryProvider);
    _reminders = ref.watch(reminderServiceProvider);
    _now = ref.watch(appNowProvider);
    _preferenceMirror = ref.watch(preferenceMirrorProvider);
    await _repository.initialize();
    await _preferenceMirror.initialize();
    ref.listen<DateTime>(clockProvider, _onTick);
    await _reconcilePlanning();
    final snapshot = await _repository.loadDay(_now());
    await _restoreReminders(snapshot);
    return _repository.loadDay(_now());
  }

  Future<void> _restoreReminders(AppSnapshot snapshot) async {
    try {
      await _reminders.initialize();
      if (snapshot.preferences['reminders'] == 'true') {
        await _reminders.scheduleTemplates(snapshot.templates,
          strictness: snapshot.user.text('strictnessLevel', 'Seimbang'), todayTasks: snapshot.tasks,
          includeToday: snapshot.score.text('dayMode') != 'Minimum');
      } else {
        await _reminders.cancelSchedule();
      }
      if (snapshot.activeFocus != null) {
        final message = await _reminders.scheduleFocus(
          snapshot.activeFocus!, requestPermission: false,
        );
        await _repository.savePreference('reminderStatus', message);
      }
      if (snapshot.planningSession != null &&
          snapshot.planningSession!.text('status') == 'Berjalan') {
        await _reminders.schedulePlanning(snapshot.planningSession!);
      }
      if (snapshot.valorantSession != null && snapshot.valorantSession!['confirmedAt'] == null) {
        await _reminders.scheduleValorant(snapshot.valorantSession!, requestPermission: false);
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
    final planning = snapshot.planningSession;
    final planningDeadline = DateTime.tryParse(planning?.text('deadlineAt') ?? '');
    final planningDue = planning?.text('status') == 'Berjalan' &&
        planningDeadline != null && !now.isBefore(planningDeadline);
    if (!_refreshingClock && (changedDay || changedMinute || planningDue)) {
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
    await _reconcilePlanning();
    final snapshot = await _repository.loadDay(_now());
    if (!_disposed) state = AsyncData(snapshot);
  }

  Future<void> _reconcilePlanning() async {
    final started = await _repository.completePlanningAndStartTop1();
    if (!started) return;
    await _writePreference('selectedTab', '1');
    final snapshot = await _repository.loadDay(_now());
    try {
      await _reminders.cancelPlanning();
      if (snapshot.activeFocus != null) {
        await _reminders.scheduleFocus(snapshot.activeFocus!, requestPermission: false);
      }
    } catch (error) {
      await _repository.savePreference('reminderStatus', 'Top 1 sudah dimulai. Alarm: $error');
    }
    if (!_disposed) ref.read(planningHandoffProvider.notifier).state++;
  }

  /// Serialize writes while retaining the current screen during disk operations.
  Future<T> _mutateValue<T>(Future<T> Function() mutation) {
    final operation = _pending.then<T>((_) async {
      try {
        return await mutation();
      } finally {
        await _reload();
      }
    });
    _pending = operation.then<void>((value) {}, onError: (Object error, StackTrace stack) {
      debugPrint('Operasi MULA gagal: $error');
    });
    return operation;
  }

  Future<void> _mutate(Future<void> Function() mutation) => _mutateValue(mutation);

  Future<void> refresh() => _mutate(() async {
    final snapshot = await _repository.loadDay(_now());
    if (state.valueOrNull?.date != snapshot.date &&
        snapshot.preferences['reminders'] == 'true') {
      await _restoreReminders(snapshot);
    }
  });

  Future<void> onResume() => _mutate(() async {
    final planningWasRunning = state.valueOrNull?.planningSession?.text('status') == 'Berjalan';
    await _reconcilePlanning();
    final snapshot = await _repository.loadDay(_now());
    if (planningWasRunning && snapshot.planningSession?.text('status') == 'Dieksekusi') {
      await _writePreference('selectedTab', '1');
      if (!_disposed) ref.read(planningHandoffProvider.notifier).state++;
    }
    await _restoreReminders(snapshot);
  });

  Future<void> saveUser({
    required String name,
    required String wakeTime,
    required String sleepTime,
    required String strictnessLevel,
    required bool onboardingCompleted,
  }) => _mutate(() async {
    await _repository.saveUser(
    name: name, wakeTime: wakeTime, sleepTime: sleepTime,
    strictnessLevel: strictnessLevel, onboardingCompleted: onboardingCompleted,
    );
    await _restoreReminders(await _repository.loadDay(_now()));
  });

  Future<void> _authenticateBackup() async {
    if (state.valueOrNull?.preferences['privacyLock'] == 'true' &&
        !await ref.read(privacyServiceProvider).authenticate()) {
      throw StateError('Verifikasi perangkat diperlukan untuk mengakses cadangan pribadi.');
    }
  }

  Future<bool> exportBackup() => _mutateValue(() async {
    await _authenticateBackup();
    return ref.read(backupServiceProvider).exportBackup();
  });

  Future<BackupPreview?> inspectBackup() => _mutateValue(() async {
    await _authenticateBackup();
    return ref.read(backupServiceProvider).inspectBackup();
  });

  Future<void> restoreBackup(BackupPreview preview) => _mutate(() async {
    await _authenticateBackup();
    await ref.read(backupServiceProvider).restoreBackup(preview);
    ref.read(thoughtsUnlockedProvider.notifier).state = false;
    ref.invalidate(anxietySessionProvider);
    ref.invalidate(alarmDiagnosticsProvider);
    try {
      await _reminders.cancelFocus();
      await _reminders.cancelPlanning();
      await _reminders.cancelValorant();
      await _reminders.cancelSchedule();
      await ref.read(alarmDiagnosticsPlatformProvider).cancelTest();
    } catch (error) {
      await _repository.savePreference('reminderStatus', 'Data dipulihkan. Periksa alarm perangkat: $error');
    }
    await _restoreReminders(await _repository.loadDay(_now()));
  });

  Future<void> saveSchedule({int? id, required String title, required String startTime,
    required String endTime, required String category, required List<int> days,
    required bool active, required List<String> checklist}) => _mutate(() async {
      await ScheduleRepository(ref.read(databaseProvider), now: _now).save(
        id: id, title: title, startTime: startTime, endTime: endTime,
        category: category, days: days, active: active, checklist: checklist,
      );
      await _restoreReminders(await _repository.loadDay(_now()));
    });

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
    estimatedMinutes: estimatedMinutes, date: _dayKey(_now()),
  ));

  Future<void> saveTask({
    int? taskId,
    required String title,
    required String description,
    required String category,
    String? deadline,
    required int estimatedMinutes,
    required String energyLevel,
    required String priority,
    required List<DbRow> subtasks,
    required int pointWeight,
  }) => _mutate(() async {
    if (await _repository.completePlanningAndStartTop1()) {
      await _writePreference('selectedTab', '1');
      final snapshot = await _repository.loadDay(_now());
      await _restoreReminders(snapshot);
      if (!_disposed) ref.read(planningHandoffProvider.notifier).state++;
      throw StateError('Batas perencanaan habis. Jalankan Top 1 selama 25 menit dahulu.');
    }
    await _repository.saveTask(
      taskId: taskId, date: _dayKey(_now()), title: title,
      description: description, category: category, deadline: deadline,
      estimatedMinutes: estimatedMinutes, energyLevel: energyLevel,
      priority: priority, subtasks: subtasks, pointWeight: pointWeight,
    );
  });

  Future<void> assignPriority(int taskId, String priority) =>
      _mutate(() => _repository.assignPriority(taskId, priority));

  Future<DbRow> completeTaskWithUndo(int taskId) => _mutateValue(() async {
    final previous = await _repository.captureTaskState(taskId);
    await _repository.setTaskStatus(taskId, 'Selesai');
    return <String, Object?>{
      ...previous, '_undoUntil': _now().add(const Duration(seconds: 5)).toUtc().toIso8601String(),
    };
  });

  Future<void> restoreTask(DbRow previous) => _mutate(() async {
    final until = DateTime.tryParse(previous.text('_undoUntil'));
    if (until == null || !_now().isBefore(until)) {
      throw StateError('Waktu Undo sudah habis. Gunakan menu status untuk membuka kembali tugas.');
    }
    await _repository.restoreTaskState(previous);
  });

  Future<void> startPlanning() => _mutate(() async {
    await _repository.startPlanning();
    final snapshot = await _repository.loadDay(_now());
    try {
      await _reminders.schedulePlanning(snapshot.planningSession!, requestPermission: true);
    } catch (error) {
      await _writePreference('reminderStatus', 'Perencanaan 20 menit aktif. Alarm belum tersedia: $error');
    }
  });

  Future<void> startFiveMinutes() => _mutate(() async {
    await _writePreference('sanctuary', 'true');
    await _writePreference('sanctuaryDate', _dayKey(_now()));
    final snapshot = await _repository.loadDay(_now());
    if (snapshot.activeFocus == null) {
      final candidates = snapshot.score.text('dayMode') == 'Minimum'
          ? snapshot.minimumTasks.where((task) => task.text('minimumKey') == 'main')
          : snapshot.tasks.where((task) => task.text('priority') == 'Top 1');
      final task = candidates.where((task) => task.text('status') != 'Selesai').firstOrNull;
      await _repository.startFocus(taskId: task?.number('id'), plannedSeconds: 300, mode: 'Langkah kecil');
      final active = (await _repository.loadDay(_now())).activeFocus;
      try {
        if (active != null) await _reminders.scheduleFocus(active);
      } catch (error) {
        await _writePreference('reminderStatus', 'Langkah 5 menit aktif. Alarm: $error');
      }
    }
    await _writePreference('selectedTab', '1');
  });

  Future<void> startValorant() => _mutate(() async {
    final snapshot = await _repository.loadDay(_now());
    if (snapshot.valorantGate['allowed'] != true) {
      throw StateError(snapshot.valorantGate.text('reason', 'VALORANT belum tersedia.'));
    }
    await _reminders.requireGameAlarmAccess();
    final session = await _repository.startValorant();
    try {
      await _reminders.scheduleValorant(session);
    } catch (error) {
      await _repository.rollbackValorantStart(session.number('id'));
      await _reminders.cancelValorant();
      rethrow;
    }
  });

  Future<void> confirmValorantClosed() => _mutate(() async {
    await _repository.confirmValorantClosed();
    await _reminders.cancelValorant();
    await _writePreference('selectedTab', '0');
  });

  Future<void> overrideProject({required int taskId, required String project}) =>
      _mutate(() => _repository.overrideProject(taskId: taskId, project: project));

  Future<void> _writePreference(String key, String value) async {
    await _repository.savePreference(key, value);
    await _preferenceMirror.writeString(key, value);
  }

  Future<void> savePreference(String key, String value) =>
      _mutate(() => _writePreference(key, value));

  Future<void> setSelectedTab(int index) {
    if (index < 0 || index > 4) throw ArgumentError.value(index, 'index');
    return savePreference('selectedTab', '$index');
  }

  Future<void> setDayMode(String mode, {String? reason}) => _mutate(() async {
    await _repository.saveDayMode(_dayKey(_now()), mode, reason: reason);
    await _writePreference('sanctuary', mode == 'Normal' ? 'false' : 'true');
    await _writePreference('sanctuaryDate', _dayKey(_now()));
    if (mode == 'Minimum') {
      await _reminders.cancelPlanning();
    }
    await _restoreReminders(await _repository.loadDay(_now()));
  });

  Future<void> enterSanctuary(String reason) => _mutate(() async {
    if (reason == 'Mode Hari Buruk') {
      await _repository.saveDayMode(_dayKey(_now()), 'Minimum', reason: reason);
      await _reminders.cancelPlanning();
      await _restoreReminders(await _repository.loadDay(_now()));
    }
    await _repository.recordAnxiety(
      mode: reason, durationSeconds: 0,
      anxietyBefore: state.valueOrNull?.score.number('anxietyScore', 5) ?? 5,
      anxietyAfter: state.valueOrNull?.score.number('anxietyScore', 5) ?? 5,
    );
    await _writePreference('sanctuary', 'true');
    await _writePreference('sanctuaryDate', _dayKey(_now()));
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
    date: _dayKey(_now()), moodScore: moodScore,
    anxietyScore: anxietyScore, notes: notes, gratitudeNote: gratitudeNote,
    firstStepTomorrow: firstStepTomorrow,
  ));

  Future<void> startFocus({
    int? taskId, required int plannedSeconds, required String mode,
    bool allowPriorityOverride = false,
  }) => _mutate(() async {
    await _repository.startFocus(
      taskId: taskId, plannedSeconds: plannedSeconds, mode: mode,
      allowPriorityOverride: allowPriorityOverride,
    );
    final snapshot = await _repository.loadDay(_now());
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
    final snapshot = await _repository.loadDay(_now());
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
    final snapshot = await _repository.loadDay(_now());
    await _reminders.scheduleTemplates(snapshot.templates,
      strictness: snapshot.user.text('strictnessLevel', 'Seimbang'), todayTasks: snapshot.tasks,
      includeToday: snapshot.score.text('dayMode') != 'Minimum');
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
      await savePreference('lastUnlockAt', _now().toIso8601String());
      ref.read(thoughtsUnlockedProvider.notifier).state = true;
    }
    return authenticated;
  }
}
