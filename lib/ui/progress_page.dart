import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_snapshot.dart';
import '../features/wellbeing/presentation/history_panel.dart';
import 'widgets/mula_seed.dart';
import 'widgets/shared.dart';

class ProgressPage extends ConsumerStatefulWidget {
  const ProgressPage({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends ConsumerState<ProgressPage> with PersistedActions<ProgressPage> {
  Future<void> _reflection() async {
    final draft = await showDialog<_ReflectionDraft>(context: context, builder: (_) => _ReflectionDialog(score: widget.snapshot.score));
    if (draft != null && mounted) await perform(() => actions.saveReflection(moodScore: draft.mood, anxietyScore: draft.anxiety, notes: draft.notes, gratitudeNote: draft.gratitude, firstStepTomorrow: draft.tomorrow), success: 'Refleksi tersimpan. Besok boleh mulai kecil lagi.');
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final colors = Theme.of(context).colorScheme;
    final score = data.score;
    final total = score.number('totalScore');
    final seed = MulaSeed(score: total, size: 154);
    final history = data.history.take(7).toList().reversed.toList();
    return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
      const PageTitle(title: 'Tumbuh dengan\nritmemu sendiri.', subtitle: 'Kemajuanmu adalah kumpulan langkah kecil.'),
      MulaCard(color: colors.primaryContainer.withValues(alpha: .3), child: Column(children: [
        seed,
        Text(seed.stage, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text('$total / 100 poin hari ini', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colors.primary)),
        const SizedBox(height: 12),
        const Text('Skor dihitung otomatis dari rutinitas, tugas, dan waktu fokus yang benar-benar dijalani.', textAlign: TextAlign.center, style: TextStyle(height: 1.6, fontSize: 13)),
      ])),
      const SizedBox(height: 22),
      Text('Keseimbangan hari ini', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      MulaCard(child: Column(children: [
        _ScoreLine(label: 'Aktivasi pagi', score: score.number('morningScore'), maximum: 20, icon: Icons.wb_sunny_outlined),
        const SizedBox(height: 18),
        _ScoreLine(label: 'Kerja & prioritas', score: score.number('workScore'), maximum: 35, icon: Icons.work_outline_rounded),
        const SizedBox(height: 18),
        _ScoreLine(label: 'Kesehatan & keluarga', score: score.number('healthFamilyScore'), maximum: 25, icon: Icons.favorite_outline_rounded),
        const SizedBox(height: 18),
        _ScoreLine(label: 'Side job & penutupan', score: score.number('sideJobScore'), maximum: 20, icon: Icons.nightlight_outlined),
      ])),
      const SizedBox(height: 24),
      Text('Jejak pertumbuhan', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      if (history.isEmpty)
        const EmptyState(icon: Icons.eco_outlined, title: 'Jejakmu dimulai hari ini.', message: 'Progres harian akan terkumpul di sini saat kamu kembali ke sistem.')
      else
        MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${history.length} hari tersimpan', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
          const SizedBox(height: 18),
          SizedBox(height: 158, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: history.map((day) {
            final value = day.number('totalScore').clamp(0, 100).toInt();
            final date = DateTime.tryParse(day.text('date'));
            final isToday = day.text('date') == data.date;
            return Expanded(child: Semantics(label: '${day.text('date')}: $value poin', child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text('$value', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
                const SizedBox(height: 6),
                Container(height: 8 + value * .95, constraints: const BoxConstraints(maxWidth: 36), decoration: BoxDecoration(color: isToday ? colors.primary : colors.primary.withValues(alpha: .25), borderRadius: BorderRadius.circular(8))),
                const SizedBox(height: 10),
                Text(date == null ? '–' : '${date.day}/${date.month}', style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant)),
              ]),
            )));
          }).toList())),
        ])),
      const SizedBox(height: 24),
      HistoryPanel(snapshot: data),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: Text('Singgah & refleksi', style: Theme.of(context).textTheme.titleLarge)),
        TextButton.icon(onPressed: saving ? null : _reflection, icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('Tulis')),
      ]),
      const SizedBox(height: 12),
      MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.sentiment_satisfied_alt_rounded, color: colors.primary, size: 21),
          const SizedBox(width: 8),
          Expanded(child: Text('Suasana hati ${score.number('moodScore', 5)}/10', style: const TextStyle(fontSize: 13))),
          Text('Cemas ${score.number('anxietyScore', 5)}/10', style: const TextStyle(fontSize: 13)),
        ]),
        const SizedBox(height: 16),
        if (score.text('notes').isNotEmpty) ...[
          Text(score.text('notes'), style: const TextStyle(height: 1.6)),
          const SizedBox(height: 14),
        ] else ...[
          const Text('Apa yang berjalan baik? Apa yang terasa berat? Beri dirimu satu menit untuk didengar.', style: TextStyle(height: 1.6)),
          const SizedBox(height: 14),
        ],
        if (score.text('gratitudeNote').isNotEmpty) ...[
          Text('Yang disyukuri', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.primary)),
          const SizedBox(height: 5),
          Text(score.text('gratitudeNote'), style: const TextStyle(height: 1.5)),
          const SizedBox(height: 14),
        ],
        if (score.text('firstStepTomorrow').isNotEmpty) ...[
          Text('Langkah pertama besok', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.primary)),
          const SizedBox(height: 5),
          Text(score.text('firstStepTomorrow'), style: const TextStyle(height: 1.5)),
        ],
      ])),
    ]);
  }
}

