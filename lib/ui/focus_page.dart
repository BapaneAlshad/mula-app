import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';
import '../domain/focus_clock.dart';
import 'widgets/shared.dart';

class FocusPage extends ConsumerStatefulWidget {
  const FocusPage({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends ConsumerState<FocusPage> with PersistedActions<FocusPage> {
  String _duration(int seconds) {
    final value = seconds < 0 ? 0 : seconds;
    return '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _cancel() async {
    final reason = await askText(context, title: 'Akhiri sesi lebih awal', label: 'Apa yang perlu kamu tangani?', confirm: 'Akhiri sesi', lines: 2);
    if (reason != null && mounted) await perform(() => actions.finishFocus(cancel: true, reason: reason));
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final colors = Theme.of(context).colorScheme;
    final now = ref.watch(clockProvider);
    final session = data.activeFocus;
    final planned = session?.number('plannedSeconds', 3000) ?? int.tryParse(data.preferences['focusDuration'] ?? '3000') ?? 3000;
    final startedAt = DateTime.tryParse(session?.text('startedAt') ?? '');
    final focusClock = startedAt == null ? null : FocusClock(startedAt: startedAt, plannedSeconds: planned);
    final elapsed = focusClock?.elapsedAt(now) ?? 0;
    final remaining = focusClock?.remainingAt(now) ?? planned;
    final taskOptions = data.tasks.where((task) => !['Selesai', 'Dilewati'].contains(task.text('status'))).toList();
    final preferenceTask = int.tryParse(data.preferences['focusTaskId'] ?? '0') ?? 0;
    final selectedTask = taskOptions.any((task) => task.number('id') == preferenceTask) ? preferenceTask : 0;
    final activeTask = data.tasks.where((task) => task.number('id') == (session?.number('taskId', -1) ?? -1));
    return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
      const PageTitle(title: 'Satu hal.\nSepenuh hadir.', subtitle: 'Beri ruang untuk tugas yang ada di depanmu.'),
      MulaCard(
        color: colors.primaryContainer.withValues(alpha: .3),
        child: Column(children: [
          Text(session == null ? 'RUANG FOKUS' : 'SESI SEDANG BERJALAN', style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.7, color: colors.primary)),
          const SizedBox(height: 26),
          SizedBox.square(dimension: 232, child: Stack(alignment: Alignment.center, children: [
            SizedBox.square(dimension: 224, child: CircularProgressIndicator(value: session == null ? 0 : (elapsed / planned).clamp(0, 1).toDouble(), strokeWidth: 6, backgroundColor: colors.primary.withValues(alpha: .12), strokeCap: StrokeCap.round)),
            Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_duration(session == null ? planned : remaining), style: Theme.of(context).textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w300, fontSize: 54, letterSpacing: -1.5)),
              const SizedBox(height: 5),
              Text(session == null ? 'siap ketika kamu siap' : remaining == 0 ? 'durasi tercapai ✦' : 'kembali ke satu hal', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            ]),
          ])),
          const SizedBox(height: 24),
          if (session != null) ...[
            Text(activeTask.isEmpty ? 'Fokus mandiri' : activeTask.first.text('title'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${session.text('mode')} · berjalan ${_duration(elapsed)}', style: TextStyle(color: colors.onSurfaceVariant)),
            const SizedBox(height: 22),
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: saving ? null : () => perform(() => actions.finishFocus(), success: 'Sesi tersimpan. Terima kasih sudah hadir.'), icon: const Icon(Icons.check_rounded), label: const Text('Selesaikan & simpan sesi'))),
            TextButton(onPressed: saving ? null : _cancel, child: const Text('Akhiri lebih awal')),
          ] else ...[
            Wrap(alignment: WrapAlignment.center, spacing: 8, children: [5, 25, 50].map((minutes) => ChoiceChip(
              label: Text('$minutes menit'),
              selected: planned == minutes * 60,
              onSelected: saving ? null : (_) => perform(() => actions.savePreference('focusDuration', '${minutes * 60}')),
            )).toList()),
            const SizedBox(height: 20),
            DropdownButtonFormField<int>(
              key: ValueKey('focusTask-$selectedTask-${taskOptions.length}'),
              initialValue: selectedTask,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Fokus untuk'),
              items: [
                const DropdownMenuItem(value: 0, child: Text('Fokus mandiri')),
                ...taskOptions.map((task) => DropdownMenuItem(value: task.number('id'), child: Text(task.text('title'), overflow: TextOverflow.ellipsis))),
              ],
              onChanged: saving ? null : (id) => perform(() => actions.savePreference('focusTaskId', '${id ?? 0}')),
            ),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: saving ? null : () => perform(() => actions.startFocus(taskId: selectedTask == 0 ? null : selectedTask, plannedSeconds: planned, mode: planned <= 300 ? 'Langkah kecil' : 'Deep Work')),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Mulai fokus'),
            )),
          ],
        ]),
      ),
      const SizedBox(height: 18),
      if ((data.preferences['reminderStatus'] ?? '').isNotEmpty) ...[
        Text(data.preferences['reminderStatus']!, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant, height: 1.5)),
        const SizedBox(height: 18),
      ],
      MulaCard(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.spa_outlined, color: colors.primary, size: 24),
        const SizedBox(width: 14),
        const Expanded(child: Text('Simpan HP dan mulai dari tindakan paling kecil. Timer tetap menghitung saat layar mati. Setelah sesi, ambil jeda tanpa scrolling.', style: TextStyle(height: 1.6, fontSize: 13))),
      ])),
    ]);
  }
}
