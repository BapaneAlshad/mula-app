import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/app_snapshot.dart';
import 'daily_score_calculator.dart';
import 'local/app_database.dart';
import 'local/default_schedule_seeder.dart';

class MulaRepository {
  MulaRepository(this._database, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AppDatabase _database;
  final DateTime Function() _now;
  static const _userId = 1;
  static const adaptationReasons = <String>{
    'Sakit', 'Kondisi keluarga', 'Tugas darurat', 'Kelelahan berat',
    'Perjalanan', 'Acara/kewajiban penting',
  };
  static const _minimumDefinitions = <DbRow>[
    {'key': 'prayer', 'title': 'Sholat', 'category': 'Rutinitas', 'minutes': 10},
    {'key': 'water', 'title': 'Minum air', 'category': 'Rutinitas', 'minutes': 1},
    {'key': 'movement', 'title': 'Olahraga 5–10 menit atau stretching', 'category': 'Pribadi', 'minutes': 5},
    {'key': 'main', 'title': 'Menyelesaikan satu tugas utama selama 25 menit', 'category': 'Penting', 'minutes': 25},
    {'key': 'family', 'title': 'Meluangkan waktu berkualitas untuk keluarga', 'category': 'Pribadi', 'minutes': 10},
    {'key': 'closing', 'title': 'Menulis satu catatan penutupan hari', 'category': 'Side Job', 'minutes': 5},
    {'key': 'sleep', 'title': 'Tidur lebih awal', 'category': 'Side Job', 'minutes': 10},
  ];

  Future<void> initialize() async {
    await DefaultScheduleSeeder.seed(await _database.database);
  }

  static String dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  Future<AppSnapshot> loadDay(DateTime day) async {
    final database = await _database.database;
    final date = dateKey(day);
    return database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      await _settleOverdueValorant(transaction);
      await _updateScore(transaction, date);
      final users = await transaction.query('users', where: 'id = ?', whereArgs: [_userId]);
      final templates = await transaction.query('schedule_templates',
          where: 'userId = ?', whereArgs: [_userId], orderBy: 'sortOrder');
      final tasks = await _tasks(transaction, date);
      final minimumTasks = await _minimumTasks(transaction, date);
      final thoughts = await transaction.query('thought_parkings',
          where: 'userId = ?', whereArgs: [_userId], orderBy: 'createdAt DESC, id DESC');
      final active = await transaction.query('focus_sessions',
          where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId], limit: 1);
      final scores = await transaction.query('daily_scores',
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      final history = await transaction.query('daily_scores',
          where: 'userId = ? AND date <= ?', whereArgs: [_userId, date],
          orderBy: 'date DESC', limit: 30);
      final preferences = await transaction.query('app_preferences');
      final planning = await transaction.query('planning_sessions',
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      final valorant = await transaction.query('valorant_sessions',
          where: "userId = ? AND (status = 'Berjalan' OR date = ?)",
          whereArgs: [_userId, date],
          orderBy: "CASE WHEN status = 'Berjalan' THEN 0 ELSE 1 END, date DESC", limit: 1);
      return AppSnapshot(
        user: users.single,
        templates: templates,
        tasks: tasks,
        thoughts: thoughts,
        activeFocus: active.isEmpty ? null : active.single,
        score: scores.single,
        history: history,
        preferences: {for (final row in preferences) row.text('key'): row.text('value')},
        date: date,
        minimumTasks: minimumTasks,
        planningSession: planning.isEmpty ? null : planning.single,
        valorantSession: valorant.isEmpty ? null : valorant.single,
        valorantGate: await _valorantGate(transaction, date),
        streak: await _streak(transaction, date),
      );
    });
  }

  Future<void> saveUser({
    required String name,
    required String wakeTime,
    required String sleepTime,
    required String strictnessLevel,
    required bool onboardingCompleted,
  }) async {
    _nonEmpty(name, 'Nama');
    _validTime(wakeTime);
    _validTime(sleepTime);
    if (wakeTime == sleepTime) {
      throw ArgumentError('Jam bangun dan jam tidur harus berbeda.');
    }
    _oneOf(strictnessLevel, {'Lembut', 'Seimbang', 'Tegas'}, 'Tingkat ketegasan');
    final database = await _database.database;
    await database.update('users', {
      'name': name.trim(), 'wakeTime': wakeTime, 'sleepTime': sleepTime,
      'strictnessLevel': strictnessLevel,
      'onboardingCompleted': onboardingCompleted ? 1 : 0,
    }, where: 'id = ?', whereArgs: [_userId]);
  }

