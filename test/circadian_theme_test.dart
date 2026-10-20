import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/theme/circadian_theme.dart';

void main() {
  const controller = CircadianThemeController();
  test('circadian changes exactly at all requested boundaries', () {
    final cases = <(int, int, String)>[
      (4, 29, 'Istirahat'), (4, 30, 'Pagi'), (7, 59, 'Pagi'),
      (8, 0, 'Kerja'), (15, 59, 'Kerja'), (16, 0, 'Keluarga'),
      (19, 59, 'Keluarga'), (20, 0, 'Malam'), (21, 59, 'Malam'),
      (22, 0, 'Istirahat'), (0, 0, 'Istirahat'),
    ];
    for (final (hour, minute, label) in cases) {
      expect(controller.resolve(DateTime(2026, 10, 21, hour, minute)).periodLabel, label);
    }
  });

  test('sanctuary overrides every circadian palette', () {
    final morning = controller.resolve(DateTime(2026, 10, 21, 7), sanctuary: true);
    final night = controller.resolve(DateTime(2026, 10, 21, 21), sanctuary: true);
    expect(morning.periodLabel, 'Sanctuary');
    expect(morning.theme.scaffoldBackgroundColor, night.theme.scaffoldBackgroundColor);
    expect(night.theme.brightness, Brightness.light);
  });

  test('wake and sleep preferences affect daily boundaries', () {
    expect(controller.resolve(DateTime(2026, 10, 21, 5), wakeTime: '06:00').periodLabel,
        'Istirahat');
    expect(controller.resolve(DateTime(2026, 10, 21, 21), sleepTime: '21:00').periodLabel,
        'Istirahat');
  });

  test('an overnight wake interval still has active hours', () {
    expect(controller.resolve(DateTime(2026, 10, 21, 23),
        wakeTime: '22:00', sleepTime: '06:00').periodLabel, 'Malam');
    expect(controller.resolve(DateTime(2026, 10, 21, 12),
        wakeTime: '22:00', sleepTime: '06:00').periodLabel, 'Istirahat');
  });

  test('new day exits sanctuary even if an old global preference remains', () async {
    final notifier = _ThemeTestController();
    final container = ProviderContainer(overrides: [
      appControllerProvider.overrideWith(() => notifier),
      clockProvider.overrideWithValue(DateTime(2026, 10, 21, 9)),
    ]);
    addTearDown(container.dispose);
    await container.read(appControllerProvider.future);
    expect(container.read(circadianThemeProvider).sanctuary, isTrue);
    notifier.nextDay();
    expect(container.read(circadianThemeProvider).sanctuary, isFalse);
  });
}

class _ThemeTestController extends AppController {
  @override
  Future<AppSnapshot> build() async => _snapshot('Minimum', '2026-10-21');

  void nextDay() => state = AsyncData(_snapshot('Normal', '2026-10-22'));

  AppSnapshot _snapshot(String mode, String date) => AppSnapshot(
    user: const {'name': 'Anggit'},
    templates: const [], tasks: const [], thoughts: const [], activeFocus: null,
    score: {'dayMode': mode}, history: const [],
    preferences: const {'sanctuary': 'true'}, date: date,
  );
}
