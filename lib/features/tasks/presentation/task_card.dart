import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/app_controller.dart';
import '../../../domain/app_snapshot.dart';
import '../../../ui/widgets/shared.dart';
import 'task_editor.dart';

/// Starts work only after the user has acknowledged any Top 1 reminder.
Future<void> startTaskFocus(
  BuildContext context,
  WidgetRef ref,
  DbRow task, {
  int plannedSeconds = 1500,
}) async {
  final actions = ref.read(appControllerProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (ref.read(appControllerProvider).valueOrNull?.activeFocus != null) {
      await actions.setSelectedTab(1);
      return;
    }
    final permission = await _confirmPriorityStart(context, ref, task);
    if (!permission.allowed || !context.mounted) return;
    await actions.startFocus(
      taskId: task.number('id'),
      plannedSeconds: plannedSeconds,
      mode: 'Fokus tugas',
      allowPriorityOverride: permission.override,
    );
    await actions.setSelectedTab(1);
  } catch (error) {
    if (messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text('Fokus belum dimulai: $error')));
    }
  }
}

class _PriorityPermission {
  const _PriorityPermission(this.allowed, {this.override = false});

  final bool allowed;
  final bool override;
}

Future<_PriorityPermission> _confirmPriorityStart(
  BuildContext context,
  WidgetRef ref,
  DbRow task,
) async {
  if (!{'Top 2', 'Top 3'}.contains(task.text('priority'))) {
    return const _PriorityPermission(true);
  }
  final tasks = ref.read(appControllerProvider).valueOrNull?.tasks ?? <DbRow>[];
  DbRow? top1;
  for (final candidate in tasks) {
    if (candidate.text('priority') == 'Top 1') {
      top1 = candidate;
      break;
    }
  }
  if (top1 != null &&
      (top1.text('startedAt').isNotEmpty ||
          {'Sedang berjalan', 'Selesai'}.contains(top1.text('status')))) {
    return const _PriorityPermission(true);
  }
  final proceed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Beri Top 1 langkah pertama'),
      content: Text(top1 == null
          ? 'Belum ada tugas Top 1. Pilih satu tugas wajib agar energimu punya arah. Tetap mulai ${task.text('priority')} sekarang?'
          : 'Top 1 “${top1.text('title')}” belum dimulai. Coba mulai tugas wajib itu lebih dulu. Tetap mulai ${task.text('priority')} sekarang?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Kembali ke Top 1')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Tetap mulai sekali ini')),
      ],
    ),
  );
  return _PriorityPermission(proceed == true, override: proceed == true);
}

class TaskCard extends ConsumerStatefulWidget {
  const TaskCard({
    super.key,
    required this.task,
    this.allowProjectOverride = false,
    this.showPlanningAction = false,
  });

  final DbRow task;
  final bool allowProjectOverride;
  final bool showPlanningAction;