  Future<void> setTaskStatus(int id, String status, {String? reason}) async {
    _oneOf(status,
        {'Belum mulai', 'Sedang berjalan', 'Selesai', 'Dilewati', 'Ditunda'}, 'Status');
    if ({'Dilewati', 'Ditunda'}.contains(status)) {
      _nonEmpty(reason ?? '', 'Alasan');
    }
    await _mutateTask(id, (transaction, task) async {
      final values = <String, Object?>{
        'status': status,
        'completedAt': status == 'Selesai' ? _now().toIso8601String() : null,
        'skippedReason': {'Dilewati', 'Ditunda'}.contains(status) ? reason?.trim() : null,
        if ({'Sedang berjalan', 'Selesai'}.contains(status) && task.text('startedAt').isEmpty)
          'startedAt': _now().toUtc().toIso8601String(),
      };
      final checklist = DailyScoreCalculator.decodeChecklist(task.text('subtasksJson'));
      final resetChecklist = status == 'Belum mulai' ||
          (status == 'Sedang berjalan' &&
              checklist.isNotEmpty && checklist.every((item) => item['done'] == true));
      if (status == 'Selesai' || resetChecklist) {
        values['subtasksJson'] = jsonEncode([
          for (final item in checklist) {...item, 'done': status == 'Selesai'},
        ]);
      }
      await transaction.update('daily_tasks', values, where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> setChecklistItem(int taskId, int index, bool done) async {
    await _mutateTask(taskId, (transaction, task) async {
      final checklist = DailyScoreCalculator.decodeChecklist(task.text('subtasksJson'));
      if (index < 0 || index >= checklist.length) {
        throw RangeError.index(index, checklist, 'index');
      }
      checklist[index]['done'] = done;
      final allDone = checklist.every((item) => item['done'] == true);
      final anyDone = checklist.any((item) => item['done'] == true);
      await transaction.update('daily_tasks', {
        'subtasksJson': jsonEncode(checklist),
        'status': allDone ? 'Selesai' : anyDone ? 'Sedang berjalan' : 'Belum mulai',
        'completedAt': allDone ? _now().toIso8601String() : null,
        'skippedReason': null,
        if (anyDone && task.text('startedAt').isEmpty)
          'startedAt': _now().toUtc().toIso8601String(),
      }, where: 'id = ?', whereArgs: [taskId]);
    });
  }

  Future<void> addTask({
    required String title,
    required String category,
    required String priority,
    required int estimatedMinutes,
    required String date,
  }) async {
    await saveTask(date: date, title: title, description: '', category: category,
        estimatedMinutes: estimatedMinutes, energyLevel: 'Sedang', priority: priority,
        subtasks: const [], pointWeight: estimatedMinutes.clamp(1, 100).toInt());
  }

  Future<void> saveTask({
    int? taskId,
    required String date,
    required String title,
    required String description,
    required String category,
    String? deadline,
    required int estimatedMinutes,
    required String energyLevel,
    required String priority,
    required List<DbRow> subtasks,
    required int pointWeight,
  }) async {
    _nonEmpty(title, 'Judul tugas');
    _oneOf(category, {'Wajib', 'Penting', 'Jika Sempat', 'Rutinitas', 'Tim', 'Pribadi', 'Side Job'}, 'Kategori');
    _oneOf(priority, {'Top 1', 'Top 2', 'Top 3', 'Reguler'}, 'Prioritas');
    if (estimatedMinutes < 1 || estimatedMinutes > 1440) {
      throw ArgumentError('Estimasi harus antara 1 dan 1440 menit.');
    }
    _validDate(date);
    _oneOf(energyLevel, {'Rendah', 'Sedang', 'Tinggi'}, 'Tingkat energi');
    if (pointWeight < 1 || pointWeight > 100) {
      throw ArgumentError('Nilai poin harus antara 1 dan 100.');
    }
    if (deadline != null) _validDate(deadline);
    final checklist = <DbRow>[];
    for (final item in subtasks) {
      _nonEmpty(item.text('title'), 'Subtask');
      checklist.add({'title': item.text('title').trim(), 'done': item.flag('done')});
    }
    final database = await _database.database;
    await database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      if (taskId != null) {
        final previous = await _task(transaction, taskId);
        if (previous.text('date') != date || previous['minimumKey'] != null) {
          throw ArgumentError('Tanggal atau jenis tugas tidak dapat diubah.');
        }
      }
      if (priority != 'Reguler') {
        await transaction.update('daily_tasks', {'priority': 'Reguler'},
            where: 'userId = ? AND date = ? AND priority = ? AND minimumKey IS NULL',
            whereArgs: [_userId, date, priority]);
      }
      final values = <String, Object?>{
        'userId': _userId, 'date': date, 'title': title.trim(),
        'category': category, 'priority': priority, 'estimatedMinutes': estimatedMinutes,
        'description': description.trim(), 'deadline': deadline,
        'energyLevel': energyLevel, 'pointWeight': pointWeight,
        'subtasksJson': jsonEncode(checklist),
      };
      final allDone = checklist.isNotEmpty && checklist.every((item) => item.flag('done'));
      final anyDone = checklist.any((item) => item.flag('done'));
      if (taskId == null) {
        if (anyDone) {
          values['status'] = allDone ? 'Selesai' : 'Sedang berjalan';
          values['startedAt'] = _now().toUtc().toIso8601String();
          if (allDone) values['completedAt'] = _now().toUtc().toIso8601String();
        }
        await transaction.insert('daily_tasks', values);
      } else {
        final previous = await _task(transaction, taskId);
        values['revision'] = previous.number('revision') + 1;
        if (anyDone && previous.text('startedAt').isEmpty) {
          values['startedAt'] = _now().toUtc().toIso8601String();
        }
        if (checklist.isNotEmpty) {
          values['status'] = allDone ? 'Selesai' : anyDone ? 'Sedang berjalan' :
              previous.text('status') == 'Selesai' ? 'Belum mulai' : previous.text('status');
          values['completedAt'] = allDone ? previous['completedAt'] ??
              _now().toUtc().toIso8601String() : null;
        }
        await transaction.update('daily_tasks', values, where: 'id = ? AND userId = ?',
            whereArgs: [taskId, _userId]);
      }
      await _updateScore(transaction, date);
    });
  }

  Future<void> assignPriority(int taskId, String priority) async {
    _oneOf(priority, {'Top 1', 'Top 2', 'Top 3', 'Reguler'}, 'Prioritas');
    await _mutateTask(taskId, (transaction, task) async {
      if (task['minimumKey'] != null) throw ArgumentError('Checklist minimum tidak memiliki slot Top 3.');
      if (priority != 'Reguler') {
        await transaction.update('daily_tasks', {'priority': 'Reguler'},
            where: 'userId = ? AND date = ? AND priority = ? AND minimumKey IS NULL',
            whereArgs: [_userId, task.text('date'), priority]);
      }
      await transaction.update('daily_tasks', {'priority': priority},
          where: 'id = ?', whereArgs: [taskId]);
    });
  }

  Future<DbRow> captureTaskState(int id) async {
    final database = await _database.database;
    return Map<String, Object?>.from(await _task(database, id));
  }

  Future<void> restoreTaskState(DbRow previous) async {
    await _mutateTask(previous.number('id'), (transaction, current) async {
      // Undo only applies to the swipe completion; preserve a later user edit.
      if (current.text('status') != 'Selesai' ||
          current.number('revision') != previous.number('revision') + 1) {
        return;
      }
      final completed = DateTime.tryParse(current.text('completedAt'));
      if (completed == null) return;
      final elapsed = _now().difference(completed);
      if (elapsed.isNegative || elapsed.inMilliseconds > 5000) return;
      await transaction.update('daily_tasks', {
        for (final key in ['status', 'completedAt', 'skippedReason', 'subtasksJson', 'startedAt'])
          key: previous[key],
      }, where: 'id = ?', whereArgs: [previous.number('id')]);
    });
  }

  Future<void> overrideProject({required int taskId, required String project}) async {
    _nonEmpty(project, 'Proyek');
    await _mutateTask(taskId, (transaction, task) async {
      if (!{'13:00', '20:00', '20:45'}.contains(task.text('startTime'))) {
        throw ArgumentError('Override hanya tersedia untuk blok proyek harian.');
      }
      final baseTitle = task.text('templateTitle');
      final description = task.text('description').split('\n')
          .where((line) => !line.startsWith('Proyek:') && !line.startsWith('Override deadline aktif:'))
          .join('\n');
      await transaction.update('daily_tasks', {
        'title': '$baseTitle · ${project.trim()}',
        'description': '$description\nOverride deadline aktif: ${project.trim()}',
        'outputNote': 'Deadline aktif: ${project.trim()}',
      }, where: 'id = ?', whereArgs: [taskId]);
    });
  }

  Future<void> saveDayMode(String date, String mode, {String? reason}) async {
    _validDate(date);
    _oneOf(mode, {'Normal', 'Minimum', 'Adaptasi', 'Reset24Jam'}, 'Mode hari');
    if (mode == 'Adaptasi') _oneOf(reason ?? '', adaptationReasons, 'Alasan adaptasi');
    final database = await _database.database;
    await database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      await transaction.update('daily_scores', {
        'dayMode': mode, 'adaptationReason': reason?.trim() ?? '',
        'consequencesDisabled': mode == 'Adaptasi' ? 1 : 0,
        'streakProtected': mode == 'Adaptasi' ? 1 : 0,
        if (mode == 'Adaptasi') 'valorantPenaltyNextDay': 0,
      }, where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      if (mode == 'Minimum') {
        await transaction.update('planning_sessions', {'status': 'Dibatalkan'},
            where: "userId = ? AND date = ? AND status IN ('Berjalan','Siap Top 1')",
            whereArgs: [_userId, date]);
      }
      await _updateScore(transaction, date);
    });
  }

  Future<void> addThought({
    required String content,
    required String type,
    required int intensity,
    required bool needsAction,
    required String nextAction,
  }) async {
    _nonEmpty(content, 'Pikiran');
    _oneOf(type, {'Kekhawatiran', 'Ide', 'Masalah', 'Tugas', 'Emosi'}, 'Jenis pikiran');
    _rating(intensity);
    final database = await _database.database;
    await database.insert('thought_parkings', {
      'userId': _userId, 'content': content.trim(), 'type': type,
      'intensity': intensity, 'needsAction': needsAction ? 1 : 0,
      'nextAction': nextAction.trim(), 'createdAt': _now().toIso8601String(),
      'reviewAt': _now().add(const Duration(hours: 3)).toIso8601String(),
    });
  }

  Future<void> setThoughtStatus(int id, String status) async {
    _oneOf(status, {'Terparkir', 'Ditinjau', 'Selesai'}, 'Status pikiran');
    final database = await _database.database;
    final changed = await database.update('thought_parkings', {'status': status},
        where: 'id = ? AND userId = ?', whereArgs: [id, _userId]);
    if (changed == 0) throw StateError('Pikiran tidak ditemukan.');
  }

  Future<void> saveReflection({
    required String date,
    required int moodScore,
    required int anxietyScore,
    required String notes,
    required String gratitudeNote,
    required String firstStepTomorrow,
  }) async {
    _validDate(date);
    _rating(moodScore);
    _rating(anxietyScore);
    final database = await _database.database;
    await database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      await transaction.update('daily_scores', {
        'moodScore': moodScore, 'anxietyScore': anxietyScore,
        'notes': notes.trim(), 'mainObstacle': notes.trim(),
        'gratitudeNote': gratitudeNote.trim(),
        'firstStepTomorrow': firstStepTomorrow.trim(),
      }, where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      await _updateScore(transaction, date);
    });
  }

