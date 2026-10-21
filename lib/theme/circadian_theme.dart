import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';

class CircadianThemeState {
  const CircadianThemeState({
    required this.theme,
    required this.greeting,
    required this.atmosphere,
    required this.sanctuary,
    required this.periodLabel,
  });

  final ThemeData theme;
  final String greeting;
  final String atmosphere;
  final bool sanctuary;
  final String periodLabel;
}

class CircadianThemeController {
  const CircadianThemeController();

  CircadianThemeState resolve(
    DateTime now, {
    String name = 'Anggit',
    bool sanctuary = false,
    String wakeTime = '04:30',
    String sleepTime = '22:00',
    String workStartTime = '08:00',
    String workEndTime = '16:00',
  }) {
    final minute = now.hour * 60 + now.minute;
    final wake = _minutes(wakeTime, 270);
    final sleep = _minutes(sleepTime, 1320);
    final workStart = _minutes(workStartTime, 480);
    final workEnd = _minutes(workEndTime, 960);
    final resting = wake < sleep
        ? minute < wake || minute >= sleep
        : minute >= sleep && minute < wake;
    late String label;
    late String greeting;
    late String atmosphere;
    late Color seed;
    late Color background;
    var dark = false;

    if (sanctuary) {
      label = 'Sanctuary';
      greeting = 'Pelan-pelan, $name.';
      atmosphere = 'Tidak harus sempurna. Ambil napas, lalu satu langkah kecil.';
      seed = const Color(0xFF507E79);
      background = const Color(0xFFEFF5F1);
    } else if (resting) {
      label = 'Istirahat';
      greeting = 'Cukup untuk hari ini, $name.';
      atmosphere = 'Tanaman juga tumbuh ketika beristirahat.';
      seed = const Color(0xFFB8BCDB);
      background = const Color(0xFF171C29);
      dark = true;
    } else if (minute < workStart) {
      label = 'Pagi';
      greeting = 'Selamat pagi, $name.';
      atmosphere = 'Hari yang baru. Mulai dari hal yang kecil.';
      seed = const Color(0xFF667B40);
      background = const Color(0xFFF8F5EA);
    } else if (minute < workEnd) {
      label = 'Kerja';
      greeting = 'Satu per satu, $name.';
      atmosphere = 'Jaga perhatianmu untuk hal yang paling berarti.';
      seed = const Color(0xFF356D63);
      background = const Color(0xFFF0F4EF);
    } else if (minute < 20 * 60) {
      label = 'Keluarga';
      greeting = 'Saatnya hadir, $name.';
      atmosphere = 'Rumah dan orang tersayang juga bagian dari pertumbuhan.';
      seed = const Color(0xFFA35D3C);
      background = const Color(0xFFFFF3E8);
    } else {
      label = 'Malam';
      greeting = 'Tutup hari dengan lembut, $name.';
      atmosphere = 'Sedikit kemajuan, lalu beri ruang untuk istirahat.';
      seed = const Color(0xFFC3BCDF);
      background = const Color(0xFF222333);
      dark = true;
    }

    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: dark ? const Color(0xFF2D3040) : const Color(0xFFFFFEF9),
    );
    return CircadianThemeState(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        appBarTheme: AppBarTheme(
          backgroundColor: background,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surface,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLow,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: scheme.surface,
          indicatorColor: scheme.primaryContainer,
          height: 76,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        textTheme: ThemeData(brightness: scheme.brightness).textTheme.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        ),
        dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      ),
      greeting: greeting,
      atmosphere: atmosphere,
      sanctuary: sanctuary,
      periodLabel: label,
    );
  }

  static int _minutes(String value, int fallback) {
    final parts = value.split(':');
    if (parts.length != 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return fallback;
    }
    return hour * 60 + minute;
  }
}

final circadianThemeProvider = Provider<CircadianThemeState>((ref) {
  ref.watch(clockProvider.select((now) => now.millisecondsSinceEpoch ~/ 60000));
  final now = ref.read(clockProvider);
  final snapshot = ref.watch(appControllerProvider).valueOrNull;
  return const CircadianThemeController().resolve(
    now,
    name: snapshot?.user.text('name', 'Anggit') ?? 'Anggit',
    sanctuary: (snapshot?.score.text('dayMode', 'Normal') ?? 'Normal') != 'Normal' ||
        (snapshot?.preferences['sanctuary'] == 'true' &&
            snapshot?.preferences['sanctuaryDate'] == snapshot?.date),
    wakeTime: snapshot?.user.text('wakeTime', '04:30') ?? '04:30',
    sleepTime: snapshot?.user.text('sleepTime', '22:00') ?? '22:00',
    workStartTime: snapshot?.user.text('workStartTime', '08:00') ?? '08:00',
    workEndTime: snapshot?.user.text('workEndTime', '16:00') ?? '16:00',
  );
});