  @override
  ConsumerState<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends ConsumerState<TaskCard> with PersistedActions<TaskCard> {
  Future<void> _completeWithUndo() async {
    if (saving) return;
    final controller = actions;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => saving = true);
    try {
      final previous = await controller.completeTaskWithUndo(widget.task.number('id'));
      if (!mounted || !messenger.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: const Text('Tugas selesai. Skor diperbarui otomatis.'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await controller.restoreTask(previous);
            } catch (error) {
              if (messenger.mounted) {
                messenger.showSnackBar(SnackBar(content: Text('Pembatalan belum tersimpan: $error')));
              }
            }
          },
        ),
      ));
    } catch (error) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Tugas belum tersimpan: $error')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _setStatus(String status) async {
    if (saving) return;
    if (status == 'Selesai') {
      await _completeWithUndo();
      return;
    }
    String? reason;
    if (status == 'Ditunda' || status == 'Dilewati') {
      reason = await showDialog<String>(
        context: context,
        builder: (_) => _TaskReasonDialog(status: status),
      );
      if (reason == null || !mounted) return;
    }
    if (status == 'Sedang berjalan') {
      final permission = await _confirmPriorityStart(context, ref, widget.task);
      if (!permission.allowed || !mounted) return;
    }
    await perform(() => actions.setTaskStatus(widget.task.number('id'), status, reason: reason));
  }

  Future<void> _showStatusSheet() async {
    if (saving) return;
    final status = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sesuaikan langkah berikutnya', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final option in const <(String, String, IconData)>[
              ('Belum mulai', 'Belum selesai / kembalikan ke belum mulai', Icons.radio_button_unchecked_rounded),
              ('Sedang berjalan', 'Sedang dikerjakan', Icons.play_circle_outline_rounded),
              ('Ditunda', 'Tunda dengan alasan', Icons.schedule_rounded),
              ('Dilewati', 'Lewati dengan alasan', Icons.skip_next_rounded),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(option.$3),
                title: Text(option.$2),
                onTap: () => Navigator.pop(sheetContext, option.$1),
              ),
          ]),
        ),
      ),
    );
    if (status != null && mounted) await _setStatus(status);
  }

  Future<void> _menuAction(String action) async {
    if (action == 'edit') {
      await showTaskEditor(context, ref, task: widget.task);
    } else if (action == 'override') {
      final project = await askText(
        context,
        title: 'Prioritaskan deadline',
        label: 'Proyek yang dikerjakan',
        initial: widget.task.text('title'),
        lines: 2,
      );
      if (project != null && mounted) {
        await perform(() => actions.overrideProject(taskId: widget.task.number('id'), project: project));
      }
    } else {
      await _setStatus(action);
    }
  }

  bool _isCurrent(DateTime now, String start, String end) {
    final date = widget.task.text('date');
    final today = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (date != today || start.isEmpty || end.isEmpty) return false;
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return start.compareTo(end) <= 0
        ? time.compareTo(start) >= 0 && time.compareTo(end) < 0
        : time.compareTo(start) >= 0 || time.compareTo(end) < 0;
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final colors = Theme.of(context).colorScheme;
    final now = ref.watch(clockProvider);
    final start = task.text('startTime');
    final end = task.text('endTime');
    final current = _isCurrent(now, start, end);
    final done = task.text('status') == 'Selesai';
    final checklist = readChecklist(task);
    final deadline = DateTime.tryParse(task.text('deadline'))?.toLocal();
    return Dismissible(
      key: ValueKey('task-swipe-${task.number('id')}'),
      direction: saving ? DismissDirection.none : DismissDirection.horizontal,
      background: _SwipeBackground(
        icon: Icons.check_circle_outline_rounded,
        label: 'Selesai',
        alignment: Alignment.centerLeft,
        color: colors.primaryContainer,
        foreground: colors.onPrimaryContainer,
      ),
      secondaryBackground: _SwipeBackground(
        icon: Icons.tune_rounded,
        label: 'Status · Tunda · Lewati',
        alignment: Alignment.centerRight,
        color: colors.secondaryContainer,
        foreground: colors.onSecondaryContainer,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _completeWithUndo();
        } else {
          await _showStatusSheet();
        }
        return false;
      },
      child: MulaCard(
        padding: EdgeInsets.zero,
        color: current ? colors.primaryContainer.withValues(alpha: .35) : null,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('task-details-${task.number('id')}'),
            tilePadding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
            childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            leading: Checkbox(
              value: done,
              shape: const CircleBorder(),
              semanticLabel: 'Tandai ${task.text('title')} selesai',
              onChanged: saving ? null : (value) async {
                if (value == true) {
                  await _completeWithUndo();
                } else {
                  await _setStatus('Belum mulai');
                }
              },
            ),
            title: Text(
              task.text('title'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                decoration: done ? TextDecoration.lineThrough : null,
                color: done ? colors.onSurfaceVariant : colors.onSurface,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${start.isEmpty ? '${task.number('estimatedMinutes')} menit' : '$start – $end'}${current ? ' · Sekarang' : ''}\n'
                '${task.text('priority', 'Reguler')} · ${task.text('status', 'Belum mulai')}',
                style: TextStyle(fontSize: 12, height: 1.6, color: current ? colors.primary : colors.onSurfaceVariant),
              ),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  _TaskDetail(icon: Icons.folder_outlined, label: task.text('category', 'Pribadi')),
                  _TaskDetail(icon: Icons.battery_4_bar_rounded, label: 'Energi ${task.text('energyLevel', 'Sedang').toLowerCase()}'),
                  _TaskDetail(icon: Icons.timelapse_rounded, label: '${task.number('estimatedMinutes')} menit'),
                  _TaskDetail(icon: Icons.spa_outlined, label: '${task.number('points')} poin otomatis'),
                  if (deadline != null) _TaskDetail(
                    icon: Icons.event_outlined,
                    label: 'Deadline ${displayDate(deadline.toIso8601String())}, '
                        '${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')}',
                  ),
                ]),
              ),
              if (task.text('description').isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Align(alignment: Alignment.centerLeft, child: Text(task.text('description'), style: const TextStyle(height: 1.5))),
              ),
              ...checklist.asMap().entries.map((entry) => CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: entry.value.flag('done'),
                title: Text(entry.value.text('title', entry.value.text('text')), style: const TextStyle(fontSize: 13, height: 1.4)),
                onChanged: saving ? null : (value) => perform(() => actions.setChecklistItem(task.number('id'), entry.key, value ?? false)),
              )),
              if (task.text('skippedReason').isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(alignment: Alignment.centerLeft, child: Text('Alasan: ${task.text('skippedReason')}', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))),
              ),
              const SizedBox(height: 12),
              Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: saving ? null : () => perform(() => startTaskFocus(context, ref, task)),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Mulai fokus 25 menit'),
                ),
                PopupMenuButton<String>(
                  enabled: !saving,
                  tooltip: 'Atur tugas',
                  onSelected: _menuAction,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit tugas')),
                    const PopupMenuItem(value: 'Sedang berjalan', child: Text('Mulai mengerjakan')),
                    const PopupMenuItem(value: 'Selesai', child: Text('Tandai selesai')),
                    const PopupMenuItem(value: 'Belum mulai', child: Text('Kembalikan ke belum mulai')),
                    const PopupMenuItem(value: 'Ditunda', child: Text('Tunda dengan alasan')),
                    const PopupMenuItem(value: 'Dilewati', child: Text('Lewati dengan alasan')),
                    if (widget.allowProjectOverride) const PopupMenuItem(value: 'override', child: Text('Override proyek / deadline')),
                  ],
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ]),
              const SizedBox(height: 6),
              Text('Geser kanan untuk selesai · geser kiri untuk mengatur status', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskDetail extends StatelessWidget {
  const _TaskDetail({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
    const SizedBox(width: 4),
    Flexible(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
  ]);
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.icon, required this.label, required this.alignment, required this.color, required this.foreground});

  final IconData icon;
  final String label;
  final Alignment alignment;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    alignment: alignment,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(24)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: foreground),
      const SizedBox(height: 6),
      Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _TaskReasonDialog extends StatefulWidget {
  const _TaskReasonDialog({required this.status});
  final String status;

  @override
  State<_TaskReasonDialog> createState() => _TaskReasonDialogState();
}

