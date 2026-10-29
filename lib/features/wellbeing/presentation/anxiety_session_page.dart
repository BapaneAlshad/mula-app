import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/app_controller.dart';
import '../../../data/wellbeing_repository.dart';
import '../../../domain/app_snapshot.dart';
import '../../../ui/widgets/shared.dart';
import '../application/wellbeing_providers.dart';

Future<void> showAnxietySession(BuildContext context, WidgetRef ref) async {
  await ref.read(appControllerProvider.notifier).enterSanctuary('Cemas');
  if (!context.mounted) return;
  ref.invalidate(anxietySessionProvider);
  await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => const AnxietySessionPage()));
}

class AnxietySessionPage extends ConsumerStatefulWidget {
  const AnxietySessionPage({super.key});

  @override
  ConsumerState<AnxietySessionPage> createState() => _AnxietySessionPageState();
}

class _AnxietySessionPageState extends ConsumerState<AnxietySessionPage>
    with PersistedActions<AnxietySessionPage> {
  double _before = 5;
  double _after = 5;

  Future<void> _start() => perform(() async {
    await ref.read(wellbeingRepositoryProvider).startSession(_before.round());
    ref.invalidate(anxietySessionProvider);
  });

  Future<void> _finish(DbRow session) => perform(() async {
    await ref.read(wellbeingRepositoryProvider)
        .finishSession(session.text('id'), _after.round());
    ref.invalidate(anxietySessionProvider);
    ref.invalidate(historyDayProvider);
    ref.invalidate(historyMonthProvider);
    ref.invalidate(historyWeekProvider);
    await actions.refresh();
    if (mounted) Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(anxietySessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Ruang tenang')),
      body: SafeArea(child: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ListView(
          padding: const EdgeInsets.all(22), children: [
            Text('Sesi belum dapat dibuka: $error'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => ref.invalidate(anxietySessionProvider),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Buka kembali sesi tersimpan'),
            ),
          ],
        ),
        data: (session) => _content(context, session),
      )),
    );
  }

  Widget _content(BuildContext context, DbRow? session) {
    final colors = Theme.of(context).colorScheme;
    if (session == null) {
      return ListView(padding: const EdgeInsets.all(22), children: [
        const PageTitle(title: 'Ambil ruang\nuntuk dirimu.',
          subtitle: 'Dua menit untuk bernapas pelan, lalu kembali mengenali sekitar.'),
        MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Seberapa kuat cemasmu sekarang? ${_before.round()}/10',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text('1 = ringan · 10 = sangat kuat'),
          Slider(value: _before, min: 1, max: 10, divisions: 9,
            label: '${_before.round()}',
            onChanged: saving ? null : (value) => setState(() => _before = value)),
          const SizedBox(height: 12),
          const Text('Ikuti napas yang nyaman. Kamu boleh beralih ke grounding atau menyimpan sesi lebih awal.',
              style: TextStyle(height: 1.6)),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: saving ? null : _start,
            icon: const Icon(Icons.spa_outlined), label: const Text('Mulai sesi tenang')),
        ])),
      ]);
    }
    final now = ref.watch(clockProvider);
    final began = DateTime.parse(session.text('startedAt'));
    final elapsed = now.difference(began).inSeconds;
    final remaining = (120 - elapsed).clamp(0, 120).toInt();
    final phaseSecond = elapsed < 0 ? 0 : elapsed % 10;
    final inhaling = phaseSecond < 4;
    final grounding = session.text('phase') == 'grounding' || remaining == 0;
    final checks = List<bool>.from(session['grounding']! as List<dynamic>);
    return ListView(padding: const EdgeInsets.all(22), children: [
      const PageTitle(title: 'Di sini.\nSaat ini.',
        subtitle: 'Sesi tersimpan. Kamu bisa menutup layar dan melanjutkannya nanti.'),
      if (!grounding) MulaCard(
        color: colors.primaryContainer.withValues(alpha: .35),
        child: Column(children: [
          Text(inhaling ? 'Tarik napas perlahan' : 'Hembuskan dengan nyaman',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 26),
          AnimatedContainer(
            duration: const Duration(seconds: 1),
            width: inhaling ? 148 : 114, height: inhaling ? 148 : 114,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: colors.primary.withValues(alpha: .16),
              border: Border.all(color: colors.primary, width: 2)),
            child: Center(child: Text('${inhaling ? 4 - phaseSecond : 10 - phaseSecond}',
                style: Theme.of(context).textTheme.displaySmall)),
          ),
          const SizedBox(height: 26),
          Text('${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')} tersisa',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text('4 detik menarik · 6 detik menghembuskan\nSesuaikan dengan kenyamananmu.',
              textAlign: TextAlign.center, style: TextStyle(height: 1.6)),
          const SizedBox(height: 12),
          TextButton(onPressed: saving ? null : () => perform(() async {
            await ref.read(wellbeingRepositoryProvider).useGrounding();
            ref.invalidate(anxietySessionProvider);
          }), child: const Text('Beralih ke grounding sekarang')),
        ]),
      ),
      if (grounding) MulaCard(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Kenali sekitarmu · 5–4–3–2–1',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('Perhatikan satu hal pada satu waktu. Checklist boleh diselesaikan sesuai kemampuanmu.',
              style: TextStyle(height: 1.6)),
          const SizedBox(height: 12),
          for (var index = 0; index < checks.length; index++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: checks[index],
              title: Text(WellbeingRepository.groundingPrompts[index],
                  style: const TextStyle(fontSize: 14)),
              onChanged: saving ? null : (value) => perform(() async {
                await ref.read(wellbeingRepositoryProvider).setGrounding(index, value ?? false);
                ref.invalidate(anxietySessionProvider);
              }),
            ),
        ])),
      const SizedBox(height: 18),
      MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Cemas sebelum sesi: ${session.number('before')}/10'),
        const SizedBox(height: 14),
        Text('Bagaimana sekarang? ${_after.round()}/10',
            style: Theme.of(context).textTheme.titleMedium),
        Slider(value: _after, min: 1, max: 10, divisions: 9,
          label: '${_after.round()}',
          onChanged: saving ? null : (value) => setState(() => _after = value)),
        const Text('Tidak harus langsung membaik. Catat yang kamu rasakan.',
            style: TextStyle(height: 1.6)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: saving ? null : () => _finish(session),
          icon: const Icon(Icons.check_rounded), label: const Text('Simpan kondisi & akhiri sesi')),
      ])),
    ]);
  }
}
