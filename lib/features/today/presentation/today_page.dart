import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/app_controller.dart';
import '../../../domain/app_snapshot.dart';
import '../../../theme/circadian_theme.dart';
import '../../../ui/widgets/mula_seed.dart';
import '../../../ui/widgets/shared.dart';
import '../../tasks/presentation/task_card.dart';
import '../../tasks/presentation/task_editor.dart';

/// Today's rhythm is backed by persisted tasks, sessions, and daily scores.
class TodayPage extends ConsumerStatefulWidget {
  const TodayPage({super.key, required this.snapshot});

  final AppSnapshot snapshot;

  @override
  ConsumerState<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends ConsumerState<TodayPage>
    with PersistedActions<TodayPage> {
  static const _adaptationReasons = [
    'Sakit',
    'Kondisi keluarga',
    'Tugas darurat',
    'Kelelahan berat',
    'Perjalanan',
    'Acara/kewajiban penting',
  ];

  AppSnapshot get data => widget.snapshot;

  Future<void> _selectMode(String mode) async {
    if (saving) return;
    String? reason;
    if (mode == 'Adaptasi') {
      reason = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Beri ruang untuk keadaan hari ini',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Pilih alasan adaptasi. Konsekuensi harian dinonaktifkan '
                  'dan streak tetap terjaga.',
                ),
                const SizedBox(height: 12),
                ..._adaptationReasons.map((value) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(value),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(sheetContext, value),
                    )),
              ],
            ),
          ),
        ),
      );
      if (reason == null || !mounted) return;
    }
    await perform(() => actions.setDayMode(mode, reason: reason));
  }

  Future<void> _parkThought() async {
    final content = await askText(
      context,
      title: 'Parkir pikiran',
      label: 'Apa yang sedang memenuhi kepala?',
      confirm: 'Parkir & kembali',
    );
    if (content == null || !mounted) return;
    await perform(
      () => actions.addThought(
        content: content,
        type: 'Kekhawatiran',
        intensity: data.score.number('anxietyScore', 5),
        needsAction: false,
        nextAction: '',
      ),
      success: 'Pikiran tersimpan. Kamu boleh kembali ke satu langkah kecil.',
    );
  }

  Future<void> _startFiveMinutes() => perform(() async {
        await actions.startFiveMinutes();
        await actions.setSelectedTab(1);
      });

  Future<void> _choosePriority(String priority) async {
    final minimumIds = data.minimumTasks.map((task) => task.number('id')).toSet();
    final candidates = data.tasks
        .where((task) => !minimumIds.contains(task.number('id')))
        .toList();
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Text('Pilih $priority',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('Buat tugas baru'),
                subtitle: Text('Simpan langsung sebagai $priority'),
                onTap: () => Navigator.pop(sheetContext, 'new'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (_, index) {
                    final task = candidates[index];
                    return ListTile(
                      title: Text(task.text('title')),
                      subtitle: Text(
                        '${task.text('category')} · '
                        '${task.number('estimatedMinutes')} menit · '
                        '${task.text('priority', 'Reguler')}',
                      ),
                      trailing: task.text('priority') == priority
                          ? const Icon(Icons.check_circle_outline_rounded)
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(sheetContext, task),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'new') {
      await showTaskEditor(context, ref, initialPriority: priority);
    } else if (choice is DbRow) {
      await perform(() => actions.assignPriority(choice.number('id'), priority));
    }
  }

  DbRow? _priorityTask(String priority) {
    for (final task in data.tasks) {
      if (task.text('priority') == priority) return task;
    }
    return null;
  }

  DbRow? _template(DbRow task) {
    for (final template in data.templates) {
      if (template.number('id') == task.number('sourceScheduleId', -1)) {
        return template;
      }
    }
    return null;
  }

  Future<void> _writeClosingNote(DbRow task) async {
    final note = await askText(
      context,
      title: 'Satu catatan penutupan hari',
      label: 'Apa yang ingin kamu tutup dengan lembut?',
      initial: data.score.text('notes'),
    );
    if (note == null || !mounted) return;
    await perform(() async {
      await actions.saveReflection(
        moodScore: data.score.number('moodScore', 5),
        anxietyScore: data.score.number('anxietyScore', 5),
        notes: note,
        gratitudeNote: data.score.text('gratitudeNote'),
        firstStepTomorrow: data.score.text('firstStepTomorrow'),
      );
      await actions.setTaskStatus(task.number('id'), 'Selesai');
    }, success: 'Catatan penutupan tersimpan. Cukup untuk hari ini.');
  }

  Future<void> _toggleMinimum(DbRow task, int index, bool done) async {
    if (done && index == 5 && data.score.text('notes').trim().isEmpty) {
      await _writeClosingNote(task);
      return;
    }
    await perform(() => actions.setTaskStatus(
          task.number('id'), done ? 'Selesai' : 'Belum mulai',
        ));
  }

  Widget _header(CircadianThemeState atmosphere) {
    final colors = Theme.of(context).colorScheme;
    final score = data.score.number('totalScore');
    final seed = MulaSeed(score: score, size: 108);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          displayDate(data.date).toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.4,
                color: colors.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 10),
        PageTitle(title: atmosphere.greeting, subtitle: atmosphere.atmosphere),
        MulaCard(
          color: colors.primaryContainer.withValues(alpha: .4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SKOR HARI INI',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.3,
                              color: colors.primary,
                            )),
                    const SizedBox(height: 8),
                    Text('$score/100',
                        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -1,
                            )),
                    const SizedBox(height: 4),
                    Text('MULA Seed · ${seed.stage}',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: (score / 100).clamp(0, 1).toDouble(),
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(8),
                      backgroundColor: colors.primary.withValues(alpha: .1),
                    ),
                    const SizedBox(height: 8),
                    Text('${data.streak} hari kembali ke sistem',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              seed,
            ],
          ),
        ),
      ],
    );
  }

  Widget _modePicker() {
    final mode = data.score.text('dayMode', 'Normal');
    final colors = Theme.of(context).colorScheme;
    return MulaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ruang untuk hari ini',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final item in const [
                ('Normal', 'Mode Normal', Icons.wb_sunny_outlined),
                ('Minimum', 'Hari Buruk / Minimum', Icons.spa_outlined),
                ('Adaptasi', 'Hari Adaptasi', Icons.shield_outlined),
              ])
                ChoiceChip(
                  label: Text(item.$2),
                  avatar: Icon(item.$3, size: 17),
                  selected: mode == item.$1,
                  onSelected: saving ? null : (_) => _selectMode(item.$1),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            mode == 'Minimum'
                ? 'Versi minimum: tujuh kebutuhan dasar. Satu langkah pun berarti.'
                : mode == 'Adaptasi'
                    ? 'Alasan: ${data.score.text('adaptationReason')}. '
                        'Konsekuensi dinonaktifkan hari ini; streak tetap terjaga.'
                    : 'Jadwal penuh, dengan ruang untuk kembali pada blok berikutnya.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.5,
                  color: colors.onSurfaceVariant,
                ),
          ),
          if (mode == 'Adaptasi')
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.verified_user_outlined, size: 16),
                  SizedBox(width: 6),
                  Expanded(child: Text('Streak terlindungi · tanpa konsekuensi harian')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _quickActions() => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 340
              ? constraints.maxWidth
              : (constraints.maxWidth - 10) / 2;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _QuickAction(
                width: width,
                icon: Icons.add_rounded,
                label: 'Tambah Tugas',
                onPressed: saving ? null : () => showTaskEditor(context, ref),
              ),
              _QuickAction(
                width: width,
                icon: Icons.play_circle_outline_rounded,
                label: 'Mulai 5 Menit',
                detail: 'Saya sedang stuck',
                onPressed: saving ? null : _startFiveMinutes,
              ),
              _QuickAction(
                width: width,
                icon: Icons.air_rounded,
                label: 'Saya sedang cemas',
                onPressed: saving
                    ? null
                    : () => perform(
                          () => actions.enterSanctuary('Cemas'),
                          success: 'Ruang tenang aktif. Tarik napas perlahan.',
                        ),
              ),
              _QuickAction(
                width: width,
                icon: Icons.inventory_2_outlined,
                label: 'Parkir Pikiran',
                onPressed: saving ? null : _parkThought,
              ),
            ],
          );
        },
      );

  Widget _priorities() => MulaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('PRIORITAS HARI INI',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      letterSpacing: 1.3,
                    )),
            const SizedBox(height: 6),
            const Text('Mulai dari Top 1. Langkah lain boleh menunggu.'),
            const SizedBox(height: 16),
            for (var index = 0; index < 3; index++) ...[
              if (index > 0) const Divider(height: 28),
              _prioritySlot(index),
            ],
          ],
        ),
      );

  Widget _prioritySlot(int index) {
    final priority = 'Top ${index + 1}';
    final task = _priorityTask(priority);
    const descriptions = ['Wajib selesai', 'Penting', 'Jika sempat'];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: index == 0
                  ? colors.primaryContainer
                  : colors.surfaceContainerHighest,
              child: Text('${index + 1}',
                  style: TextStyle(color: colors.onSurface, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$priority · ${descriptions[index]}',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            TextButton(
              onPressed: saving ? null : () => _choosePriority(priority),
              child: Text(task == null ? 'Pilih' : 'Ganti'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(task?.text('title') ?? 'Pilih satu tindakan konkret untuk slot ini.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5)),
        if (task != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${task.number('estimatedMinutes')} menit · ${task.text('status')}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (task.text('status') != 'Selesai')
                FilledButton.tonalIcon(
                  onPressed: saving ? null : () => startTaskFocus(context, ref, task),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text('Mulai $priority'),
                )
              else
                const Icon(Icons.check_circle_outline_rounded, size: 20),
            ],
          ),
        ],
      ],
    );
  }

  Widget _minimumChecklist() => MulaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Versi minimum sudah cukup',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('Tidak harus sempurna. Rawat dasar-dasarnya hari ini.'),
            const SizedBox(height: 12),
            ...data.minimumTasks.asMap().entries.map((entry) {
              final task = entry.value;
              final done = task.text('status') == 'Selesai';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(task.text('title')),
                    value: done,
                    onChanged: saving
                        ? null
                        : (value) => _toggleMinimum(task, entry.key, value ?? false),
                  ),
                  if (entry.key == 3 && !done)
                    Padding(
                      padding: const EdgeInsets.only(left: 52, bottom: 8),
                      child: FilledButton.tonalIcon(
                        onPressed: saving
                            ? null
                            : () => startTaskFocus(context, ref, task),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Mulai fokus 25 menit'),
                      ),
                    ),
                  if (entry.key == 5)
                    Padding(
                      padding: const EdgeInsets.only(left: 52, bottom: 8),
                      child: TextButton.icon(
                        onPressed: saving ? null : () => _writeClosingNote(task),
                        icon: const Icon(Icons.edit_note_rounded),
                        label: Text(data.score.text('notes').isEmpty
                            ? 'Tulis satu catatan'
                            : 'Edit catatan penutupan'),
                      ),
                    ),
                ],
              );
            }),
          ],
        ),
      );

  Widget _planningModule(DateTime now) {
    final session = data.planningSession;
    final startedAt = DateTime.tryParse(session?.text('startedAt') ?? '');
    final deadline = DateTime.tryParse(session?.text('deadlineAt') ?? '') ??
        startedAt?.add(const Duration(minutes: 20));
    final cancelled = session?.text('status') == 'Dibatalkan';
    final expired = deadline != null && !now.isBefore(deadline);
    final minute = now.hour * 60 + now.minute;
    final inWindow = minute >= 8 * 60 && minute < 9 * 60 + 30;
    return MulaCard(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: .3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Perencanaan pagi · 08.00–09.30',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (session == null) ...[
            const Text('Susun To-Do List Tim dan Pribadi selama paling lama '
                '20 menit, lalu langsung kerjakan Top 1.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving || !inWindow
                  ? null
                  : () => perform(() => actions.startPlanning()),
              icon: const Icon(Icons.timer_outlined),
              label: const Text('Mulai Susun To-Do List (Batas 20 Menit)'),
            ),
            if (!inWindow)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Tersedia pukul 08.00–09.30.'),
              ),
          ] else if (cancelled) ...[
            const Text('Perencanaan dihentikan ketika Mode Hari Buruk dipilih. '
                'Mulai Top 1 saat kamu siap.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      final task = _priorityTask('Top 1');
                      if (task == null) {
                        await _choosePriority('Top 1');
                      } else {
                        await startTaskFocus(context, ref, task);
                      }
                    },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Kembali ke Top 1'),
            ),
          ] else if (!expired && deadline != null) ...[
            Text(_remaining(deadline, now),
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
            const Text('Sisa waktu menyusun rencana. Pilih Top 1 yang konkret.'),
          ] else ...[
            const Text('Batas 20 menit selesai. Saatnya mengeksekusi Top 1.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () => perform(() => actions.setSelectedTab(1)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Buka sesi Top 1'),
            ),
          ],
          if (!expired) ...[
            const Divider(height: 28),
            _planningList('Tim'),
            const Divider(height: 24),
            _planningList('Pribadi'),
          ],
        ],
      ),
    );
  }

  Widget _planningList(String category) {
    final tasks = data.tasks.where((task) =>
        task.text('category') == category && task['sourceScheduleId'] == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('To-Do List $category',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              tooltip: 'Tambah tugas $category',
              onPressed: saving
                  ? null
                  : () => showTaskEditor(context, ref, initialCategory: category),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        if (tasks.isEmpty)
          Text('Tambahkan satu tindakan yang bisa diukur.',
              style: Theme.of(context).textTheme.bodySmall),
        ...tasks.map((task) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(task.text('status') == 'Selesai'
                  ? Icons.check_circle_outline_rounded
                  : Icons.radio_button_unchecked_rounded),
              title: Text(task.text('title')),
              subtitle: Text('${task.text('priority')} · '
                  '${task.number('estimatedMinutes')} menit'),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: saving ? null : () => showTaskEditor(context, ref, task: task),
            )),
      ],
    );
  }

  Widget _valorantModule(DateTime now) {
    final session = data.valorantSession;
    final open = session != null && session.text('confirmedAt').isEmpty;
    final gate = data.valorantGate;
    final started = DateTime.tryParse(session?.text('startedAt') ?? '');
    final alarm = DateTime.tryParse(session?.text('alarmAt') ?? '') ??
        started?.add(const Duration(minutes: 45));
    final cutoff = DateTime.tryParse(session?.text('cutoffAt') ?? '') ??
        (started == null ? null : DateTime(started.year, started.month, started.day, 13));
    final isLate = open && cutoff != null && now.isAfter(cutoff);
    final consequencesDisabled = data.score.flag('consequencesDisabled');
    final colors = Theme.of(context).colorScheme;
    return MulaCard(
      color: (isLate ? colors.errorContainer : colors.tertiaryContainer)
          .withValues(alpha: .35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_esports_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Main 1 Match VALORANT',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Istirahat siang · 11.45–13.00 · maksimal 1 match'),
          const SizedBox(height: 12),
          if (open) ...[
            if (alarm != null)
              Text(now.isBefore(alarm)
                  ? 'Alarm 45 menit · ${_remaining(alarm, now)}'
                  : 'Alarm 45 menit selesai. Tutup game dan kembali bekerja.'),
            const SizedBox(height: 8),
            Text(
              isLate
                  ? consequencesDisabled
                      ? 'Konsekuensi dinonaktifkan untuk Hari Adaptasi. '
                          'Tutup game dan kembali bekerja.'
                      : 'Batas pukul 13.00 terlewati. Akses VALORANT besok dikunci.'
                  : 'Konfirmasikan game sudah ditutup paling lambat pukul 13.00.',
              style: TextStyle(color: isLate ? colors.error : null, height: 1.5),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () => perform(
                        () => actions.confirmValorantClosed(),
                        success: 'Game ditutup. Selamat kembali ke blok berikutnya.',
                      ),
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text('Game Sudah Ditutup & Kembali Bekerja'),
            ),
          ] else ...[
            _gateCondition(gate.flag('morningAchieved'),
                'Top 1 atau satu sesi fokus pagi tercapai'),
            _gateCondition(!gate.flag('quotaUsed'), 'Kuota 1 match masih tersedia'),
            _gateCondition(!gate.flag('penalty'), 'Tanpa penalti dari hari sebelumnya'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: saving || !gate.flag('allowed')
                  ? null
                  : () => perform(() => actions.startValorant()),
              icon: Icon(gate.flag('allowed')
                  ? Icons.play_arrow_rounded
                  : Icons.lock_outline_rounded),
              label: const Text('Mulai bermain · alarm 45 menit'),
            ),
            if (gate.text('reason').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(gate.text('reason'),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (session != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Match hari ini sudah ditutup dan dikonfirmasi.'),
              ),
          ],
          const SizedBox(height: 10),
          Text('Konfirmasi setelah pukul 13.00 mengunci akses keesokan hari, '
              'kecuali pada Hari Adaptasi dengan konsekuensi dinonaktifkan.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  )),
        ],
      ),
    );
  }

  Widget _gateCondition(bool passed, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          children: [
            Icon(passed ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded,
                size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final atmosphere = ref.watch(circadianThemeProvider);
    final now = ref.watch(clockProvider);
    final minimum = data.score.text('dayMode') == 'Minimum';
    final openGame = data.valorantSession != null &&
        data.valorantSession!.text('confirmedAt').isEmpty;
    final minimumIds = data.minimumTasks.map((task) => task.number('id')).toSet();
    final tasks = data.tasks.where((task) => !minimumIds.contains(task.number('id'))).toList();
    final planningTaskExists = tasks.any((task) => _template(task)?.text('startTime') == '08:00');
    final lunchTaskExists = tasks.any((task) => _template(task)?.text('startTime') == '11:45');
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
      children: [
        _header(atmosphere),
        const SizedBox(height: 16),
        _modePicker(),
        const SizedBox(height: 16),
        _quickActions(),
        if (openGame) ...[
          const SizedBox(height: 18),
          _valorantModule(now),
        ],
        const SizedBox(height: 22),
        if (minimum)
          _minimumChecklist()
        else ...[
          _priorities(),
          const SizedBox(height: 22),
          if (!planningTaskExists || data.planningSession != null) ...[
            _planningModule(now),
            const SizedBox(height: 20),
          ],
          Text('Ritme hari ini',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('Geser kanan untuk selesai. Geser kiri untuk atur status.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (tasks.isEmpty)
            const EmptyState(
              icon: Icons.wb_sunny_outlined,
              title: 'Hari baru, ruang baru.',
              message: 'Gunakan Tambah Tugas untuk menyiapkan langkah pertamamu.',
            ),
          for (final task in tasks) ...[
            TaskCard(
              task: task,
              allowProjectOverride: const ['13:00', '20:00', '20:45']
                  .contains(_template(task)?.text('startTime')),
            ),
            const SizedBox(height: 12),
            if (_template(task)?.text('startTime') == '08:00' &&
                data.planningSession == null) ...[
              _planningModule(now),
              const SizedBox(height: 16),
            ],
            if (_template(task)?.text('startTime') == '11:45' && !openGame) ...[
              _valorantModule(now),
              const SizedBox(height: 16),
            ],
          ],
          if (!lunchTaskExists && !openGame) _valorantModule(now),
        ],
        const SizedBox(height: 22),
        Text(
          'Saya tidak harus sempurna. Saya hanya wajib kembali '
          'ke sistem pada blok berikutnya.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  static String _remaining(DateTime deadline, DateTime now) {
    final seconds = deadline.difference(now).inSeconds.clamp(0, 86400);
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.width,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.detail,
  });

  final double width;
  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label),
                    if (detail != null)
                      Text(detail!, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
