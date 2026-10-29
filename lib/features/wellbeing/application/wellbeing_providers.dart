import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/app_controller.dart';
import '../../../data/wellbeing_repository.dart';
import '../../../domain/app_snapshot.dart';

final wellbeingRepositoryProvider = Provider<WellbeingRepository>((ref) =>
    WellbeingRepository(ref.watch(databaseProvider), now: ref.watch(appNowProvider)));

final anxietySessionProvider = FutureProvider<DbRow?>((ref) =>
    ref.watch(wellbeingRepositoryProvider).activeSession());

final historyMonthProvider = FutureProvider.autoDispose.family<HistoryRange, String>((ref, month) {
  ref.watch(appControllerProvider);
  final date = DateTime.parse('$month-01');
  return ref.watch(wellbeingRepositoryProvider).history(
      date, DateTime(date.year, date.month + 1, 0));
});

final historyDayProvider = FutureProvider.autoDispose.family<HistoryDay, String>((ref, day) {
  ref.watch(appControllerProvider);
  return ref.watch(wellbeingRepositoryProvider).day(DateTime.parse(day));
});

final historyWeekProvider = FutureProvider.autoDispose.family<HistoryRange, String>((ref, day) {
  ref.watch(appControllerProvider);
  final date = DateTime.parse(day);
  return ref.watch(wellbeingRepositoryProvider).history(
      date.subtract(const Duration(days: 6)), date);
});
