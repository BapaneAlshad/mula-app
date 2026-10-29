import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/app_snapshot.dart';
import 'local/app_database.dart';

/// Read-only history and durable drafts for a guided calming session.
class WellbeingRepository {
  WellbeingRepository(this._database, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AppDatabase _database;
  final DateTime Function() _now;
  static const sessionKey = 'anxietySession';
  static const groundingPrompts = <String>[
    'Sebutkan 5 hal yang bisa kamu lihat.',
    'Rasakan 4 hal yang bisa kamu sentuh.',
    'Dengarkan 3 suara di sekitarmu.',
    'Perhatikan 2 aroma di sekitarmu.',
    'Perhatikan 1 rasa atau satu teguk air.',
  ];

  Future<DbRow?> activeSession() async {
    return _readSession(await _database.database);
  }

  Future<DbRow?> _readSession(DatabaseExecutor database) async {
    final rows = await database.query('app_preferences',
        where: 'key = ?', whereArgs: [sessionKey]);
    if (rows.isEmpty) return null;
    final value = jsonDecode(rows.single.text('value'));
    if (value is! Map<String, dynamic> ||
        value['id'] is! String || (value['id'] as String).isEmpty ||
        DateTime.tryParse('${value['startedAt']}') == null ||
        value['before'] is! int ||
        (value['before'] as int) < 1 ||
        (value['before'] as int) > 10 ||
        value['plannedSeconds'] != 120 ||
        !{'breathing', 'grounding'}.contains(value['phase']) ||
        value['grounding'] is! List<dynamic> ||
        (value['grounding'] as List<dynamic>).length != groundingPrompts.length ||
        !(value['grounding'] as List<dynamic>).every((item) => item is bool)) {
      throw const FormatException('Sesi tenang tersimpan tidak valid.');
    }
    return Map<String, Object?>.from(value);
  }

  Future<void> _writeSession(DatabaseExecutor database, DbRow session) =>
      database.insert('app_preferences',
        {'key': sessionKey, 'value': jsonEncode(session)},
        conflictAlgorithm: ConflictAlgorithm.replace).then((_) {});

  Future<DbRow> startSession(int before) async {
    _rating(before);
    final database = await _database.database;
    return database.transaction((transaction) async {
      final existing = await _readSession(transaction);
      if (existing != null) return existing;
      final stamp = _now().toUtc().toIso8601String();
      final session = <String, Object?>{
        'id': stamp, 'startedAt': stamp, 'before': before,
        'plannedSeconds': 120, 'phase': 'breathing',
        'grounding': List<bool>.filled(groundingPrompts.length, false),
      };
      await _writeSession(transaction, session);
      return session;
    });
  }

  Future<void> setGrounding(int index, bool value) async {
    if (index < 0 || index >= groundingPrompts.length) {
      throw RangeError.index(index, groundingPrompts);
    }
    final database = await _database.database;
    await database.transaction((transaction) async {
      final session = await _readSession(transaction);
      if (session == null) throw StateError('Mulai sesi tenang terlebih dahulu.');
      final checks = List<bool>.from(session['grounding']! as List<dynamic>);
      checks[index] = value;
      await _writeSession(transaction,
          {...session, 'phase': 'grounding', 'grounding': checks});
    });
  }

  Future<void> useGrounding() async {
    final database = await _database.database;
    await database.transaction((transaction) async {
      final session = await _readSession(transaction);
      if (session == null) throw StateError('Mulai sesi tenang terlebih dahulu.');
      await _writeSession(transaction, {...session, 'phase': 'grounding'});
    });
  }

  /// The id makes a repeated tap safe, including an old route after restoration.
  Future<bool> finishSession(String sessionId, int after) async {
    _rating(after);
    final database = await _database.database;
    return database.transaction((transaction) async {
      final session = await _readSession(transaction);
      if (session == null || session.text('id') != sessionId) return false;
      final now = _now();
      final startedAt = DateTime.parse(session.text('startedAt'));
      final seconds = now.difference(startedAt).inSeconds;
      await transaction.insert('anxiety_sessions', {
        'userId': 1,
        'mode': session.text('phase') == 'grounding'
            ? 'Napas & grounding 5–4–3–2–1' : 'Napas tenang',
        'durationSeconds': seconds < 0 ? 0 : seconds,
        'anxietyBefore': session.number('before'), 'anxietyAfter': after,
        'completedAt': now.toUtc().toIso8601String(),
      });
      final date = dateKey(now);
      // Historical screens never create days; the running app has already made
      // today's score, so update it only when it exists.
      await transaction.update('daily_scores', {'anxietyScore': after},
          where: 'userId = ? AND date = ?', whereArgs: [1, date]);
      await transaction.delete('app_preferences',
          where: 'key = ?', whereArgs: [sessionKey]);
      return true;
    });
  }

  static void _rating(int value) {
    if (value < 1 || value > 10) {
      throw ArgumentError.value(value, 'rating', 'Gunakan nilai 1–10.');
    }
  }

  static String dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  Future<HistoryRange> history(DateTime from, DateTime through) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(through.year, through.month, through.day + 1);
    if (!end.isAfter(start) || end.difference(start).inDays > 370) {
      throw ArgumentError('Rentang riwayat harus 1–370 hari.');
    }
    final database = await _database.database;
    return database.transaction((transaction) async {
      final scores = await transaction.query('daily_scores',
          where: 'userId = ? AND date >= ? AND date < ?',
          whereArgs: [1, dateKey(start), dateKey(end)], orderBy: 'date ASC');
      final sessions = await transaction.query('focus_sessions',
          where: "userId = ? AND status != 'Berjalan' AND actualSeconds > 0",
          whereArgs: [1], orderBy: 'startedAt ASC');
      final focusSeconds = <String, int>{};
      for (var day = start; day.isBefore(end);
          day = DateTime(day.year, day.month, day.day + 1)) {
        focusSeconds[dateKey(day)] = _focusSeconds(sessions, day);
      }
      return HistoryRange(scores: scores, focusSeconds: focusSeconds);
    });
  }

