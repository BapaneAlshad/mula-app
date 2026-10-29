import 'package:flutter_test/flutter_test.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/services/schedule_reminder_planner.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  final now = DateTime.utc(2026, 10, 29, 8); // Thursday.

  DbRow template({String start = '10:00', String title = 'Jadwal baru',
    String effective = '', bool active = true, String days = '[4]'}) => {
    'id': 7, 'title': title, 'startTime': start, 'endTime': '11:00',
    'effectiveFrom': effective, 'isActive': active ? 1 : 0, 'daysOfWeek': days,
  };
  DbRow task({String start = '09:00', String title = 'Blok hari ini',
    String date = '2026-10-29', int source = 7}) => {
    'id': 20, 'sourceScheduleId': source, 'templateTitle': title,
    'startTime': start, 'endTime': '10:00', 'date': date,
  };

  test('strictness adds no lead, two-minute lead, or five-minute lead beside normal alarm', () {
    for (final entry in {'Lembut': 0, 'Seimbang': 2, 'Tegas': 5}.entries) {
      final plan = ScheduleReminderPlanner.plan([], now: now,
          strictness: entry.key, todayTasks: [task()]);
      expect(plan.where((row) => row.leadMinutes == 0).single.at,
          DateTime.utc(2026, 10, 29, 9));
      if (entry.value == 0) {
        expect(plan, hasLength(1));
      } else {
        expect(plan, hasLength(2));
        final lead = plan.singleWhere((row) => row.leadMinutes > 0);
        expect(lead.at, DateTime.utc(2026, 10, 29, 9).subtract(Duration(minutes: entry.value)));
        expect(lead.body, contains('${entry.value} menit'));
      }
    }
  });

  test('future template edit preserves today old time and title with no duplicate today alarm', () {
    final plan = ScheduleReminderPlanner.plan([template(effective: '2026-10-30')],
        now: now, todayTasks: [task()], strictness: 'Tegas');
    final today = plan.where((row) => row.fromTodaySnapshot).toList();
    expect(today, hasLength(2));
    expect(today.map((row) => row.title), everyElement(contains('Blok hari ini')));
    expect(today.singleWhere((row) => row.leadMinutes == 0).at, DateTime.utc(2026, 10, 29, 9));
    final recurring = plan.where((row) => !row.fromTodaySnapshot).toList();
    expect(recurring, hasLength(4));
    expect(recurring.firstWhere((row) => row.leadMinutes == 0).at, DateTime.utc(2026, 11, 5, 10));
    expect(recurring.map((row) => row.title), everyElement(contains('Jadwal baru')));
    expect(plan.map((row) => row.id).toSet(), hasLength(plan.length));
  });

  test('deactivating template never removes current-day persisted snapshot reminder', () {
    final plan = ScheduleReminderPlanner.plan([template(active: false)],
        now: now, todayTasks: [task()], strictness: 'Lembut');
    expect(plan, hasLength(1));
    expect(plan.single.fromTodaySnapshot, isTrue);
    expect(plan.single.title, 'Blok hari ini');
  });

  test('weekly alarm starts after effective date and lead never crosses validity boundary', () {
    final plan = ScheduleReminderPlanner.plan([
      template(start: '00:03', effective: '2026-11-06', days: '[5]'),
    ], now: now, strictness: 'Tegas');
    expect(plan.firstWhere((row) => row.leadMinutes == 0).at,
        DateTime.utc(2026, 11, 6, 0, 3));
    expect(plan.where((row) => row.leadMinutes > 0), isEmpty);
  });

  test('past leads are omitted today and unrelated/manual/old-day tasks are ignored', () {
    final plan = ScheduleReminderPlanner.plan([], now: DateTime.utc(2026, 10, 29, 8, 58),
        strictness: 'Tegas', todayTasks: [task(), task(source: 0), task(date: '2026-10-28')]);
    expect(plan, hasLength(1));
    expect(plan.single.at, DateTime.utc(2026, 10, 29, 9));
    expect(plan.single.leadMinutes, 0);
    expect(ScheduleReminderPlanner.plan([], now: DateTime.utc(2026, 10, 29, 9),
        todayTasks: [task()]), isEmpty);
  });

  test('unchanged template contributes exactly one normal alarm today and recurring next week', () {
    final plan = ScheduleReminderPlanner.plan([template(start: '09:00', title: 'Blok hari ini')],
        now: now, todayTasks: [task()], strictness: 'Lembut');
    expect(plan, hasLength(3));
    expect(plan.where((row) => row.at.day == 29), hasLength(1));
    expect(plan.firstWhere((row) => !row.fromTodaySnapshot).at, DateTime.utc(2026, 11, 5, 9));
  });

  test('Jakarta reminders keep timezone and weekly lead weekday through midnight', () {
    timezone_data.initializeTimeZones();
    final jakarta = tz.getLocation('Asia/Jakarta');
    final local = tz.TZDateTime(jakarta, 2026, 10, 29, 8);
    final plan = ScheduleReminderPlanner.plan([template(start: '00:03', days: '[5]')],
        now: local, strictness: 'Tegas');
    final lead = plan.firstWhere((row) => row.leadMinutes > 0);
    expect(lead.at, isA<tz.TZDateTime>());
    expect(lead.at, tz.TZDateTime(jakarta, 2026, 10, 29, 23, 58));
    expect(lead.at.toUtc(), DateTime.utc(2026, 10, 29, 16, 58));
  });

  test('initial callers without snapshots use valid current templates for today', () {
    final plan = ScheduleReminderPlanner.plan([template(start: '09:00')],
        now: now, strictness: 'Lembut');
    expect(plan.first.at, DateTime.utc(2026, 10, 29, 9));
    expect(plan, hasLength(3));
    final futureOnly = ScheduleReminderPlanner.plan([template(effective: '2026-10-30')],
        now: now, strictness: 'Lembut');
    expect(futureOnly.first.at, DateTime.utc(2026, 11, 5, 10));
  });

  test('dated schedule stays within fourteen days and refuses capacity overflow explicitly', () {
    final plan = ScheduleReminderPlanner.plan([
      template(days: '[1,2,3,4,5,6,7]'),
    ], now: now, strictness: 'Tegas', todayTasks: [task()]);
    expect(plan, hasLength(30));
    expect(plan.last.at, DateTime.utc(2026, 11, 12, 10));
    for (var index = 1; index < plan.length; index++) {
      expect(plan[index].at.isBefore(plan[index - 1].at), isFalse);
    }
    expect(() => ScheduleReminderPlanner.plan([
      for (var index = 0; index < 40; index++) template(days: '[1,2,3,4,5,6,7]'),
    ], now: now, strictness: 'Tegas', todayTasks: [task()]),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Jadwal terlalu padat'))));
  });
}