  Future<void> startFocus({
    int? taskId,
    required int plannedSeconds,
    required String mode,
    bool allowPriorityOverride = false,
  }) async {
    _nonEmpty(mode, 'Mode fokus');
    if (plannedSeconds < 1 || plannedSeconds > 86400) {
      throw ArgumentError('Durasi fokus harus antara 1 detik dan 24 jam.');
    }
    final database = await _database.database;
    await database.transaction((transaction) async {
      final active = await transaction.query('focus_sessions',
          where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId], limit: 1);
      if (active.isNotEmpty) throw StateError('Selesaikan sesi fokus yang sedang berjalan.');
      if (taskId != null) {
        final task = await _task(transaction, taskId);
        if (task.text('date') != dateKey(_now())) {
          throw StateError('Sesi fokus hanya dapat dimulai pada tugas hari ini.');
        }
        if (!allowPriorityOverride && {'Top 2', 'Top 3'}.contains(task.text('priority')) &&
            !await _hasTop1Started(transaction, task.text('date'))) {
          throw StateError('Mulai Top 1 terlebih dahulu sebelum Top 2 atau Top 3.');
        }
        if (task.text('status') != 'Selesai') {
          await transaction.update('daily_tasks', {
            'status': 'Sedang berjalan',
            'revision': task.number('revision') + 1,
            if (task.text('startedAt').isEmpty) 'startedAt': _now().toUtc().toIso8601String(),
          },
              where: 'id = ?', whereArgs: [taskId]);
        }
      }
      final now = _now();
      final date = dateKey(now);
      await _ensureDay(transaction, date);
      await transaction.insert('focus_sessions', {
        'userId': _userId, 'taskId': taskId, 'mode': mode.trim(),
        'plannedSeconds': plannedSeconds, 'startedAt': now.toUtc().toIso8601String(),
      });
      await _updateScore(transaction, date);
    });
  }

  Future<bool> _hasTop1Started(DatabaseExecutor database, String date) async {
    final top = await database.query('daily_tasks',
        where: "userId = ? AND date = ? AND priority = 'Top 1' AND minimumKey IS NULL",
        whereArgs: [_userId, date], limit: 1);
    if (top.isEmpty) return true;
    final task = top.single;
    if (task.text('startedAt').isNotEmpty ||
        {'Sedang berjalan', 'Selesai'}.contains(task.text('status'))) {
      return true;
    }
    final sessions = await database.query('focus_sessions', columns: ['id'],
        where: 'userId = ? AND taskId = ?', whereArgs: [_userId, task.number('id')], limit: 1);
    return sessions.isNotEmpty;
  }

  Future<void> startPlanning() async {
    final database = await _database.database;
    await database.transaction((transaction) async {
      final now = _now();
      final date = dateKey(now);
      await _ensureDay(transaction, date);
      final scores = await transaction.query('daily_scores',
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      if (scores.single.text('dayMode') == 'Minimum') {
        throw StateError('Mode Hari Buruk menggunakan tujuh checklist minimum, tanpa perencanaan pagi.');
      }
      final existing = await transaction.query('planning_sessions',
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      if (existing.isNotEmpty) return;
      final minute = now.hour * 60 + now.minute;
      if (minute < 480 || minute >= 570) {
        throw StateError('Perencanaan pagi dimulai pada blok 08.00–09.30.');
      }
      await transaction.insert('planning_sessions', {
        'userId': _userId, 'date': date,
        'startedAt': now.toUtc().toIso8601String(),
        'deadlineAt': now.add(const Duration(minutes: 20)).toUtc().toIso8601String(),
      });
    });
  }

  Future<DbRow?> resolvePlanningExpiry() async {
    final database = await _database.database;
    return database.transaction((transaction) => _resolvePlanningExpiry(transaction));
  }

  Future<DbRow?> _resolvePlanningExpiry(DatabaseExecutor database) async {
    final date = dateKey(_now());
    await database.update('planning_sessions', {'status': 'Dibatalkan'},
        where: "userId = ? AND date != ? AND status IN ('Berjalan','Siap Top 1')",
        whereArgs: [_userId, date]);
    await _ensureDay(database, date);
    final scores = await database.query('daily_scores',
        where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
    if (scores.single.text('dayMode') == 'Minimum') {
      await database.update('planning_sessions', {'status': 'Dibatalkan'},
          where: "userId = ? AND date = ? AND status IN ('Berjalan','Siap Top 1')",
          whereArgs: [_userId, date]);
      return null;
    }
    final rows = await database.query('planning_sessions',
        where: "userId = ? AND date = ? AND status IN ('Berjalan','Siap Top 1')",
        whereArgs: [_userId, date], limit: 1);
    if (rows.isEmpty) return null;
    final planning = rows.single;
    if (_now().isBefore(DateTime.parse(planning.text('deadlineAt')))) return null;
    final tops = await database.query('daily_tasks',
        where: "userId = ? AND date = ? AND priority = 'Top 1' AND minimumKey IS NULL",
        whereArgs: [_userId, date], limit: 1);
    DbRow target;
    if (tops.isNotEmpty && tops.single.text('status') != 'Selesai') {
      target = tops.single;
    } else {
      await database.update('daily_tasks', {'priority': 'Reguler'},
          where: "userId = ? AND date = ? AND priority = 'Top 1' AND minimumKey IS NULL",
          whereArgs: [_userId, date]);
      final id = await database.insert('daily_tasks', {
        'userId': _userId, 'date': date,
        'title': 'Menyelesaikan satu langkah utama dan mencatat hasilnya',
        'description': 'Kerjakan satu output konkret selama 25 menit, lalu tulis hasil yang selesai.',
        'category': 'Penting', 'priority': 'Top 1', 'estimatedMinutes': 25,
        'energyLevel': 'Sedang',
      });
      target = await _task(database, id);
    }
    await database.update('planning_sessions', {
      'status': 'Siap Top 1', 'targetTaskId': target.number('id'),
    }, where: 'id = ?', whereArgs: [planning.number('id')]);
    return target;
  }

  Future<bool> completePlanningAndStartTop1() async {
    final database = await _database.database;
    return database.transaction((transaction) async {
      final target = await _resolvePlanningExpiry(transaction);
      if (target == null) return false;
      final now = _now();
      final active = await transaction.query('focus_sessions',
          where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId], limit: 1);
      final activeStart = active.isEmpty ? null : DateTime.parse(active.single.text('startedAt'));
      final activeEnd = activeStart?.add(Duration(seconds: active.single.number('plannedSeconds')));
      final canReuse = active.isNotEmpty && active.single.number('taskId', -1) == target.number('id') &&
          active.single.number('plannedSeconds') >= 1500 && now.isBefore(activeEnd!);
      if (active.isNotEmpty && !canReuse) {
        final session = active.single;
        final elapsed = now.difference(activeStart!).inSeconds
            .clamp(0, session.number('plannedSeconds')).toInt();
        final expired = !now.isBefore(activeEnd!);
        await transaction.update('focus_sessions', {
          'status': expired ? 'Selesai' : 'Dibatalkan', 'actualSeconds': elapsed,
          'cancelReason': expired ? null : 'Perencanaan selesai; kembali ke Top 1.',
          'completedAt': (expired ? activeEnd : now).toUtc().toIso8601String(),
        }, where: 'id = ?', whereArgs: [session.number('id')]);
      }
      if (!canReuse) {
        await transaction.insert('focus_sessions', {
          'userId': _userId, 'taskId': target.number('id'), 'mode': 'Top 1 · 25 menit',
          'plannedSeconds': 1500, 'startedAt': now.toUtc().toIso8601String(),
        });
      }
      await transaction.update('daily_tasks', {
        'status': 'Sedang berjalan',
        'revision': target.number('revision') + 1,
        if (target.text('startedAt').isEmpty) 'startedAt': now.toUtc().toIso8601String(),
      }, where: 'id = ?', whereArgs: [target.number('id')]);
      await transaction.update('planning_sessions', {'status': 'Dieksekusi'},
          where: "userId = ? AND status = 'Siap Top 1' AND targetTaskId = ?",
          whereArgs: [_userId, target.number('id')]);
      await _updateScore(transaction, target.text('date'));
      return true;
    });
  }

  /// Repeated UI/alarm completion calls are harmless: only one active row can
  /// exist, and the transaction observes the result of earlier completion calls.
  Future<bool> finishFocus({
    bool cancel = false,
    String? reason,
    int? expectedSessionId,
  }) async {
    final database = await _database.database;
    return database.transaction((transaction) async {
      final active = await transaction.query('focus_sessions',
          where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId], limit: 1);
      if (active.isEmpty) return false;
      final session = active.single;
      if (expectedSessionId != null && session.number('id') != expectedSessionId) return false;
      final now = _now();
      final started = DateTime.parse(session.text('startedAt'));
      final elapsed = now.difference(started).inSeconds
          .clamp(0, session.number('plannedSeconds')).toInt();
      await transaction.update('focus_sessions', {
        'actualSeconds': elapsed,
        'status': cancel ? 'Dibatalkan' : 'Selesai',
        'cancelReason': cancel ? reason?.trim() : null,
        'completedAt': now.toUtc().toIso8601String(),
      }, where: "id = ? AND status = 'Berjalan'", whereArgs: [session.number('id')]);
      final dates = {dateKey(started.toLocal()), dateKey(now)};
      if (session['taskId'] != null) {
        final task = await _task(transaction, session.number('taskId'));
        dates.add(task.text('date'));
      }
      for (final date in dates) {
        await _ensureDay(transaction, date);
        await _updateScore(transaction, date);
      }
      return true;
    });
  }

  Future<DbRow> startValorant() async {
    final database = await _database.database;
    return database.transaction((transaction) async {
      final now = _now();
      final date = dateKey(now);
      await _ensureDay(transaction, date);
      await _settleOverdueValorant(transaction);
      final gate = await _valorantGate(transaction, date);
      if (!gate.flag('allowed')) throw StateError(gate.text('reason'));
      final cutoff = DateTime(now.year, now.month, now.day, 13);
      final id = await transaction.insert('valorant_sessions', {
        'userId': _userId, 'date': date,
        'startedAt': now.toUtc().toIso8601String(),
        'alarmAt': now.add(const Duration(minutes: 45)).toUtc().toIso8601String(),
        'cutoffAt': cutoff.toUtc().toIso8601String(),
      });
      await transaction.update('daily_scores', {'valorantUsed': 1},
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
      return (await transaction.query('valorant_sessions',
          where: 'id = ?', whereArgs: [id])).single;
    });
  }

  /// Only the immediate alarm-setup failure path may refund an unused launch.
  Future<void> rollbackValorantStart(int sessionId) async {
    final database = await _database.database;
    await database.transaction((transaction) async {
      final sessions = await transaction.query('valorant_sessions',
          where: "id = ? AND userId = ? AND status = 'Berjalan'",
          whereArgs: [sessionId, _userId]);
      if (sessions.isEmpty) return;
      final session = sessions.single;
      final elapsed = _now().difference(DateTime.parse(session.text('startedAt')));
      if (elapsed.isNegative || elapsed > const Duration(minutes: 1)) {
        throw StateError('Kuota pertandingan yang sudah berjalan tidak dapat dikembalikan.');
      }
      await transaction.delete('valorant_sessions', where: 'id = ?', whereArgs: [sessionId]);
      await transaction.update('daily_scores', {'valorantUsed': 0},
          where: 'userId = ? AND date = ?', whereArgs: [_userId, session.text('date')]);
    });
  }

  Future<bool> confirmValorantClosed() async {
    final database = await _database.database;
    return database.transaction((transaction) async {
      final sessions = await transaction.query('valorant_sessions',
          where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId],
          orderBy: 'startedAt', limit: 1);
      if (sessions.isEmpty) return false;
      final session = sessions.single;
      final now = _now();
      final isLate = now.isAfter(DateTime.parse(session.text('cutoffAt')));
      final scores = await transaction.query('daily_scores',
          where: 'userId = ? AND date = ?', whereArgs: [_userId, session.text('date')]);
      final penalty = isLate && !scores.single.flag('consequencesDisabled');
      await transaction.update('valorant_sessions', {
        'status': 'Ditutup', 'confirmedAt': now.toUtc().toIso8601String(),
      }, where: 'id = ?', whereArgs: [session.number('id')]);
      if (penalty) {
        await transaction.update('daily_scores', {'valorantPenaltyNextDay': 1},
            where: 'userId = ? AND date = ?', whereArgs: [_userId, session.text('date')]);
      }
      return penalty;
    });
  }

  Future<void> _settleOverdueValorant(DatabaseExecutor database) async {
    final active = await database.query('valorant_sessions',
        where: "userId = ? AND status = 'Berjalan'", whereArgs: [_userId]);
    for (final session in active) {
      if (!_now().isAfter(DateTime.parse(session.text('cutoffAt')))) continue;
      await database.update('daily_scores', {'valorantPenaltyNextDay': 1},
          where: 'userId = ? AND date = ? AND consequencesDisabled = 0',
          whereArgs: [_userId, session.text('date')]);
    }
  }

  Future<DbRow> _valorantGate(DatabaseExecutor database, String date) async {
    final today = (await database.query('daily_scores',
        where: 'userId = ? AND date = ?', whereArgs: [_userId, date])).single;
    final yesterday = dateKey(DateTime.parse(date).subtract(const Duration(days: 1)));
    final previous = await database.query('daily_scores',
        where: 'userId = ? AND date = ?', whereArgs: [_userId, yesterday]);
    final penalty = !today.flag('consequencesDisabled') && previous.isNotEmpty &&
        !previous.single.flag('consequencesDisabled') && previous.single.flag('valorantPenaltyNextDay');
    final sessions = await database.query('valorant_sessions',
        where: "userId = ? AND (date = ? OR status = 'Berjalan')", whereArgs: [_userId, date]);
    final quotaUsed = today.flag('valorantUsed') ||
        sessions.any((session) => session.text('date') == date);
    final unresolved = sessions.any((session) => session.text('status') == 'Berjalan');
    final top = await database.query('daily_tasks', columns: ['id'],
        where: "userId = ? AND date = ? AND priority = 'Top 1' AND status = 'Selesai' AND minimumKey IS NULL",
        whereArgs: [_userId, date], limit: 1);
    final focus = await database.query('focus_sessions',
        where: "userId = ? AND status = 'Selesai' AND actualSeconds >= plannedSeconds",
        whereArgs: [_userId]);
    final morningFocus = focus.any((session) {
      final started = DateTime.tryParse(session.text('startedAt'))?.toLocal();
      final completed = DateTime.tryParse(session.text('completedAt'))?.toLocal();
      if (started == null || completed == null || dateKey(started) != date ||
          dateKey(completed) != date || session.number('actualSeconds') <= 0) {
        return false;
      }
      final startMinute = started.hour * 60 + started.minute;
      final endMinute = completed.hour * 60 + completed.minute;
      return startMinute >= 270 && startMinute < 705 && endMinute <= 705;
    });
    final achieved = top.isNotEmpty || morningFocus;
    final now = _now();
    final minute = now.hour * 60 + now.minute;
    final inWindow = dateKey(now) == date && minute >= 705 && minute < 780;
    final reason = penalty ? 'Akses hari ini terkunci karena pelanggaran batas waktu kemarin.'
        : quotaUsed ? 'Kuota satu match VALORANT hari ini sudah terpakai.'
        : unresolved ? 'Konfirmasi game sebelumnya sudah ditutup terlebih dahulu.'
        : !achieved ? 'Selesaikan Top 1 atau satu sesi fokus pagi terlebih dahulu.'
        : !inWindow ? 'VALORANT tersedia hanya pada blok 11.45–13.00.'
        : 'Target pagi tercapai. Satu match dengan alarm 45 menit.';
    return {
      'allowed': !penalty && !quotaUsed && !unresolved && achieved && inWindow,
      'reason': reason, 'morningAchieved': achieved,
      'quotaUsed': quotaUsed, 'penalty': penalty,
    };
  }

  Future<void> savePreference(String key, String value) async {
    _nonEmpty(key, 'Kunci preferensi');
    final database = await _database.database;
    await database.insert('app_preferences', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recordAnxiety({
    required String mode,
    required int durationSeconds,
    required int anxietyBefore,
    required int anxietyAfter,
  }) async {
    _nonEmpty(mode, 'Mode tenang');
    _rating(anxietyBefore);
    _rating(anxietyAfter);
    if (durationSeconds < 0) throw ArgumentError('Durasi tidak boleh negatif.');
    final database = await _database.database;
    await database.transaction((transaction) async {
      final now = _now();
      final date = dateKey(now);
      await _ensureDay(transaction, date);
      await transaction.insert('anxiety_sessions', {
        'userId': _userId, 'mode': mode.trim(), 'durationSeconds': durationSeconds,
        'anxietyBefore': anxietyBefore, 'anxietyAfter': anxietyAfter,
        'completedAt': now.toIso8601String(),
      });
      await transaction.update('daily_scores', {'anxietyScore': anxietyAfter},
          where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
    });
  }

  Future<void> _mutateTask(int id,
      Future<void> Function(Transaction transaction, DbRow task) action) async {
    final database = await _database.database;
    await database.transaction((transaction) async {
      final task = await _task(transaction, id);
      await action(transaction, task);
      await transaction.rawUpdate('UPDATE daily_tasks SET revision = revision + 1 WHERE id = ?', [id]);
      await _updateScore(transaction, task.text('date'));
    });
  }

  Future<DbRow> _task(DatabaseExecutor database, int id) async {
    final rows = await database.rawQuery('''
      SELECT t.*, COALESCE(t.scheduleStartTime, s.startTime) AS startTime,
        COALESCE(t.scheduleEndTime, s.endTime) AS endTime,
        COALESCE(t.scheduleTitle, s.title) AS templateTitle
      FROM daily_tasks t LEFT JOIN schedule_templates s ON s.id = t.sourceScheduleId
      WHERE t.id = ? AND t.userId = ?''', [id, _userId]);
    if (rows.isEmpty) throw StateError('Tugas tidak ditemukan.');
    return rows.single;
  }

  Future<List<DbRow>> _tasks(DatabaseExecutor database, String date) =>
      database.rawQuery('''
        SELECT t.*, COALESCE(t.scheduleStartTime, s.startTime) AS startTime,
          COALESCE(t.scheduleEndTime, s.endTime) AS endTime,
          COALESCE(t.scheduleTitle, s.title) AS templateTitle, s.sortOrder
        FROM daily_tasks t LEFT JOIN schedule_templates s ON s.id = t.sourceScheduleId
        WHERE t.userId = ? AND t.date = ? AND t.minimumKey IS NULL
        ORDER BY CASE WHEN s.sortOrder IS NULL THEN 1 ELSE 0 END,
          COALESCE(t.scheduleStartTime, s.startTime), s.sortOrder, t.id''', [_userId, date]);

  Future<List<DbRow>> _minimumTasks(DatabaseExecutor database, String date) async {
    final rows = await database.query('daily_tasks',
        where: 'userId = ? AND date = ? AND minimumKey IS NOT NULL',
        whereArgs: [_userId, date]);
    final order = [for (final definition in _minimumDefinitions) definition.text('key')];
    return rows.toList()..sort((left, right) =>
        order.indexOf(left.text('minimumKey')).compareTo(order.indexOf(right.text('minimumKey'))));
  }

  Future<void> _ensureDay(DatabaseExecutor database, String date) async {
    _validDate(date);
    final day = DateTime.parse(date);
    await database.insert('daily_scores', {'userId': _userId, 'date': date},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final existing = await database.query('daily_tasks', columns: ['id'],
        where: 'userId = ? AND date = ? AND minimumKey IS NULL',
        whereArgs: [_userId, date], limit: 1);
    final templates = await database.query('schedule_templates',
        where: 'userId = ? AND isActive = 1 AND effectiveFrom <= ?',
        whereArgs: [_userId, date], orderBy: 'sortOrder');
    for (final template in templates) {
      final days = jsonDecode(template.text('daysOfWeek')) as List;
      if (!days.contains(day.weekday)) continue;
      final start = template.text('startTime');
      final end = template.text('endTime');
      final minutes = _minutes(end) - _minutes(start);
      final daytime = start == '13:00';
      final evening = start == '20:00' || start == '20:45';
      final project = daytime ? DefaultScheduleSeeder.daytimeProject(day)
          : evening ? DefaultScheduleSeeder.eveningProject(day) : '';
      final baseTitle = template.text('title');
      final checklist = DailyScoreCalculator.decodeChecklist(template.text('checklistJson'));
      final description = [
        '$start–$end',
        if (project.isNotEmpty) 'Proyek: $project',
        for (final item in checklist) item.text('title'),
      ].join('\n');
      await database.insert('daily_tasks', {
        'userId': _userId, 'date': date,
        'title': project.isEmpty ? baseTitle : '$baseTitle · $project',
        'description': description,
        'category': template.text('category'),
        'priority': existing.isEmpty && start == '09:30' ? 'Top 1' :
            existing.isEmpty && daytime ? 'Top 2' : 'Reguler',
        'estimatedMinutes': minutes > 0 ? minutes : minutes + 1440,
        'energyLevel': {'09:30', '13:00', '20:45'}.contains(start) ? 'Tinggi' : 'Sedang',
        'sourceScheduleId': template.number('id'),
        'scheduleStartTime': start, 'scheduleEndTime': end,
        'scheduleTitle': baseTitle,
        'subtasksJson': template.text('checklistJson'),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final definition in _minimumDefinitions) {
      await database.insert('daily_tasks', {
        'userId': _userId, 'date': date, 'minimumKey': definition.text('key'),
        'title': definition.text('title'), 'category': definition.text('category'),
        'estimatedMinutes': definition.number('minutes'), 'pointWeight': 1,
        'energyLevel': 'Rendah',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _updateScore(DatabaseExecutor database, String date) async {
    final tasks = await _tasks(database, date);
    final minimumTasks = await _minimumTasks(database, date);
    final dayScores = await database.query('daily_scores',
        where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
    final minimumMode = dayScores.single.text('dayMode') == 'Minimum';
    final scoredTasks = minimumMode ? minimumTasks : tasks;
    final sessions = await database.rawQuery('''
      SELECT f.*, t.minimumKey AS taskMinimumKey
      FROM focus_sessions f LEFT JOIN daily_tasks t ON t.id = f.taskId
      WHERE f.userId = ?''', [_userId]);
    final minimumIds = minimumTasks.map((task) => task.number('id')).toSet();
    final scoredSessions = minimumMode
        ? sessions.where((session) => minimumIds.contains(session.number('taskId', -1))).toList()
        : sessions.where((session) => session.text('taskMinimumKey').isEmpty).toList();
    final score = DailyScoreCalculator.calculate(
        tasks: scoredTasks, sessions: scoredSessions, day: DateTime.parse(date), now: _now());
    final completed = scoredTasks.where((task) => task.text('status') == 'Selesai');
    await database.update('daily_scores', {
      ...score,
      'completedSummary': completed.map((task) => task.text('title')).join('\n'),
    }, where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
    final points = {
      ...DailyScoreCalculator.taskPoints(tasks),
      ...DailyScoreCalculator.taskPoints(minimumTasks),
    };
    for (final task in [...tasks, ...minimumTasks]) {
      final value = points[task.number('id')] ?? 0;
      if (task.number('points') != value) {
        await database.update('daily_tasks', {'points': value},
            where: 'id = ?', whereArgs: [task.number('id')]);
      }
    }
  }

  Future<int> _streak(DatabaseExecutor database, String date) async {
    final scores = await database.query('daily_scores',
        where: 'userId = ? AND date <= ?', whereArgs: [_userId, date],
        orderBy: 'date DESC');
    var expected = DateTime.parse(date);
    var count = 0;
    for (final score in scores) {
      if (score.text('date') != dateKey(expected)) break;
      final qualifies = score.number('totalScore') > 0 || score.flag('streakProtected');
      if (!qualifies && score.text('date') != date) break;
      if (qualifies) count++;
      expected = expected.subtract(const Duration(days: 1));
    }
    return count;
  }

  static void _nonEmpty(String value, String name) {
    if (value.trim().isEmpty) throw ArgumentError('$name tidak boleh kosong.');
  }

  static void _oneOf(String value, Set<String> allowed, String name) {
    if (!allowed.contains(value)) throw ArgumentError('$name tidak valid: $value');
  }

  static void _rating(int value) {
    if (value < 1 || value > 10) throw ArgumentError('Nilai harus antara 1 dan 10.');
  }

  static void _validTime(String value) {
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
      throw ArgumentError('Jam harus berformat HH:mm.');
    }
  }

  static void _validDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        dateKey(parsed) != value) {
      throw ArgumentError('Tanggal harus berformat yyyy-MM-dd.');
    }
  }

  static int _minutes(String value) {
    final parts = value.split(':').map(int.parse).toList();
    return parts[0] * 60 + parts[1];
  }
}
