import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_snapshot.dart';
import '../theme/circadian_theme.dart';
import 'widgets/shared.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> with PersistedActions<SettingsPage> {
  Future<void> _profile() async {
    final draft = await showDialog<_ProfileDraft>(context: context, builder: (_) => _ProfileDialog(user: widget.snapshot.user));
    if (draft != null && mounted) await perform(() => actions.saveUser(name: draft.name, wakeTime: draft.wakeTime, sleepTime: draft.sleepTime, strictnessLevel: draft.strictness, onboardingCompleted: true), success: 'Profil dan ritmemu tersimpan.');
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.snapshot;
    final colors = Theme.of(context).colorScheme;
    final theme = ref.watch(circadianThemeProvider);
    final user = data.user;
    return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
      const PageTitle(title: 'Sistem yang\nmenemanimu.', subtitle: 'Sesuaikan MULA dengan ritme dan kebutuhanmu.'),
      MulaCard(child: Row(children: [
        CircleAvatar(radius: 27, backgroundColor: colors.primaryContainer, child: Icon(Icons.person_outline_rounded, size: 29, color: colors.primary)),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(user.text('name', 'Anggit'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Ditemani dengan ${user.text('strictnessLevel', 'Lembut').toLowerCase()}', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13)),
        ])),
        IconButton(onPressed: saving ? null : _profile, tooltip: 'Ubah profil dan ritme', icon: const Icon(Icons.edit_outlined)),
      ])),
      const SizedBox(height: 16),
      MulaCard(child: Column(children: [
        Row(children: [
          Expanded(child: _RhythmValue(icon: Icons.wb_sunny_outlined, label: 'BANGUN', value: user.text('wakeTime', '04:30'))),
          Container(width: 1, height: 46, color: colors.outlineVariant),
          Expanded(child: _RhythmValue(icon: Icons.bedtime_outlined, label: 'TIDUR', value: user.text('sleepTime', '22:00'))),
        ]),
        const SizedBox(height: 16),
        Text('Jam kerja ${user.text('workStartTime', '08:00')} – ${user.text('workEndTime', '16:00')}', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
      ])),
      const SizedBox(height: 26),
      Text('Pengingat & privasi', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      MulaCard(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4), child: Column(children: [
        SwitchListTile(
          secondary: Icon(Icons.notifications_none_rounded, color: colors.primary),
          title: const Text('Pengingat jadwal'),
          subtitle: const Text('Notifikasi dan alarm untuk kembali ke blok berikutnya.', style: TextStyle(fontSize: 12, height: 1.5)),
          value: data.preferences['reminders'] == 'true',
          onChanged: saving ? null : (value) => perform(() => actions.configureReminders(value)),
        ),
        const Divider(indent: 20, endIndent: 20),
        SwitchListTile(
          secondary: Icon(Icons.fingerprint_rounded, color: colors.primary),
          title: const Text('Kunci ruang pikiran'),
          subtitle: const Text('Buka catatan dengan biometrik atau PIN kunci perangkat.', style: TextStyle(fontSize: 12, height: 1.5)),
          value: data.preferences['privacyLock'] == 'true',
          onChanged: saving ? null : (value) => perform(() => actions.setPrivacyLock(value)),
        ),
        if ((data.preferences['reminderStatus'] ?? '').isNotEmpty) Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Text(data.preferences['reminderStatus']!, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12, height: 1.5)),
        ),
      ])),
      const SizedBox(height: 26),
      Text('Suasana ruangmu', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 14),
      MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(theme.sanctuary ? Icons.spa_outlined : Icons.wb_twilight_rounded, color: colors.primary), const SizedBox(width: 12), Expanded(child: Text(theme.sanctuary ? 'Sanctuary · ruang tenang' : 'Ritme ${theme.periodLabel.toLowerCase()}', style: Theme.of(context).textTheme.titleMedium))]),
        const SizedBox(height: 12),
        Text('Warna dan sapaan mengikuti waktu. Saat cemas, stuck, atau menjalani hari buruk, MULA berubah menjadi ruang yang lebih tenang.', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13, height: 1.6)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: saving ? null : () => perform(theme.sanctuary ? actions.exitSanctuary : () => actions.enterSanctuary('Memilih ruang tenang')),
          icon: Icon(theme.sanctuary ? Icons.wb_sunny_outlined : Icons.spa_outlined, size: 18),
          label: Text(theme.sanctuary ? 'Kembali ke ritme normal' : 'Masuk ruang tenang'),
        ),
      ])),
      const SizedBox(height: 22),
      MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.offline_bolt_outlined, color: colors.primary, size: 22), const SizedBox(width: 10), Text('Milikmu, di perangkatmu.', style: Theme.of(context).textTheme.titleSmall)]),
        const SizedBox(height: 10),
        Text('Jadwal, progres, sesi fokus, dan catatan disimpan lokal. MULA tetap bisa menemanimu tanpa koneksi internet.', style: TextStyle(color: colors.onSurfaceVariant, height: 1.6, fontSize: 13)),
        const SizedBox(height: 12),
        TextButton.icon(onPressed: saving ? null : () => perform(actions.refresh, success: 'Data hari ini sudah diperbarui.'), icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Muat ulang data hari ini')),
      ])),
      const SizedBox(height: 26),
      Text('MULA\nMulai kecil. Tumbuh setiap hari.', textAlign: TextAlign.center, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12, height: 1.8, letterSpacing: .4)),
    ]);
  }
}

