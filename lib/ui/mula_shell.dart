import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_snapshot.dart';
import '../theme/circadian_theme.dart';
import 'focus_page.dart';
import 'progress_page.dart';
import 'settings_page.dart';
import 'thoughts_page.dart';
import 'today_page.dart';
import 'widgets/shared.dart';

class MulaShell extends ConsumerStatefulWidget {
  const MulaShell({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<MulaShell> createState() => _MulaShellState();
}

class _MulaShellState extends ConsumerState<MulaShell> with PersistedActions<MulaShell> {
  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final theme = ref.watch(circadianThemeProvider);
    final selected = (int.tryParse(data.preferences['selectedTab'] ?? '0') ?? 0).clamp(0, 4).toInt();
    final colors = Theme.of(context).colorScheme;
    final pages = [
      TodayPage(snapshot: data),
      FocusPage(snapshot: data),
      ThoughtsPage(snapshot: data),
      ProgressPage(snapshot: data),
      SettingsPage(snapshot: data),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.spa_outlined, size: 23, color: colors.primary),
          const SizedBox(width: 9),
          Text('MULA', style: TextStyle(letterSpacing: 4, fontSize: 17, fontWeight: FontWeight.w700, color: colors.primary)),
        ]),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Chip(
              avatar: Icon(theme.sanctuary ? Icons.favorite_outline_rounded : Icons.wb_twilight_rounded, size: 16),
              label: Text(theme.sanctuary ? 'Ruang tenang' : theme.periodLabel),
              labelStyle: const TextStyle(fontSize: 12),
              side: BorderSide.none,
              backgroundColor: colors.primaryContainer.withValues(alpha: .5),
            ),
          ),
        ],
      ),
      body: Column(children: [
        if (theme.sanctuary)
          Material(
            color: colors.primaryContainer.withValues(alpha: .55),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(children: [
                const Expanded(child: Text('Pelan saja. Satu langkah kecil sudah cukup.', style: TextStyle(fontSize: 13))),
                TextButton(onPressed: saving ? null : () => perform(actions.exitSanctuary), child: const Text('Kembali')),
              ]),
            ),
          ),
        if (saving) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: SafeArea(top: false, bottom: false, child: Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: pages[selected]),
        ))),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (index) {
          if (index != selected) perform(() => actions.setSelectedTab(index));
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), selectedIcon: Icon(Icons.wb_sunny_rounded), label: 'Hari Ini'),
          NavigationDestination(icon: Icon(Icons.timelapse_outlined), selectedIcon: Icon(Icons.timelapse_rounded), label: 'Fokus'),
          NavigationDestination(icon: Icon(Icons.cloud_outlined), selectedIcon: Icon(Icons.cloud_rounded), label: 'Pikiran'),
          NavigationDestination(icon: Icon(Icons.eco_outlined), selectedIcon: Icon(Icons.eco_rounded), label: 'Progres'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Pengaturan'),
        ],
      ),
    );
  }
}