  Future<HistoryDay> day(DateTime day) async {
    final date = dateKey(day);
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final database = await _database.database;
    return database.transaction((transaction) async {
      final scores = await transaction.query('daily_scores',
          where: 'userId = ? AND date = ?', whereArgs: [1, date]);
      final tasks = await transaction.query('daily_tasks',
          where: 'userId = ? AND date = ?', whereArgs: [1, date],
          orderBy: 'id ASC');
      final sessions = await transaction.query('focus_sessions',
          where: "userId = ? AND status != 'Berjalan' AND actualSeconds > 0",
          whereArgs: [1], orderBy: 'startedAt ASC');
      final anxiety = await transaction.query('anxiety_sessions',
          where: 'userId = ?', whereArgs: [1], orderBy: 'completedAt DESC');
      return HistoryDay(
        date: date, score: scores.isEmpty ? null : scores.single,
        tasks: tasks, focusSeconds: _focusSeconds(sessions, start),
        anxietySessions: anxiety.where((session) {
          final stamp = DateTime.tryParse(session.text('completedAt'))?.toLocal();
          return stamp != null && !stamp.isBefore(start) && stamp.isBefore(end);
        }).toList(),
      );
    });
  }

  /// Merge real recorded intervals, so overlapping and midnight sessions cannot
  /// inflate weekly totals. Completed flags alone never create focus minutes.
  static int _focusSeconds(List<DbRow> sessions, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final intervals = <({DateTime start, DateTime end})>[];
    for (final row in sessions) {
      final began = DateTime.tryParse(row.text('startedAt'))?.toLocal();
      final completed = DateTime.tryParse(row.text('completedAt'))?.toLocal();
      if (began == null || completed == null) continue;
      final wallSeconds = completed.difference(began).inSeconds;
      final seconds = row.number('actualSeconds')
          .clamp(0, row.number('plannedSeconds'))
          .clamp(0, wallSeconds < 0 ? 0 : wallSeconds).toInt();
      final ended = began.add(Duration(seconds: seconds));
      final clippedStart = began.isBefore(start) ? start : began;
      final clippedEnd = ended.isAfter(end) ? end : ended;
      if (clippedEnd.isAfter(clippedStart)) {
        intervals.add((start: clippedStart, end: clippedEnd));
      }
    }
    intervals.sort((left, right) => left.start.compareTo(right.start));
    DateTime? openStart;
    DateTime? openEnd;
    var total = 0;
    for (final interval in intervals) {
      if (openStart == null || openEnd == null) {
        openStart = interval.start;
        openEnd = interval.end;
      } else if (!interval.start.isAfter(openEnd)) {
        if (interval.end.isAfter(openEnd)) openEnd = interval.end;
      } else {
        total += openEnd.difference(openStart).inSeconds;
        openStart = interval.start;
        openEnd = interval.end;
      }
    }
    if (openStart != null && openEnd != null) {
      total += openEnd.difference(openStart).inSeconds;
    }
    return total;
  }
}

class HistoryRange {
  const HistoryRange({required this.scores, required this.focusSeconds});
  final List<DbRow> scores;
  final Map<String, int> focusSeconds;
  int get totalFocusSeconds => focusSeconds.values.fold(0, (sum, item) => sum + item);
  int get averageScore => scores.isEmpty ? 0 :
      (scores.fold<int>(0, (sum, row) => sum + row.number('totalScore')) / scores.length).round();
}

class HistoryDay {
  const HistoryDay({required this.date, required this.score, required this.tasks,
    required this.focusSeconds, required this.anxietySessions});
  final String date;
  final DbRow? score;
  final List<DbRow> tasks;
  final int focusSeconds;
  final List<DbRow> anxietySessions;
}