class _RhythmValue extends StatelessWidget {
  const _RhythmValue({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(children: [
    Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
    const SizedBox(height: 9),
    Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    const SizedBox(height: 5),
    Text(value, style: Theme.of(context).textTheme.headlineSmall),
  ]);
}

class _ProfileDraft {
  const _ProfileDraft(this.name, this.wakeTime, this.sleepTime, this.strictness);
  final String name;
  final String wakeTime;
  final String sleepTime;
  final String strictness;
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.user});
  final DbRow user;
  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late TimeOfDay _wake;
  late TimeOfDay _sleep;
  late String _strictness;

  TimeOfDay _parse(String value, TimeOfDay fallback) {
    final parts = value.split(':');
    if (parts.length != 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) return fallback;
    return TimeOfDay(hour: hour, minute: minute);
  }

  String _format(TimeOfDay value) => '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user.text('name', 'Anggit'));
    _wake = _parse(widget.user.text('wakeTime'), const TimeOfDay(hour: 4, minute: 30));
    _sleep = _parse(widget.user.text('sleepTime'), const TimeOfDay(hour: 22, minute: 0));
    final strictness = widget.user.text('strictnessLevel', 'Lembut');
    _strictness = ['Lembut', 'Seimbang', 'Tegas'].contains(strictness) ? strictness : 'Lembut';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _chooseTime(bool wake) async {
    final value = await showTimePicker(context: context, initialTime: wake ? _wake : _sleep);
    if (value != null && mounted) {
      setState(() {
        if (wake) {
          _wake = value;
        } else {
          _sleep = value;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Profil & ritme harian'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextFormField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nama panggilan'), validator: (value) => value == null || value.trim().isEmpty ? 'Isi nama panggilan.' : null),
      const SizedBox(height: 18),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.wb_sunny_outlined), title: const Text('Jam bangun'), trailing: Text(_format(_wake)), onTap: () => _chooseTime(true)),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.bedtime_outlined), title: const Text('Jam tidur'), trailing: Text(_format(_sleep)), onTap: () => _chooseTime(false)),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(initialValue: _strictness, isExpanded: true, decoration: const InputDecoration(labelText: 'Tingkat ketegasan'), items: ['Lembut', 'Seimbang', 'Tegas'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(), onChanged: (value) => setState(() => _strictness = value ?? _strictness)),
    ])))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
      FilledButton(onPressed: () {
        if (_form.currentState!.validate()) Navigator.pop(context, _ProfileDraft(_name.text.trim(), _format(_wake), _format(_sleep), _strictness));
      }, child: const Text('Simpan ritme')),
    ],
  );
}
