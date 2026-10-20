import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';
import 'widgets/mula_seed.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(text: 'Anggit');
  TimeOfDay _wake = const TimeOfDay(hour: 4, minute: 30);
  TimeOfDay _sleep = const TimeOfDay(hour: 22, minute: 0);
  String _strictness = 'Lembut';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name.text = widget.snapshot.user.text('name', 'Anggit');
    final wake = widget.snapshot.user.text('wakeTime', '04:30').split(':');
    final sleep = widget.snapshot.user.text('sleepTime', '22:00').split(':');
    _wake = TimeOfDay(hour: int.tryParse(wake.first) ?? 4, minute: wake.length > 1 ? int.tryParse(wake[1]) ?? 30 : 30);
    _sleep = TimeOfDay(hour: int.tryParse(sleep.first) ?? 22, minute: sleep.length > 1 ? int.tryParse(sleep[1]) ?? 0 : 0);
    final strictness = widget.snapshot.user.text('strictnessLevel', 'Lembut');
    _strictness = ['Lembut', 'Seimbang', 'Tegas'].contains(strictness) ? strictness : 'Lembut';
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _time(TimeOfDay value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  Future<void> _chooseTime(bool wake) async {
    final result = await showTimePicker(context: context, initialTime: wake ? _wake : _sleep);
    if (result != null && mounted) {
      setState(() {
        if (wake) {
          _wake = result;
        } else {
          _sleep = result;
        }
      });
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(appControllerProvider.notifier).saveUser(
        name: _name.text.trim(),
        wakeTime: _time(_wake),
        sleepTime: _time(_sleep),
        strictnessLevel: _strictness,
        onboardingCompleted: true,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Belum tersimpan: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MulaSeed(score: 25, size: 96),
                    Text('MULA', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 5, color: colors.primary)),
                    const SizedBox(height: 18),
                    Text('Ruang untuk\nbertumbuh.', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, height: 1.12)),
                    const SizedBox(height: 12),
                    Text('Mulai kecil. Tumbuh setiap hari.', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 26),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Nama panggilan', prefixIcon: Icon(Icons.person_outline_rounded)),
                      validator: (value) => value == null || value.trim().isEmpty ? 'Isi nama panggilanmu.' : null,
                    ),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(onPressed: _saving ? null : () => _chooseTime(true), icon: const Icon(Icons.wb_sunny_outlined), label: Text('Bangun ${_time(_wake)}'))),
                      const SizedBox(width: 10),
                      Expanded(child: OutlinedButton.icon(onPressed: _saving ? null : () => _chooseTime(false), icon: const Icon(Icons.bedtime_outlined), label: Text('Tidur ${_time(_sleep)}'))),
                    ]),
                    const SizedBox(height: 20),
                    Text('Bagaimana MULA menemanimu?', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: ['Lembut', 'Seimbang', 'Tegas'].map((value) => ChoiceChip(
                        label: Text(value),
                        selected: _strictness == value,
                        onSelected: _saving ? null : (_) => setState(() => _strictness = value),
                      )).toList(),
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(color: colors.primaryContainer.withValues(alpha: .5), borderRadius: BorderRadius.circular(20)),
                      child: const Text('“Saya tidak harus sempurna. Saya hanya wajib kembali ke sistem pada blok berikutnya.”', style: TextStyle(height: 1.6)),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(width: double.infinity, child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_forward_rounded),
                      label: Text(_saving ? 'Menyiapkan ruangmu…' : 'Mulai langkah pertama'),
                    )),
                    const SizedBox(height: 14),
                    Text('Jadwal dan catatan tersimpan di perangkatmu. Tetap bisa digunakan tanpa internet.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant, height: 1.5)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
