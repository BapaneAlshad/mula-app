import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_controller.dart';
import '../domain/app_snapshot.dart';
import '../services/alarm_diagnostics_service.dart';
import 'widgets/shared.dart';

class AlarmDiagnosticsPanel extends StatelessWidget {
  const AlarmDiagnosticsPanel({super.key});

  @override
  Widget build(BuildContext context) => MulaCard(child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Alarm di perangkatmu', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      const Text('Periksa izin Android dan uji alarm satu menit dengan layar terkunci.',
          style: TextStyle(fontSize: 13, height: 1.6)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const AlarmDiagnosticsPage())),
        icon: const Icon(Icons.alarm_on_outlined),
        label: const Text('Periksa alarm di HP'),
      ),
    ],
  ));
}

class AlarmDiagnosticsPage extends ConsumerStatefulWidget {
  const AlarmDiagnosticsPage({super.key});

  @override
  ConsumerState<AlarmDiagnosticsPage> createState() => _AlarmDiagnosticsPageState();
}

class _AlarmDiagnosticsPageState extends ConsumerState<AlarmDiagnosticsPage>
    with WidgetsBindingObserver {
  bool _saving = false;
  AlarmDiagnosticsController get _actions => ref.read(alarmDiagnosticsProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_saving) {
      _perform(_actions.refresh);
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Pemeriksaan belum selesai: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _time(DateTime value) =>
      '${value.toLocal().hour.toString().padLeft(2, '0')}:'
      '${value.toLocal().minute.toString().padLeft(2, '0')}:'
      '${value.toLocal().second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final diagnostics = ref.watch(alarmDiagnosticsProvider);
    final now = ref.watch(clockProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Periksa alarm di HP')),
      body: diagnostics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListView(padding: const EdgeInsets.all(22), children: [
          Text('Pemeriksaan belum dapat dibuka: $error'),
          const SizedBox(height: 16),
          FilledButton(onPressed: _saving ? null : () => _perform(_actions.refresh),
              child: const Text('Coba periksa lagi')),
        ]),
        data: (data) {
          final status = data.deviceStatus;
          final test = data.test;
          final due = data.isDue(now);
          final pending = data.awaitingResult && !due;
          final dueAt = data.dueAt;
          final remaining = dueAt == null ? 0 : dueAt.difference(now).inSeconds.clamp(0, 60);
          return ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
            const Text('Uji ini perlu kamu jalankan di HP yang dipakai sehari-hari. '
                'Izin aktif belum membuktikan bunyi alarm terdengar saat layar terkunci.',
                style: TextStyle(height: 1.6)),
            const SizedBox(height: 20),
            if (_saving) const LinearProgressIndicator(),
            if (status != null) ...[
              Text('${status.device} · Android ${status.androidVersion}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 14),
              MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _StatusLine(title: 'Notifikasi', enabled: status.notificationsAllowed),
                _StatusLine(title: 'Alarm presisi', enabled: status.exactAlarmsAllowed),
                _StatusLine(title: 'Kanal uji alarm', enabled: status.testChannelAllowed),
                _StatusLine(title: 'Bebas optimasi baterai', enabled: status.batteryUnrestricted),
                if (status.doNotDisturb) const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Jangan Ganggu sedang aktif. Bunyi alarm mengikuti pengaturan Android.'),
                ),
                if (!status.batteryUnrestricted) const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Pembatasan baterai dapat memengaruhi pengingat. '
                      'Periksa pengaturan baterai MULA pada HP ini.'),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton(onPressed: _saving ? null : () => _perform(_actions.requestNotifications),
                      child: const Text('Minta izin notifikasi')),
                  TextButton(onPressed: _saving ? null : () => _perform(() => _actions.openSettings('notifications')),
                      child: const Text('Pengaturan notifikasi')),
                  TextButton(onPressed: _saving ? null : () => _perform(() => _actions.openSettings('exact')),
                      child: const Text('Izin alarm presisi')),
                  TextButton(onPressed: _saving ? null : () => _perform(() => _actions.openSettings('battery')),
                      child: const Text('Pengaturan baterai')),
                ]),
              ])),
              const SizedBox(height: 18),
            ],
            if (data.deviceError != null) ...[
              Text(data.deviceError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _perform(_actions.refresh),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Periksa ulang izin'),
            ),
            const SizedBox(height: 20),
            MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Uji dengan layar terkunci', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              const Text('1. Atur volume alarm dan notifikasi agar terdengar.\n'
                  '2. Jadwalkan uji, lalu kunci layar HP selama satu menit.\n'
                  '3. Setelah waktunya lewat, kembali dan catat apakah alarm terdengar.\n'
                  'Ulangi setelah mengubah izin atau pengaturan baterai.',
                  style: TextStyle(fontSize: 13, height: 1.7)),
              const SizedBox(height: 18),
              if (test != null) ...[
                Text(switch (test.text('status')) {
                  'scheduled' when !due => 'Alarm dijadwalkan pukul ${_time(dueAt!)} · sekitar $remaining detik lagi.',
                  'scheduled' => 'Waktu uji sudah lewat. Bagaimana hasilnya saat layar terkunci?',
                  'received' => 'Kamu mengonfirmasi alarm terdengar saat uji terakhir.',
                  'notReceived' => 'Kamu mencatat alarm belum terdengar. Periksa izin dan pengaturan HP, lalu uji ulang.',
                  'cancelled' => 'Uji terakhir dibatalkan.',
                  'failed' => 'Alarm uji belum berhasil dipasang: ${test.text('error')}',
                  'scheduling' => 'Pemasangan uji sebelumnya belum terkonfirmasi. Batalkan atau jadwalkan ulang.',
                  _ => test.text('error', 'Belum ada hasil uji yang terkonfirmasi.'),
                }, style: const TextStyle(height: 1.6)),
                if (test.text('confirmedAt').isNotEmpty) Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Dicatat ${test.text('confirmedAt')}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                const SizedBox(height: 14),
              ],
              if (data.awaitingResult && due) Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: _saving ? null : () => _perform(() => _actions.recordResult(true)),
                  icon: const Icon(Icons.hearing_rounded), label: const Text('Alarm terdengar'),
                ),
                OutlinedButton(
                  onPressed: _saving ? null : () => _perform(() => _actions.recordResult(false)),
                  child: const Text('Belum terdengar'),
                ),
              ]),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _saving || pending || status?.canTest != true
                    ? null : () => _perform(_actions.startTest),
                icon: const Icon(Icons.alarm_add_rounded),
                label: const Text('Jadwalkan uji 1 menit'),
              ),
              if (data.awaitingResult || test?.text('status') == 'scheduling') TextButton(
                onPressed: _saving ? null : () => _perform(_actions.cancelTest),
                child: const Text('Batalkan uji'),
              ),
              if (status != null && !status.canTest) const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Aktifkan notifikasi, kanal uji, dan alarm presisi sebelum menjadwalkan uji.'),
              ),
            ])),
          ]);
        },
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.title, required this.enabled});
  final String title;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      Icon(enabled ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded,
          color: enabled ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
          size: 21),
      const SizedBox(width: 10),
      Expanded(child: Text(title)),
      Text(enabled ? 'Aktif' : 'Belum aktif', style: Theme.of(context).textTheme.bodySmall),
    ]),
  );
}
