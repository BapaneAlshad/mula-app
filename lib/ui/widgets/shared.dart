import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/app_controller.dart';
import '../../domain/app_snapshot.dart';

mixin PersistedActions<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool saving = false;

  AppController get actions => ref.read(appControllerProvider.notifier);

  Future<void> perform(Future<void> Function() action, {String? success}) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await action();
      if (mounted && success != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Belum tersimpan: $error')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class MulaCard extends StatelessWidget {
  const MulaCard({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .5)),
    ),
    child: child,
  );
}

class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, required this.subtitle, this.trailing});
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.7)),
        const SizedBox(height: 6),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5)),
      ])),
      if (trailing != null) trailing!,
    ]),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => MulaCard(child: Column(children: [
    Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
    const SizedBox(height: 12),
    Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 6),
    Text(message, textAlign: TextAlign.center, style: TextStyle(height: 1.5, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  ]));
}

List<DbRow> readChecklist(DbRow task) {
  try {
    final value = jsonDecode(task.text('subtasksJson', '[]'));
    if (value is List) return value.whereType<Map>().map((item) => Map<String, Object?>.from(item)).toList();
  } on FormatException {
    return [];
  }
  return [];
}

Future<String?> askText(BuildContext context, {required String title, required String label, String initial = '', String confirm = 'Simpan', int lines = 3}) async {
  final controller = TextEditingController(text: initial);
  final form = GlobalKey<FormState>();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Form(key: form, child: TextFormField(
        controller: controller,
        autofocus: true,
        minLines: lines,
        maxLines: lines + 2,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        validator: (value) => value == null || value.trim().isEmpty ? 'Tulis satu hal singkat.' : null,
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Batal')),
        FilledButton(onPressed: () {
          if (form.currentState!.validate()) Navigator.pop(dialogContext, controller.text.trim());
        }, child: Text(confirm)),
      ],
    ),
  );
  // The dialog route can still animate after its result is delivered.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  controller.dispose();
  return result;
}

String displayDate(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return value;
  const days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
  const months = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
  return '${days[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}';
}
