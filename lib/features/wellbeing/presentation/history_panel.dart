import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/wellbeing_repository.dart';
import '../../../domain/app_snapshot.dart';
import '../../../ui/widgets/shared.dart';
import '../application/wellbeing_providers.dart';

class HistoryPanel extends ConsumerStatefulWidget {
  const HistoryPanel({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends ConsumerState<HistoryPanel>
    with PersistedActions<HistoryPanel> {
  static const _months = ['Januari', 'Februari', 'Maret', 'April', 'Mei',
    'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];

  DateTime _month() {
    final saved = widget.snapshot.preferences['historyMonth'] ?? '';
    final parsed = RegExp(r'^\d{4}-\d{2}$').hasMatch(saved)
        ? DateTime.tryParse('$saved-01') : null;
    final date = parsed ?? DateTime.parse(widget.snapshot.date);
    return DateTime(date.year, date.month);
  }

  String _monthKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

  Future<void> _moveMonth(DateTime month, int offset) => perform(() =>
      actions.savePreference('historyMonth',
        _monthKey(DateTime(month.year, month.month + offset))));

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final month = _month();
    final monthKey = _monthKey(month);
    final selectedSaved = snapshot.preferences['historyDay'] ?? snapshot.date;
    final selected = DateTime.tryParse(selectedSaved) == null ? snapshot.date : selectedSaved;
    final weekly = ref.watch(historyWeekProvider(snapshot.date));
    final monthly = ref.watch(historyMonthProvider(monthKey));
    final details = ref.watch(historyDayProvider(selected));
    final colors = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Tujuh hari terakhir', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      _asyncCard<HistoryRange>(weekly, (value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${value.totalFocusSeconds ~/ 60} menit fokus tercatat',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Text('Rata-rata ${value.averageScore}/100 · ${value.scores.length} hari memiliki catatan.'),
          const SizedBox(height: 10),
          const Text('Total memakai durasi sesi yang sudah disimpan. Waktu yang bertumpuk dihitung satu kali.',
              style: TextStyle(fontSize: 12, height: 1.6)),
        ]), () => ref.invalidate(historyWeekProvider(snapshot.date))),
      const SizedBox(height: 24),
      Text('Kalender & riwayat harian', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      MulaCard(child: Column(children: [
        Row(children: [
          IconButton(onPressed: saving ? null : () => _moveMonth(month, -1),
            tooltip: 'Bulan sebelumnya', icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Text('${_months[month.month - 1]} ${month.year}',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(onPressed: saving ? null : () => _moveMonth(month, 1),
            tooltip: 'Bulan berikutnya', icon: const Icon(Icons.chevron_right_rounded)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (final label in ['S', 'S', 'R', 'K', 'J', 'S', 'M'])
            Expanded(child: Center(child: Text(label, style: const TextStyle(fontSize: 11)))),
        ]),
        const SizedBox(height: 8),
        monthly.when(
          loading: () => const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()),
          error: (error, stack) => Column(children: [
            Text('Kalender belum dapat dibuka: $error'),
            TextButton(onPressed: () => ref.invalidate(historyMonthProvider(monthKey)),
                child: const Text('Buka ulang kalender')),
          ]),
          data: (value) {
            final scores = {for (final row in value.scores) row.text('date'): row.number('totalScore')};
            final offset = month.weekday - 1;
            final count = DateTime(month.year, month.month + 1, 0).day;
            return GridView.builder(
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7, mainAxisSpacing: 4, crossAxisSpacing: 2,
                childAspectRatio: .78),
              itemCount: offset + count,
              itemBuilder: (context, index) {
                if (index < offset) return const SizedBox.shrink();
                final day = index - offset + 1;
                final key = WellbeingRepository.dateKey(DateTime(month.year, month.month, day));
                final savedScore = scores[key];
                return Semantics(
                  label: '$key: ${savedScore == null ? 'belum ada catatan' : '$savedScore poin'}',
                  selected: selected == key,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: saving ? null : () => perform(() => actions.savePreference('historyDay', key)),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: selected == key ? colors.primaryContainer : null,
                        border: key == snapshot.date ? Border.all(color: colors.primary) : null,
                      ),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('$day', style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 3),
                        Text(savedScore == null ? '·' : '$savedScore',
                            style: TextStyle(fontSize: 10, color: colors.primary)),
                      ]),
                    ),
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 10),
        const Text('Angka kecil menunjukkan skor tersimpan. Membuka riwayat tidak mengubah progres.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, height: 1.5)),
      ])),
      const SizedBox(height: 14),
      _asyncCard<HistoryDay>(details, (value) => _dayDetails(context, value),
          () => ref.invalidate(historyDayProvider(selected))),
    ]);
  }

  Widget _asyncCard<T>(AsyncValue<T> value, Widget Function(T) builder, VoidCallback retry) =>
      MulaCard(child: value.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Riwayat belum dapat dibuka: $error'),
          TextButton(onPressed: retry, child: const Text('Buka ulang riwayat')),
        ]),
        data: builder,
      ));

  Widget _dayDetails(BuildContext context, HistoryDay day) {
    final score = day.score;
    final minimum = score?.text('dayMode') == 'Minimum';
    final tasks = day.tasks.where((task) =>
        minimum ? task.text('minimumKey').isNotEmpty : task.text('minimumKey').isEmpty).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(day.date, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      if (score == null) const Text('Belum ada catatan untuk tanggal ini.')
      else ...[
        Text('${score.number('totalScore')}/100 · Mode ${score.text('dayMode')}'),
        const SizedBox(height: 8),
        Text('Fokus tersimpan ${day.focusSeconds ~/ 60} menit · '
            '${tasks.where((task) => task.text('status') == 'Selesai').length}/${tasks.length} tugas selesai'),
        if (score.text('adaptationReason').isNotEmpty) ...[
          const SizedBox(height: 8), Text('Alasan adaptasi: ${score.text('adaptationReason')}'),
        ],
        const SizedBox(height: 16),
        Text('Suasana hati ${score.number('moodScore', 5)}/10 · Cemas ${score.number('anxietyScore', 5)}/10'),
        for (final field in <String, String>{
          'notes': 'Refleksi', 'gratitudeNote': 'Yang disyukuri',
          'firstStepTomorrow': 'Langkah pertama besok',
        }.entries)
          if (score.text(field.key).isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(field.value, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(score.text(field.key), style: const TextStyle(height: 1.6)),
          ],
      ],
      if (tasks.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text('Tugas tersimpan', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        for (final task in tasks) Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(task.text('status') == 'Selesai' ? Icons.check_circle_outline : Icons.circle_outlined,
                size: 17),
            const SizedBox(width: 8),
            Expanded(child: Text('${task.text('title')} · ${task.text('status')}',
                style: const TextStyle(fontSize: 12, height: 1.5))),
          ]),
        ),
      ],
      if (day.anxietySessions.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text('Sesi tenang', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        for (final session in day.anxietySessions)
          Text('${session.text('mode')} · ${session.number('anxietyBefore')} → '
              '${session.number('anxietyAfter')}/10 · ${session.number('durationSeconds')} detik',
              style: const TextStyle(fontSize: 12, height: 1.6)),
      ],
    ]);
  }
}
