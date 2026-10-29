import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../data/daily_score_calculator.dart';
import '../data/schedule_repository.dart';
import '../domain/app_snapshot.dart';
import 'widgets/shared.dart';

class ScheduleEditorPage extends ConsumerWidget {
  const ScheduleEditorPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(appControllerProvider).valueOrNull;
    final templates = snapshot?.templates.toList() ?? [];
    templates.sort((a, b) => a.text('startTime').compareTo(b.text('startTime')));
    return Scaffold(
      appBar: AppBar(title: const Text('Jadwal rutin')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Perubahan berlaku mulai besok. Tugas dan progres yang sudah dibuat tetap tersimpan. Blok perencanaan 08.00 dan aturan game 11.45–13.00 tetap mengikuti jam sistem.', style: TextStyle(height: 1.6)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: () => _edit(context, null), icon: const Icon(Icons.add), label: const Text('Tambah blok rutin')),
        const SizedBox(height: 16),
        for (final row in templates) Padding(padding: const EdgeInsets.only(bottom: 12), child: MulaCard(child: ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(row.text('title')),
          subtitle: Text('${row.text('startTime')}–${row.text('endTime')} · ${row.flag('isActive') ? 'Aktif' : 'Nonaktif'}\n${_days(row)}${row.text('effectiveFrom').isEmpty ? '' : '\nBerlaku ${row.text('effectiveFrom')}'}'),
          trailing: const Icon(Icons.edit_outlined), onTap: () => _edit(context, row),
        ))),
      ]),
    );
  }
  static String _days(DbRow row) {
    const names = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    return (jsonDecode(row.text('daysOfWeek', '[]')) as List).map((day) => names[(day as int) - 1]).join(', ');
  }
  Future<void> _edit(BuildContext context, DbRow? row) => showDialog<void>(
    context: context, builder: (_) => _ScheduleDialog(row: row),
  );
}

class _ScheduleDialog extends ConsumerStatefulWidget {
  const _ScheduleDialog({this.row});
  final DbRow? row;
  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _checklist;
  late String _category;
  late Set<int> _days;
  late bool _active;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final row = widget.row ?? <String, Object?>{};
    _title = TextEditingController(text: row.text('title'));
    _start = TextEditingController(text: row.text('startTime', '16:00'));
    _end = TextEditingController(text: row.text('endTime', '17:00'));
    _checklist = TextEditingController(text: DailyScoreCalculator.decodeChecklist(row.text('checklistJson', '[]')).map((item) => item.text('title')).join('\n'));
    _category = row.text('category', 'Pribadi');
    _days = (jsonDecode(row.text('daysOfWeek', '[1,2,3,4,5,6,7]')) as List).cast<int>().toSet();
    _active = widget.row == null || row.flag('isActive');
  }
  @override
  void dispose() {
    _title.dispose(); _start.dispose(); _end.dispose(); _checklist.dispose();
    super.dispose();
  }
  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      await ref.read(appControllerProvider.notifier).saveSchedule(
        id: widget.row?.number('id'), title: _title.text, startTime: _start.text,
        endTime: _end.text, category: _category, days: _days.toList(), active: _active,
        checklist: _checklist.text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList(),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.row == null ? 'Tambah blok rutin' : 'Ubah blok rutin'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextFormField(controller: _title, maxLength: 160, decoration: const InputDecoration(labelText: 'Judul'), validator: (value) => value == null || value.trim().isEmpty ? 'Isi judul.' : null),
      const SizedBox(height: 12),
      Row(children: [Expanded(child: TextFormField(controller: _start, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'Mulai HH:mm'))), const SizedBox(width: 12), Expanded(child: TextFormField(controller: _end, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'Selesai HH:mm')))]),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(initialValue: _category, isExpanded: true, decoration: const InputDecoration(labelText: 'Kategori'), items: ScheduleRepository.categories.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(), onChanged: _saving ? null : (value) => setState(() => _category = value ?? _category)),
      const SizedBox(height: 16),
      Wrap(spacing: 5, children: [for (var index = 1; index <= 7; index++) FilterChip(label: Text(['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'][index - 1]), selected: _days.contains(index), onSelected: _saving ? null : (selected) => setState(() { if (selected) { _days.add(index); } else { _days.remove(index); } }))]),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Blok aktif'), value: _active, onChanged: _saving ? null : (value) => setState(() => _active = value)),
      TextFormField(controller: _checklist, minLines: 3, maxLines: 7, decoration: const InputDecoration(labelText: 'Checklist, satu per baris')),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ])))),
    actions: [TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Batal')), FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Menyimpan…' : 'Simpan mulai besok'))],
  );
}
