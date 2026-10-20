import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';
import '../theme/circadian_theme.dart';
import 'widgets/mula_seed.dart';
import 'widgets/shared.dart';

class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage> with PersistedActions<TodayPage> {
  Future<void> _addTask() async {
    final draft = await showDialog<_TaskDraft>(context: context, builder: (_) => const _AddTaskDialog());
    if (draft != null && mounted) {
      await perform(() => actions.addTask(title: draft.title, category: draft.category, priority: draft.priority, estimatedMinutes: draft.minutes));
    }
  }

  Future<void> _changeMode() async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sesuaikan harimu', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...const {
            'Normal': 'Jalani ritme yang sudah disiapkan.',
            'Minimum': 'Cukup kebutuhan dasar dan satu langkah kecil.',
            'Adaptasi': 'Sesuaikan langkah dengan keadaan hari ini.',
            'Reset24Jam': 'Beri diri ruang untuk memulai kembali.',
          }.entries.map((entry) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.key == 'Reset24Jam' ? 'Reset 24 jam' : entry.key),
            subtitle: Text(entry.value),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.pop(sheetContext, entry.key),
          )),
        ]),
      )),
    );
    if (mode == null || !mounted) return;
    String? reason;
    if (mode != 'Normal') {
      reason = await askText(context, title: 'Apa yang perlu diberi ruang?', label: 'Alasan penyesuaian', lines: 2);
      if (reason == null || !mounted) return;
    }
    await perform(() async {
      await actions.setDayMode(mode, reason: reason);
    });
  }

  Future<void> _taskAction(DbRow task, String action) async {
    final id = task.number('id');
    if (action == 'focus') {
      await perform(() async {
        if (widget.snapshot.activeFocus == null) {
          await actions.startFocus(taskId: id, plannedSeconds: 3000, mode: 'Deep Work');
        }
        await actions.setSelectedTab(1);
      });
    } else if (action == 'override') {
      final project = await askText(context, title: 'Prioritaskan deadline', label: 'Proyek yang dikerjakan', initial: task.text('title'), lines: 2);
      if (project != null && mounted) await perform(() => actions.overrideProject(taskId: id, project: project));
    } else {
      String? reason;
      if (action == 'Dilewati' || action == 'Ditunda') {
        reason = await askText(context, title: action == 'Dilewati' ? 'Lewati dengan sadar' : 'Tunda tugas', label: 'Apa alasannya?', lines: 2);
        if (reason == null || !mounted) return;
      }
      await perform(() => actions.setTaskStatus(id, action, reason: reason));
    }
  }

  DbRow? _template(DbRow task) {
    for (final template in widget.snapshot.templates) {
      if (template.number('id') == task.number('sourceScheduleId', -1)) return template;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final colors = Theme.of(context).colorScheme;
    final theme = ref.watch(circadianThemeProvider);
    final now = ref.watch(clockProvider);
    final completed = data.tasks.where((task) => task.text('status') == 'Selesai').length;
    final total = data.score.number('totalScore');
    final seed = MulaSeed(score: total, size: 100);
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
      children: [
        Text(displayDate(data.date.toString()).toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.5, color: colors.onSurfaceVariant)),
        const SizedBox(height: 10),
        PageTitle(title: theme.greeting.replaceFirst(', ', ',\n'), subtitle: theme.atmosphere),
        MulaCard(
          color: colors.primaryContainer.withValues(alpha: .45),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SETIAP LANGKAH BERARTI', style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1, color: colors.primary)),
              const SizedBox(height: 10),
              RichText(text: TextSpan(style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w600), children: [
                TextSpan(text: '$total'),
                TextSpan(text: ' / 100', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: colors.onSurfaceVariant)),
              ])),
              const SizedBox(height: 5),
              Text('${seed.stage} · $completed dari ${data.tasks.length} blok selesai', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: (total / 100).clamp(0, 1).toDouble(), minHeight: 5, backgroundColor: colors.primary.withValues(alpha: .1))),
            ])),
            seed,
          ]),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: Text('Bagaimana rasanya hari ini?', style: Theme.of(context).textTheme.titleSmall)),
          TextButton.icon(onPressed: saving ? null : _changeMode, icon: const Icon(Icons.tune_rounded, size: 16), label: Text(data.score.text('dayMode', 'Normal'))),
        ]),
        Wrap(spacing: 8, runSpacing: 6, children: [
          ActionChip(avatar: const Icon(Icons.air_rounded, size: 17), label: const Text('Cemas'), onPressed: saving ? null : () => perform(() => actions.enterSanctuary('Cemas'))),
          ActionChip(avatar: const Icon(Icons.restart_alt_rounded, size: 17), label: const Text('Stuck'), onPressed: saving ? null : () => perform(() => actions.enterSanctuary('Stuck'))),
          ActionChip(avatar: const Icon(Icons.favorite_border_rounded, size: 17), label: const Text('Hari buruk'), onPressed: saving ? null : () => perform(() async {
            await actions.enterSanctuary('Mode Hari Buruk');
          })),
        ]),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: Text('Ritme hari ini', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))),
          TextButton.icon(onPressed: saving ? null : _addTask, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Tugas')),
        ]),
        const SizedBox(height: 12),
        if (data.tasks.isEmpty) const EmptyState(icon: Icons.wb_sunny_outlined, title: 'Hari baru, ruang baru.', message: 'Tambahkan tugas pertamamu untuk mulai melangkah.'),
        ...data.tasks.map((task) {
          final template = _template(task);
          final start = template?.text('startTime') ?? '';
          final end = template?.text('endTime') ?? '';
          final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final current = start.isNotEmpty && currentTime.compareTo(start) >= 0 && currentTime.compareTo(end) < 0;
          final done = task.text('status') == 'Selesai';
          final checklist = readChecklist(task);
          final canOverride = start == '13:00' || start == '20:00' || start == '20:45';
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MulaCard(
              padding: EdgeInsets.zero,
              color: current ? colors.primaryContainer.withValues(alpha: .35) : null,
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: PageStorageKey('task-${task.number('id')}'),
                  tilePadding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  leading: Checkbox(
                    value: done,
                    shape: const CircleBorder(),
                    onChanged: saving ? null : (value) => perform(() => actions.setTaskStatus(task.number('id'), value == true ? 'Selesai' : 'Belum mulai')),
                  ),
                  title: Text(task.text('title'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, decoration: done ? TextDecoration.lineThrough : null, color: done ? colors.onSurfaceVariant : colors.onSurface)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${start.isEmpty ? '${task.number('estimatedMinutes')} menit' : '$start – $end'}${current ? ' · Sekarang' : ''}\n${task.text('priority', 'Reguler')} · ${task.text('status', 'Belum mulai')}', style: TextStyle(fontSize: 12, height: 1.6, color: current ? colors.primary : colors.onSurfaceVariant)),
                  ),
                  children: [
                    if (task.text('description').isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 12), child: Align(alignment: Alignment.centerLeft, child: Text(task.text('description'), style: const TextStyle(height: 1.5)))),
                    ...checklist.asMap().entries.map((entry) => CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: entry.value.flag('done'),
                      title: Text(entry.value.text('title', entry.value.text('text')), style: const TextStyle(fontSize: 13, height: 1.4)),
                      onChanged: saving ? null : (value) => perform(() => actions.setChecklistItem(task.number('id'), entry.key, value ?? false)),
                    )),
                    if (task.text('skippedReason').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Catatan: ${task.text('skippedReason')}', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))),
                    const SizedBox(height: 8),
                    Row(children: [
                      FilledButton.tonalIcon(onPressed: saving ? null : () => _taskAction(task, 'focus'), icon: const Icon(Icons.play_arrow_rounded, size: 18), label: const Text('Fokus')),
                      const Spacer(),
                      PopupMenuButton<String>(
                        enabled: !saving,
                        tooltip: 'Atur tugas',
                        onSelected: (value) => _taskAction(task, value),
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'Sedang berjalan', child: Text('Mulai mengerjakan')),
                          const PopupMenuItem(value: 'Selesai', child: Text('Tandai selesai')),
                          const PopupMenuItem(value: 'Belum mulai', child: Text('Kembalikan ke belum mulai')),
                          const PopupMenuItem(value: 'Ditunda', child: Text('Tunda tugas')),
                          const PopupMenuItem(value: 'Dilewati', child: Text('Lewati dengan alasan')),
                          if (canOverride) const PopupMenuItem(value: 'override', child: Text('Override proyek / deadline')),
                        ],
                        child: const Padding(padding: EdgeInsets.all(10), child: Row(children: [Text('Atur'), SizedBox(width: 4), Icon(Icons.more_horiz_rounded, size: 18)])),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        Text('Tidak harus sempurna. Cukup kembali pada blok berikutnya.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6, color: colors.onSurfaceVariant)),
      ],
    );
  }
}

class _TaskDraft {
  const _TaskDraft(this.title, this.category, this.priority, this.minutes);
  final String title;
  final String category;
  final String priority;
  final int minutes;
}

class _AddTaskDialog extends StatefulWidget {
  const _AddTaskDialog();
  @override
  State<_AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<_AddTaskDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _minutes = TextEditingController(text: '25');
  String _category = 'Pribadi';
  String _priority = 'Reguler';

  @override
  void dispose() {
    _title.dispose();
    _minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Satu langkah baru'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextFormField(controller: _title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Apa yang ingin dikerjakan?'), validator: (value) => value == null || value.trim().isEmpty ? 'Isi judul tugas.' : null),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(initialValue: _category, isExpanded: true, decoration: const InputDecoration(labelText: 'Kategori'), items: ['Wajib', 'Penting', 'Jika Sempat', 'Rutinitas', 'Tim', 'Pribadi', 'Side Job'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(), onChanged: (value) => setState(() => _category = value ?? _category)),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(initialValue: _priority, decoration: const InputDecoration(labelText: 'Prioritas'), items: ['Top 1', 'Top 2', 'Top 3', 'Reguler'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(), onChanged: (value) => setState(() => _priority = value ?? _priority)),
      const SizedBox(height: 16),
      TextFormField(controller: _minutes, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Perkiraan durasi', suffixText: 'menit'), validator: (value) {
        final minutes = int.tryParse(value ?? '');
        return minutes == null || minutes < 1 || minutes > 1440 ? 'Gunakan 1–1440 menit.' : null;
      }),
    ])))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
      FilledButton(onPressed: () {
        if (_form.currentState!.validate()) Navigator.pop(context, _TaskDraft(_title.text.trim(), _category, _priority, int.parse(_minutes.text)));
      }, child: const Text('Tambah tugas')),
    ],
  );
}
