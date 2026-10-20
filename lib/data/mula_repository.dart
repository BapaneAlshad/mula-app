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
      await _updateScore(transaction, date);
      final users = await transaction.query('users', where: 'id = ?', whereArgs: [_userId]);
      final templates = await transaction.query('schedule_templates',
          where: 'userId = ?', whereArgs: [_userId], orderBy: 'sortOrder');
      final tasks = await _tasks(transaction, date);
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
    await _mutateTask(id, (transaction, task) async {
      final values = <String, Object?>{
        'status': status,
        'completedAt': status == 'Selesai' ? _now().toIso8601String() : null,
        'skippedReason': {'Dilewati', 'Ditunda'}.contains(status) ? reason?.trim() : null,
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
    _nonEmpty(title, 'Judul tugas');
    _oneOf(category, {'Wajib', 'Penting', 'Jika Sempat', 'Rutinitas', 'Tim', 'Pribadi', 'Side Job'}, 'Kategori');
    _oneOf(priority, {'Top 1', 'Top 2', 'Top 3', 'Reguler'}, 'Prioritas');
    if (estimatedMinutes < 1 || estimatedMinutes > 1440) {
      throw ArgumentError('Estimasi harus antara 1 dan 1440 menit.');
    }
    _validDate(date);
    final database = await _database.database;
    await database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      await transaction.insert('daily_tasks', {
        'userId': _userId, 'date': date, 'title': title.trim(),
        'category': category, 'priority': priority, 'estimatedMinutes': estimatedMinutes,
      });
      await _updateScore(transaction, date);
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
    final database = await _database.database;
    await database.transaction((transaction) async {
      await _ensureDay(transaction, date);
      await transaction.update('daily_scores', {
        'dayMode': mode, 'adaptationReason': reason?.trim() ?? '',
      }, where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
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
        if (task.text('status') != 'Selesai') {
          await transaction.update('daily_tasks', {'status': 'Sedang berjalan'},
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
      await _updateScore(transaction, task.text('date'));
    });
  }

  Future<DbRow> _task(DatabaseExecutor database, int id) async {
    final rows = await database.rawQuery('''
      SELECT t.*, s.startTime, s.endTime, s.title AS templateTitle
      FROM daily_tasks t LEFT JOIN schedule_templates s ON s.id = t.sourceScheduleId
      WHERE t.id = ? AND t.userId = ?''', [id, _userId]);
    if (rows.isEmpty) throw StateError('Tugas tidak ditemukan.');
    return rows.single;
  }

  Future<List<DbRow>> _tasks(DatabaseExecutor database, String date) =>
      database.rawQuery('''
        SELECT t.*, s.startTime, s.endTime, s.title AS templateTitle, s.sortOrder
        FROM daily_tasks t LEFT JOIN schedule_templates s ON s.id = t.sourceScheduleId
        WHERE t.userId = ? AND t.date = ?
        ORDER BY CASE WHEN s.sortOrder IS NULL THEN 1 ELSE 0 END,
          s.sortOrder, t.id''', [_userId, date]);

  Future<void> _ensureDay(DatabaseExecutor database, String date) async {
    _validDate(date);
    final day = DateTime.parse(date);
    await database.insert('daily_scores', {'userId': _userId, 'date': date},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    final templates = await database.query('schedule_templates',
        where: 'userId = ? AND isActive = 1', whereArgs: [_userId], orderBy: 'sortOrder');
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
        'priority': start == '09:30' ? 'Top 1' : daytime ? 'Top 2' : 'Reguler',
        'estimatedMinutes': minutes > 0 ? minutes : minutes + 1440,
        'energyLevel': {'09:30', '13:00', '20:45'}.contains(start) ? 'Tinggi' : 'Sedang',
        'sourceScheduleId': template.number('id'),
        'subtasksJson': template.text('checklistJson'),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _updateScore(DatabaseExecutor database, String date) async {
    final tasks = await _tasks(database, date);
    final sessions = await database.query('focus_sessions',
        where: 'userId = ?', whereArgs: [_userId]);
    final score = DailyScoreCalculator.calculate(
        tasks: tasks, sessions: sessions, day: DateTime.parse(date), now: _now());
    final completed = tasks.where((task) => task.text('status') == 'Selesai');
    await database.update('daily_scores', {
      ...score,
      'completedSummary': completed.map((task) => task.text('title')).join('\n'),
    }, where: 'userId = ? AND date = ?', whereArgs: [_userId, date]);
    final points = DailyScoreCalculator.taskPoints(tasks);
    for (final task in tasks) {
      final value = points[task.number('id')] ?? 0;
      if (task.number('points') != value) {
        await database.update('daily_tasks', {'points': value},
            where: 'id = ?', whereArgs: [task.number('id')]);
      }
    }
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
