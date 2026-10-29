import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import '../domain/app_snapshot.dart';

class ScheduleReminderPlan {
  const ScheduleReminderPlan({required this.id, required this.title, required this.body,
    required this.at, required this.fromTodaySnapshot, required this.leadMinutes});
  final int id;
  final String title;
  final String body;
  final DateTime at;
  final bool fromTodaySnapshot;
  final int leadMinutes;
}

/// Future templates and today's immutable task snapshots are planned separately.
/// This keeps a template edit effective tomorrow from changing today's alarms.
class ScheduleReminderPlanner {
  static const horizonDays = 14;
  static const maximumNotifications = 450;

  static List<ScheduleReminderPlan> plan(List<DbRow> templates, {
    required DateTime now,
    String strictness = 'Seimbang',
    List<DbRow> todayTasks = const [],
  }) {
    final leadMinutes = switch (strictness) {
      'Lembut' => 0,
      'Seimbang' => 2,
      'Tegas' => 5,
      _ => throw ArgumentError.value(strictness, 'strictness'),
    };
    final result = <ScheduleReminderPlan>[];
    final today = _dateKey(now);

    void add(String title, DateTime at, {required bool snapshot, required int lead}) {
      // The low range remains separate from the fixed focus/game/test alarm IDs.
      if (result.length >= maximumNotifications) {
        throw StateError('Jadwal terlalu padat untuk pengingat 14 hari. '
            'Nonaktifkan beberapa blok atau pilih tingkat Lembut, lalu aktifkan pengingat kembali.');
      }
      result.add(ScheduleReminderPlan(
        id: 10000 + result.length,
        title: lead == 0 ? title : 'Bersiap: $title',
        body: lead == 0
            ? 'Kembali ke blok berikutnya. Mulai dari satu langkah kecil.'
            : 'Blok dimulai $lead menit lagi. Siapkan satu tindakan kecil.',
        at: at,
        fromTodaySnapshot: snapshot,
        leadMinutes: lead,
      ));
    }

    for (final template in templates.where((row) => row.flag('isActive'))) {
      final time = _time(template.text('startTime'));
      final effectiveFrom = template.text('effectiveFrom');
      if (effectiveFrom.isNotEmpty && !_validDate(effectiveFrom)) {
        throw FormatException('Tanggal berlaku jadwal tidak valid: $effectiveFrom');
      }
      final decodedDays = jsonDecode(template.text('daysOfWeek', '[1,2,3,4,5,6,7]'));
      if (decodedDays is! List || decodedDays.isEmpty ||
          decodedDays.any((day) => day is! int || day < 1 || day > 7)) {
        throw const FormatException('Hari jadwal harus berisi angka 1–7.');
      }
      final weekdays = decodedDays.cast<int>().toSet();
      // FLN's weekly date-component matching ignores the initial calendar date.
      // Explicit one-shots preserve effectiveFrom and avoid duplicate alarms today.
      for (var offset = todayTasks.isEmpty ? 0 : 1; offset <= horizonDays; offset++) {
        final next = _at(now, now.year, now.month, now.day + offset, time.$1, time.$2);
        if (!weekdays.contains(next.weekday) || !next.isAfter(now) ||
            (effectiveFrom.isNotEmpty && _dateKey(next).compareTo(effectiveFrom) < 0)) {
          continue;
        }
        add(template.text('title'), next, snapshot: false, lead: 0);
        if (leadMinutes > 0) {
          final leadAt = next.subtract(Duration(minutes: leadMinutes));
          if (leadAt.isAfter(now) &&
              (effectiveFrom.isEmpty || _dateKey(leadAt).compareTo(effectiveFrom) >= 0)) {
            add(template.text('title'), leadAt, snapshot: false, lead: leadMinutes);
          }
        }
      }
    }

    for (final task in todayTasks) {
      if (task.number('sourceScheduleId') <= 0 ||
          (task.text('date').isNotEmpty && task.text('date') != today)) {
        continue;
      }
      final startTime = task.text('startTime', task.text('scheduleStartTime'));
      if (startTime.isEmpty) continue;
      final time = _time(startTime);
      final at = _at(now, now.year, now.month, now.day, time.$1, time.$2);
      final title = task.text('templateTitle', task.text('scheduleTitle', task.text('title')));
      if (at.isAfter(now)) add(title, at, snapshot: true, lead: 0);
      if (leadMinutes > 0) {
        final leadAt = at.subtract(Duration(minutes: leadMinutes));
        if (leadAt.isAfter(now)) add(title, leadAt, snapshot: true, lead: leadMinutes);
      }
    }
    result.sort((a, b) => a.at.compareTo(b.at));
    return result;
  }

  static (int, int) _time(String value) {
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
      throw FormatException('Jam jadwal tidak valid: $value');
    }
    return (int.parse(value.substring(0, 2)), int.parse(value.substring(3, 5)));
  }

  static bool _validDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final date = DateTime.tryParse(value);
    return date != null && _dateKey(date) == value;
  }

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime _at(DateTime source, int year, int month, int day, int hour, int minute) {
    if (source is tz.TZDateTime) return tz.TZDateTime(source.location, year, month, day, hour, minute);
    return source.isUtc ? DateTime.utc(year, month, day, hour, minute)
        : DateTime(year, month, day, hour, minute);
  }
}
