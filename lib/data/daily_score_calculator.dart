import 'dart:convert';

import '../domain/app_snapshot.dart';

/// Scores are coverage of planned minutes in four independent, capped buckets.
/// Checklist completion and focus time cover the same work: use their maximum,
/// never their sum. Completing a task covers it fully. Overlapping sessions for
/// the same task are merged, and standalone sessions are merged per bucket.
class DailyScoreCalculator {
  static const caps = <String, int>{
    'morningScore': 20,
    'workScore': 35,
    'healthFamilyScore': 25,
    'sideJobScore': 20,
  };

  static String bucketForTask(DbRow task) {
    final start = task.text('startTime');
    if (start.isNotEmpty) {
      if (start.compareTo('08:00') < 0) return 'morningScore';
      if (start.compareTo('16:00') < 0) return 'workScore';
      if (start.compareTo('20:00') < 0) return 'healthFamilyScore';
      return 'sideJobScore';
    }
    return switch (task.text('category')) {
      'Side Job' => 'sideJobScore',
      'Pribadi' => 'healthFamilyScore',
      'Rutinitas' => 'morningScore',
      _ => 'workScore',
    };
  }

  static Map<String, int> calculate({
    required List<DbRow> tasks,
    required List<DbRow> sessions,
    required DateTime day,
    required DateTime now,
  }) {
    final startOfDay = DateTime(day.year, day.month, day.day);
    final endOfDay = DateTime(day.year, day.month, day.day + 1);
    final tasksById = {for (final task in tasks) task.number('id'): task};
    final taskIntervals = <int, List<_Interval>>{};
    final standaloneIntervals = <String, List<_Interval>>{};
    for (final session in sessions) {
      final started = DateTime.tryParse(session.text('startedAt'))?.toLocal();
      if (started == null) continue;
      final planned = session.number('plannedSeconds');
      final completed = DateTime.tryParse(session.text('completedAt'))?.toLocal();
      final wallEnd = completed ?? now;
      final wallSeconds = wallEnd.difference(started).inSeconds;
      final allowedSeconds = session.text('status') == 'Berjalan'
          ? wallSeconds.clamp(0, planned).toInt()
          : session.number('actualSeconds').clamp(0, planned)
              .clamp(0, wallSeconds < 0 ? 0 : wallSeconds).toInt();
      final ended = started.add(Duration(seconds: allowedSeconds));
      final clippedStart = started.isBefore(startOfDay) ? startOfDay : started;
      final clippedEnd = ended.isAfter(endOfDay) ? endOfDay : ended;
      if (!clippedEnd.isAfter(clippedStart)) continue;
      final interval = _Interval(clippedStart, clippedEnd);
      final taskId = session.number('taskId', -1);
      if (tasksById.containsKey(taskId)) {
        taskIntervals.putIfAbsent(taskId, () => []).add(interval);
      } else {
        final hour = clippedStart.hour;
        final bucket = hour < 8 ? 'morningScore'
            : hour < 16 ? 'workScore'
            : hour < 20 ? 'healthFamilyScore' : 'sideJobScore';
        standaloneIntervals.putIfAbsent(bucket, () => []).add(interval);
      }
    }

    final planned = <String, double>{for (final key in caps.keys) key: 0};
    final plannedSeconds = <String, double>{for (final key in caps.keys) key: 0};
    final covered = <String, double>{for (final key in caps.keys) key: 0};
    for (final task in tasks) {
      final bucket = bucketForTask(task);
      final seconds = task.number('estimatedMinutes', 25) * 60.0;
      final weight = _weight(task);
      planned[bucket] = planned[bucket]! + weight;
      plannedSeconds[bucket] = plannedSeconds[bucket]! + seconds;
      var fraction = 0.0;
      if (task.text('status') == 'Selesai') {
        fraction = 1;
      } else if (!{'Dilewati', 'Ditunda'}.contains(task.text('status'))) {
        final checklist = decodeChecklist(task.text('subtasksJson', '[]'));
        if (checklist.isNotEmpty) {
          fraction = checklist.where((item) => item['done'] == true).length /
              checklist.length;
        }
      }
      final focused = _unionSeconds(taskIntervals[task.number('id')] ?? []);
      final completedCoverage = seconds * fraction;
      final coverage = completedCoverage > focused ? completedCoverage : focused;
      covered[bucket] = covered[bucket]! + coverage.clamp(0, seconds) / seconds * weight;
    }
    final result = <String, int>{};
    for (final entry in caps.entries) {
      final baseline = planned[entry.key]!;
      final standalone = _unionSeconds(standaloneIntervals[entry.key] ?? []);
      final standaloneCoverage = baseline == 0 ? 0.0 :
          standalone / plannedSeconds[entry.key]! * baseline;
      result[entry.key] = baseline == 0 ? 0
          : ((covered[entry.key]! + standaloneCoverage) / baseline * entry.value)
              .round().clamp(0, entry.value).toInt();
    }
    result['totalScore'] = result.values.fold<int>(0, (sum, score) => sum + score);
    return result;
  }

  /// Allocates integer point labels using largest remainders, so each populated
  /// bucket sums exactly to its cap, even when custom tasks are added.
  static Map<int, int> taskPoints(List<DbRow> tasks) {
    final result = <int, int>{};
    for (final entry in caps.entries) {
      final group = tasks.where((task) => bucketForTask(task) == entry.key).toList();
      final minutes = group.fold<double>(0, (sum, task) => sum + _weight(task));
      if (minutes == 0) continue;
      final remainders = <({int id, double remainder})>[];
      var assigned = 0;
      for (final task in group) {
        final value = _weight(task) / minutes * entry.value;
        final points = value.floor();
        final id = task.number('id');
        result[id] = points;
        assigned += points;
        remainders.add((id: id, remainder: value - points));
      }
      remainders.sort((left, right) {
        final comparison = right.remainder.compareTo(left.remainder);
        return comparison == 0 ? left.id.compareTo(right.id) : comparison;
      });
      for (var index = 0; index < entry.value - assigned; index++) {
        final id = remainders[index].id;
        result[id] = result[id]! + 1;
      }
    }
    return result;
  }

  static double _weight(DbRow task) =>
      task.number('pointWeight', task.number('estimatedMinutes', 25)).toDouble();

  static List<DbRow> decodeChecklist(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map((item) => {
        'title': (item['title'] ?? '').toString(),
        'done': item['done'] == true,
      }).toList();
    } on FormatException {
      return [];
    }
  }

  static int _unionSeconds(List<_Interval> intervals) {
    if (intervals.isEmpty) return 0;
    intervals.sort((left, right) => left.start.compareTo(right.start));
    var currentStart = intervals.first.start;
    var currentEnd = intervals.first.end;
    var seconds = 0;
    for (final interval in intervals.skip(1)) {
      if (!interval.start.isAfter(currentEnd)) {
        if (interval.end.isAfter(currentEnd)) currentEnd = interval.end;
      } else {
        seconds += currentEnd.difference(currentStart).inSeconds;
        currentStart = interval.start;
        currentEnd = interval.end;
      }
    }
    return seconds + currentEnd.difference(currentStart).inSeconds;
  }
}

class _Interval {
  const _Interval(this.start, this.end);
  final DateTime start;
  final DateTime end;
}
