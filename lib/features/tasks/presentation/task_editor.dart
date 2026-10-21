import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/app_controller.dart';
import '../../../domain/app_snapshot.dart';
import '../../../ui/widgets/shared.dart';
import '../domain/abstract_task_converter.dart';

Future<void> showTaskEditor(
  BuildContext context,
  WidgetRef ref, {
  DbRow? task,
  String initialPriority = 'Reguler',
  String initialCategory = 'Pribadi',
}) {
  final now = ref.read(clockProvider);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TaskEditor(
      task: task,
      now: now,
      initialPriority: initialPriority,
      initialCategory: initialCategory,
    ),
  );
}

class _TaskEditor extends ConsumerStatefulWidget {
  const _TaskEditor({
    required this.task,
    required this.now,
    required this.initialPriority,
    required this.initialCategory,
  });

  final DbRow? task;
  final DateTime now;
  final String initialPriority;
  final String initialCategory;

  @override
  ConsumerState<_TaskEditor> createState() => _TaskEditorState();
}

class _SubtaskDraft {
  _SubtaskDraft({String title = '', this.done = false})
      : title = TextEditingController(text: title);

  final TextEditingController title;
  bool done;
}

class _TaskEditorState extends ConsumerState<_TaskEditor> {
  static const _categories = ['Tim', 'Pribadi', 'Wajib', 'Penting', 'Jika Sempat', 'Rutinitas', 'Side Job'];
  static const _priorities = ['Top 1', 'Top 2', 'Top 3', 'Reguler'];
  static const _energies = ['Rendah', 'Sedang', 'Tinggi'];

  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _minutes;
  late final TextEditingController _weight;
  late final List<_SubtaskDraft> _subtasks;
  late String _category;
  late String _priority;
  late String _energy;
  DateTime? _deadline;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.text('title') ?? '');
    _description = TextEditingController(text: task?.text('description') ?? '');
    _minutes = TextEditingController(text: '${task?.number('estimatedMinutes', 25) ?? 25}');
    _weight = TextEditingController(text: '${task?.number('pointWeight', 10) ?? 10}');
    _category = _validChoice(task?.text('category') ?? widget.initialCategory, _categories, 'Pribadi');
    _priority = _validChoice(task?.text('priority') ?? widget.initialPriority, _priorities, 'Reguler');
    _energy = _validChoice(task?.text('energyLevel') ?? 'Sedang', _energies, 'Sedang');
    _deadline = DateTime.tryParse(task?.text('deadline') ?? '')?.toLocal();
    _subtasks = [
      if (task != null)
        for (final subtask in readChecklist(task))
          _SubtaskDraft(title: subtask.text('title', subtask.text('text')), done: subtask.flag('done')),
    ];
  }

  static String _validChoice(String value, List<String> values, String fallback) =>
      values.contains(value) ? value : fallback;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _minutes.dispose();
    _weight.dispose();
    for (final subtask in _subtasks) {
      subtask.title.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final initial = _deadline ?? widget.now;
    final earliest = DateTime(2000);
    final latest = DateTime(2100, 12, 31);
    final initialDate = initial.isBefore(earliest) ? earliest : initial.isAfter(latest) ? latest : initial;
    final day = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: earliest,
      lastDate: latest,
      helpText: 'Pilih tanggal deadline',
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Pilih jam deadline',
    );
    if (time == null || !mounted) return;
    setState(() => _deadline = DateTime(day.year, day.month, day.day, time.hour, time.minute));
  }

  void _applySuggestion(AbstractTaskSuggestion suggestion) {
    setState(() {
      _title.text = suggestion.title;
      _title.selection = TextSelection.collapsed(offset: _title.text.length);
      if (_subtasks.isEmpty) {
        _subtasks.addAll(suggestion.steps.map((step) => _SubtaskDraft(title: step)));
      }
    });
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final actions = ref.read(appControllerProvider.notifier);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await actions.saveTask(
        taskId: widget.task?.number('id'),
        title: _title.text.trim(),
        description: _description.text.trim(),
        category: _category,
        deadline: _deadline?.toUtc().toIso8601String(),
        estimatedMinutes: int.parse(_minutes.text),
        energyLevel: _energy,
        priority: _priority,
        subtasks: [
          for (final subtask in _subtasks)
            {'title': subtask.title.text.trim(), 'done': subtask.done},
        ],
        pointWeight: int.parse(_weight.text),
      );
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Belum tersimpan: $error';
        });
      }
    }
  }

  String? _integerInRange(String? value, int min, int max, String message) {
    final number = int.tryParse(value ?? '');
    return number == null || number < min || number > max ? message : null;
  }

  @override
  Widget build(BuildContext context) {
    final suggestion = AbstractTaskConverter.suggest(_title.text);
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.task == null ? 'Tambah tugas' : 'Edit tugas'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    key: const ValueKey('task-title'),
                    controller: _title,
                    enabled: !_saving,
                    autofocus: widget.task == null,
                    textCapitalization: TextCapitalization.sentences,
                    maxLength: 240,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(labelText: 'Judul tugas', hintText: 'Tindakan kecil dengan hasil yang bisa diperiksa'),
                    onChanged: (_) => setState(() {}),
                    validator: (value) => value == null || value.trim().isEmpty ? 'Isi judul tugas.' : null,
                  ),
                  if (suggestion != null) ...[
                    const SizedBox(height: 8),
                    MulaCard(
                      padding: const EdgeInsets.all(14),
                      color: colors.secondaryContainer,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Ubah niat menjadi tindakan', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 6),
                        const Text('Judul ini masih luas. Coba satu hasil yang dapat diperiksa.'),
                        const SizedBox(height: 8),
                        Text(suggestion.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          key: const ValueKey('apply-task-conversion'),
                          onPressed: _saving ? null : () => _applySuggestion(suggestion),
                          icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                          label: const Text('Gunakan tindakan ini'),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('task-description'),
                    controller: _description,
                    enabled: !_saving,
                    minLines: 2,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(labelText: 'Deskripsi', hintText: 'Seperti apa tugas ini dianggap selesai?'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('task-category'),
                    initialValue: _category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Kategori'),
                    items: _categories.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                    onChanged: _saving ? null : (value) => setState(() => _category = value ?? _category),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      key: const ValueKey('task-deadline'),
                      onPressed: _saving ? null : _pickDeadline,
                      icon: const Icon(Icons.event_outlined, size: 18),
                      label: Text(_deadline == null ? 'Atur deadline (opsional)' : 'Deadline: ${_deadlineLabel(_deadline!)}'),
                    )),
                    if (_deadline != null) IconButton(
                      tooltip: 'Hapus deadline',
                      onPressed: _saving ? null : () => setState(() => _deadline = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('task-minutes'),
                    controller: _minutes,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Durasi estimasi', suffixText: 'menit'),
                    validator: (value) => _integerInRange(value, 1, 1440, 'Gunakan 1–1440 menit.'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('task-energy'),
                    initialValue: _energy,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Tingkat energi'),
                    items: _energies.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                    onChanged: _saving ? null : (value) => setState(() => _energy = value ?? _energy),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('task-priority'),
                    initialValue: _priority,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Prioritas', helperText: 'Setiap slot Top 1–3 hanya memuat satu tugas.'),
                    items: _priorities.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                    onChanged: _saving ? null : (value) => setState(() => _priority = value ?? _priority),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('task-point-weight'),
                    controller: _weight,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Nilai / bobot poin',
                      helperText: 'Bobot 1–100. Skor hari dihitung otomatis, maksimal 100.',
                      helperMaxLines: 2,
                    ),
                    validator: (value) => _integerInRange(value, 1, 100, 'Gunakan bobot 1–100.'),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(child: Text('Subtask', style: Theme.of(context).textTheme.titleSmall)),
                    TextButton.icon(
                      key: const ValueKey('add-subtask'),
                      onPressed: _saving ? null : () => setState(() => _subtasks.add(_SubtaskDraft())),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Tambah langkah'),
                    ),
                  ]),
                  if (_subtasks.isEmpty) Text('Pecah tugas menjadi langkah kecil bila perlu.', style: TextStyle(color: colors.onSurfaceVariant)),
                  for (var index = 0; index < _subtasks.length; index++)
                    Padding(
                      key: ObjectKey(_subtasks[index]),
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Checkbox(
                            value: _subtasks[index].done,
                            semanticLabel: 'Subtask ${index + 1} selesai',
                            onChanged: _saving ? null : (value) => setState(() => _subtasks[index].done = value ?? false),
                          ),
                        ),
                        Expanded(child: TextFormField(
                          controller: _subtasks[index].title,
                          enabled: !_saving,
                          minLines: 1,
                          maxLines: 3,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(labelText: 'Subtask ${index + 1}'),
                          validator: (value) => value == null || value.trim().isEmpty ? 'Isi langkah atau hapus baris ini.' : null,
                        )),
                        IconButton(
                          tooltip: 'Hapus subtask ${index + 1}',
                          onPressed: _saving ? null : () {
                            final removed = _subtasks[index];
                            setState(() => _subtasks.removeAt(index));
                            removed.title.dispose();
                          },
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        ),
                      ]),
                    ),
                  if (_error != null) Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_error!, key: const ValueKey('task-save-error'), style: TextStyle(color: colors.error)),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton.icon(
            key: const ValueKey('save-task'),
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_rounded, size: 18),
            label: Text(_saving ? 'Menyimpan…' : 'Simpan tugas'),
          ),
        ],
      ),
    );
  }
}

String _deadlineLabel(DateTime value) =>
    '${displayDate(value.toIso8601String())}, '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
