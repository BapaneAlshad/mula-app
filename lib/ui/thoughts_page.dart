import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';
import 'widgets/shared.dart';

class ThoughtsPage extends ConsumerStatefulWidget {
  const ThoughtsPage({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<ThoughtsPage> createState() => _ThoughtsPageState();
}

class _ThoughtsPageState extends ConsumerState<ThoughtsPage> with PersistedActions<ThoughtsPage> {
  Future<void> _addThought() async {
    final draft = await showDialog<_ThoughtDraft>(context: context, builder: (_) => const _ThoughtDialog());
    if (draft != null && mounted) await perform(() => actions.addThought(content: draft.content, type: draft.type, intensity: draft.intensity, needsAction: draft.needsAction, nextAction: draft.nextAction));
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final colors = Theme.of(context).colorScheme;
    final locked = data.preferences['privacyLock'] == 'true' && !ref.watch(thoughtsUnlockedProvider);
    if (locked) {
      return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
        const PageTitle(title: 'Ruang pribadi.', subtitle: 'Pikiranmu punya tempat yang aman untuk singgah.'),
        const EmptyState(icon: Icons.lock_outline_rounded, title: 'Catatan pikiran terkunci', message: 'Gunakan biometrik atau kunci perangkat untuk membuka catatanmu.'),
        const SizedBox(height: 18),
        FilledButton.icon(onPressed: saving ? null : () => perform(() async {
          final unlocked = await actions.unlockThoughts();
          if (!unlocked && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Catatan tetap terkunci. Autentikasi belum berhasil.')));
        }), icon: const Icon(Icons.fingerprint_rounded), label: const Text('Buka ruang pikiran')),
      ]);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
      const PageTitle(title: 'Letakkan dulu.\nLepaskan sejenak.', subtitle: 'Tidak semua pikiran perlu diselesaikan sekarang.'),
      MulaCard(color: colors.primaryContainer.withValues(alpha: .35), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.cloud_outlined, color: colors.primary, size: 30),
        const SizedBox(height: 12),
        Text('Apa yang memenuhi kepalamu?', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('Tulis agar pikiranmu tidak harus membawa semuanya sekaligus.', style: TextStyle(height: 1.6)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: saving ? null : _addThought, icon: const Icon(Icons.add_rounded), label: const Text('Parkirkan pikiran')),
      ])),
      const SizedBox(height: 26),
      Text('Yang sedang singgah', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      if (data.thoughts.isEmpty) const EmptyState(icon: Icons.waves_rounded, title: 'Ada ruang untuk bernapas.', message: 'Saat pikiran datang, kamu bisa meletakkannya di sini.'),
      ...data.thoughts.map((thought) {
        final done = thought.text('status') == 'Selesai';
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${thought.text('type')} · intensitas ${thought.number('intensity')}/10', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.primary))),
            PopupMenuButton<String>(
              enabled: !saving,
              tooltip: 'Status pikiran',
              onSelected: (status) => perform(() => actions.setThoughtStatus(thought.number('id'), status)),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'Selesai', child: Text('Sudah ditangani')),
                PopupMenuItem(value: 'Ditinjau', child: Text('Sedang ditinjau')),
                PopupMenuItem(value: 'Terparkir', child: Text('Parkirkan kembali')),
              ],
            ),
          ]),
          Text(thought.text('content'), style: TextStyle(height: 1.6, color: done ? colors.onSurfaceVariant : colors.onSurface)),
          if (thought.flag('needsAction') && thought.text('nextAction').isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.subdirectory_arrow_right_rounded, color: colors.primary, size: 18), const SizedBox(width: 8), Expanded(child: Text(thought.text('nextAction'), style: const TextStyle(fontSize: 13, height: 1.5)))]),
          ),
          const SizedBox(height: 12),
          Text('${thought.text('status', 'Terparkir')} · ${displayDate(thought.text('createdAt'))}', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
        ])));
      }),
    ]);
  }
}

class _ThoughtDraft {
  const _ThoughtDraft(this.content, this.type, this.intensity, this.needsAction, this.nextAction);
  final String content;
  final String type;
  final int intensity;
  final bool needsAction;
  final String nextAction;
}

class _ThoughtDialog extends StatefulWidget {
  const _ThoughtDialog();
  @override
  State<_ThoughtDialog> createState() => _ThoughtDialogState();
}

class _ThoughtDialogState extends State<_ThoughtDialog> {
  final _form = GlobalKey<FormState>();
  final _content = TextEditingController();
  final _next = TextEditingController();
  String _type = 'Kekhawatiran';
  double _intensity = 5;
  bool _needsAction = false;

  @override
  void dispose() {
    _content.dispose();
    _next.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Parkirkan pikiran'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextFormField(controller: _content, autofocus: true, minLines: 3, maxLines: 7, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Apa yang sedang terpikir?'), validator: (value) => value == null || value.trim().isEmpty ? 'Tulis pikiranmu terlebih dahulu.' : null),
      const SizedBox(height: 18),
      DropdownButtonFormField<String>(initialValue: _type, decoration: const InputDecoration(labelText: 'Jenis pikiran'), items: ['Kekhawatiran', 'Ide', 'Masalah', 'Tugas', 'Emosi'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(), onChanged: (value) => setState(() => _type = value ?? _type)),
      const SizedBox(height: 18),
      Text('Seberapa kuat terasa? ${_intensity.round()}/10'),
      Slider(value: _intensity, min: 1, max: 10, divisions: 9, label: '${_intensity.round()}', onChanged: (value) => setState(() => _intensity = value)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Perlu tindakan kecil'), value: _needsAction, onChanged: (value) => setState(() => _needsAction = value)),
      if (_needsAction) TextFormField(controller: _next, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Langkah berikutnya'), validator: (value) => value == null || value.trim().isEmpty ? 'Tulis tindakan terkecil yang bisa dilakukan.' : null),
    ])))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
      FilledButton(onPressed: () {
        if (_form.currentState!.validate()) Navigator.pop(context, _ThoughtDraft(_content.text.trim(), _type, _intensity.round(), _needsAction, _needsAction ? _next.text.trim() : ''));
      }, child: const Text('Simpan & lepaskan')),
    ],
  );
}