class _TaskReasonDialogState extends State<_TaskReasonDialog> {
  final _form = GlobalKey<FormState>();
  final _note = TextEditingController();
  String? _reason;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final note = _note.text.trim();
    final reason = _reason == null || _reason == 'Lainnya'
        ? note
        : note.isEmpty ? _reason! : '$_reason — $note';
    Navigator.pop(context, reason);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.status == 'Ditunda' ? 'Tunda dengan sadar' : 'Lewati dengan alasan'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Pilih atau tulis alasan singkat sebelum status disimpan.'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('task-status-reason'),
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Alasan'),
              items: const ['Prioritas berubah', 'Menunggu orang lain', 'Waktu tidak cukup', 'Energi menurun', 'Kondisi mendesak', 'Lainnya']
                  .map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
              onChanged: (value) => setState(() => _reason = value),
              validator: (value) => value == null && _note.text.trim().isEmpty ? 'Pilih atau tulis alasan singkat.' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('task-status-note'),
              controller: _note,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: _reason == 'Lainnya' ? 'Tulis alasan singkat' : 'Alasan lain / catatan (opsional)'),
              validator: (value) => _reason == 'Lainnya' && (value == null || value.trim().isEmpty) ? 'Tulis alasan singkat.' : null,
            ),
          ]),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
      FilledButton(key: const ValueKey('save-task-status'), onPressed: _save, child: const Text('Simpan alasan & status')),
    ],
  );
}