class _ScoreLine extends StatelessWidget {
  const _ScoreLine({required this.label, required this.score, required this.maximum, required this.icon});
  final String label;
  final int score;
  final int maximum;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(children: [
      Row(children: [
        Icon(icon, size: 19, color: colors.primary),
        const SizedBox(width: 9),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
        Text('$score / $maximum', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      ]),
      const SizedBox(height: 9),
      ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: (score / maximum).clamp(0, 1).toDouble(), minHeight: 5, backgroundColor: colors.primary.withValues(alpha: .1))),
    ]);
  }
}

class _ReflectionDraft {
  const _ReflectionDraft(this.mood, this.anxiety, this.notes, this.gratitude, this.tomorrow);
  final int mood;
  final int anxiety;
  final String notes;
  final String gratitude;
  final String tomorrow;
}

class _ReflectionDialog extends StatefulWidget {
  const _ReflectionDialog({required this.score});
  final DbRow score;
  @override
  State<_ReflectionDialog> createState() => _ReflectionDialogState();
}

class _ReflectionDialogState extends State<_ReflectionDialog> {
  late final TextEditingController _notes;
  late final TextEditingController _gratitude;
  late final TextEditingController _tomorrow;
  late double _mood;
  late double _anxiety;

  @override
  void initState() {
    super.initState();
    _notes = TextEditingController(text: widget.score.text('notes'));
    _gratitude = TextEditingController(text: widget.score.text('gratitudeNote'));
    _tomorrow = TextEditingController(text: widget.score.text('firstStepTomorrow'));
    _mood = widget.score.number('moodScore', 5).clamp(1, 10).toDouble();
    _anxiety = widget.score.number('anxietyScore', 5).clamp(1, 10).toDouble();
  }

  @override
  void dispose() {
    _notes.dispose();
    _gratitude.dispose();
    _tomorrow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Dengarkan harimu'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Suasana hati · ${_mood.round()}/10'),
      Slider(value: _mood, min: 1, max: 10, divisions: 9, label: '${_mood.round()}', onChanged: (value) => setState(() => _mood = value)),
      Text('Tingkat cemas · ${_anxiety.round()}/10'),
      Slider(value: _anxiety, min: 1, max: 10, divisions: 9, label: '${_anxiety.round()}', onChanged: (value) => setState(() => _anxiety = value)),
      const SizedBox(height: 10),
      TextField(controller: _notes, minLines: 3, maxLines: 6, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Hasil hari ini & hambatan')),
      const SizedBox(height: 16),
      TextField(controller: _gratitude, minLines: 2, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Satu hal yang disyukuri')),
      const SizedBox(height: 16),
      TextField(controller: _tomorrow, minLines: 2, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Langkah kecil pertama besok')),
    ]))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
      FilledButton(onPressed: () => Navigator.pop(context, _ReflectionDraft(_mood.round(), _anxiety.round(), _notes.text.trim(), _gratitude.text.trim(), _tomorrow.text.trim())), child: const Text('Simpan refleksi')),
    ],
  );
}
