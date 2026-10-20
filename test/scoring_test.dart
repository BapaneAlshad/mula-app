import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mula/data/daily_score_calculator.dart';
import 'package:mula/domain/app_snapshot.dart';

void main() {
  final day = DateTime(2026, 10, 21);
  final started = DateTime(2026, 10, 21, 9);

  DbRow task({int id = 1, String status = 'Belum mulai', String start = '09:00',
      String checklist = '[]', int minutes = 60}) => {
    'id': id, 'status': status, 'startTime': start, 'estimatedMinutes': minutes,
    'subtasksJson': checklist,
  };
  DbRow session({int id = 1, int? taskId = 1, DateTime? start, int seconds = 1800,
      String status = 'Selesai'}) {
    final from = start ?? started;
    return {
      'id': id, 'taskId': taskId, 'plannedSeconds': seconds,
      'actualSeconds': seconds, 'status': status,
      'startedAt': from.toIso8601String(),
      'completedAt': status == 'Berjalan' ? null :
          from.add(Duration(seconds: seconds)).toIso8601String(),
    };
  }

  Map<String, int> score(List<DbRow> tasks, List<DbRow> sessions, {DateTime? now}) =>
      DailyScoreCalculator.calculate(tasks: tasks, sessions: sessions,
          day: day, now: now ?? DateTime(2026, 10, 21, 22));

  test('complete task and focus on the same task do not add duplicate credit', () {
    final tasks = [task(status: 'Selesai'), task(id: 2)];
    expect(score(tasks, [])['totalScore'], 18);
    expect(score(tasks, [session(seconds: 3600)])['workScore'], 18);
  });

  test('overlapping focus is merged and checklist coverage is not added twice', () {
    final checklist = jsonEncode([
      {'title': 'Bagian satu', 'done': true},
      {'title': 'Bagian dua', 'done': false},
    ]);
    final tasks = [task(checklist: checklist)];
    final sessions = [session(), session(id: 2)];
    expect(score(tasks, sessions)['workScore'], 18);
    sessions.add(session(id: 3, start: started.add(const Duration(minutes: 30))));
    expect(score(tasks, sessions)['workScore'], 35);
  });

  test('running focus uses wall timestamps and never exceeds planned duration', () {
    final tasks = [task()];
    final active = session(seconds: 1800, status: 'Berjalan');
    expect(score(tasks, [active], now: started.add(const Duration(minutes: 15)))
        ['workScore'], 9);
    expect(score(tasks, [active], now: started.add(const Duration(hours: 2)))
        ['workScore'], 18);
    expect(score(tasks, [active], now: started.subtract(const Duration(minutes: 2)))
        ['workScore'], 0);
  });

  test('cancelled focus retains credit for the actual work already completed', () {
    expect(score([task()], [session(status: 'Dibatalkan')])['workScore'], 18);
  });

  test('every bucket has its own cap and all completed tasks total 100', () {
    final tasks = [
      task(id: 1, start: '04:30', status: 'Selesai'),
      task(id: 2, start: '08:00', status: 'Selesai'),
      task(id: 3, start: '17:00', status: 'Selesai'),
      task(id: 4, start: '20:00', status: 'Selesai'),
    ];
    expect(score(tasks, [session(taskId: null, seconds: 7200)]), {
      'morningScore': 20, 'workScore': 35, 'healthFamilyScore': 25,
      'sideJobScore': 20, 'totalScore': 100,
    });
    expect(DailyScoreCalculator.taskPoints(tasks).values.fold<int>(0,
        (sum, value) => sum + value), 100);
    expect(score([], [])['totalScore'], 0);
  });

  test('focus crossing midnight only credits the seconds inside the selected day', () {
    final previousNight = DateTime(2026, 10, 20, 23, 30);
    final tasks = [task(start: '04:30')];
    expect(score(tasks, [session(taskId: null, start: previousNight, seconds: 3600)])
        ['morningScore'], 10);
  });
}
