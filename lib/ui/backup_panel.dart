import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/app_snapshot.dart';
import '../services/backup_service.dart';
import 'widgets/shared.dart';

class BackupPanel extends ConsumerStatefulWidget {
  const BackupPanel({super.key, required this.snapshot});
  final AppSnapshot snapshot;

  @override
  ConsumerState<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends ConsumerState<BackupPanel> with PersistedActions<BackupPanel> {
  Future<void> _export() => perform(() async {
    final saved = await actions.exportBackup();
    if (saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cadangan tersimpan di lokasi pilihanmu.')));
    }
  });

  Future<void> _restore() => perform(() async {
    final preview = await actions.inspectBackup();
    if (preview == null || !mounted) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Ganti data dengan cadangan?'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Cadangan dibuat ${_backupDate(preview.createdAt.toIso8601String())}.'),
        const SizedBox(height: 14),
        Text(_summary(preview), style: const TextStyle(height: 1.6)),
        const SizedBox(height: 16),
        const Text('Seluruh data MULA di perangkat ini akan diganti. Sebelum itu, pilih lokasi untuk menyimpan cadangan pengaman data saat ini. Jika penyimpanan dibatalkan, data tidak diganti.', style: TextStyle(height: 1.6)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Simpan pengaman & pulihkan')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    await actions.restoreBackup(preview);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Data cadangan berhasil dipulihkan.')));
    }
  });

  static String _summary(BackupPreview preview) =>
      '${preview.counts['daily_tasks'] ?? 0} tugas · ${preview.counts['daily_scores'] ?? 0} hari progres\n'
      '${preview.counts['focus_sessions'] ?? 0} sesi fokus · ${preview.counts['thought_parkings'] ?? 0} catatan pikiran\n'
      'Profil, jadwal, refleksi, dan pengaturan juga dipulihkan.';

  static String _backupDate(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    return '${displayDate(date.toIso8601String())} ${date.year} · '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final last = widget.snapshot.preferences['lastBackupAt'];
    return MulaCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(Icons.save_alt_rounded, color: colors.primary), const SizedBox(width: 10), Expanded(child: Text('Cadangan & pemulihan', style: Theme.of(context).textTheme.titleMedium))]),
      const SizedBox(height: 12),
      const Text('Simpan tugas, jadwal, progres, dan catatan sebelum ganti HP. File JSON memuat catatan pribadi tanpa enkripsi; simpan di tempat yang kamu percaya.', style: TextStyle(height: 1.6, fontSize: 13)),
      const SizedBox(height: 10),
      Text(last == null ? 'Belum pernah menyimpan cadangan.' : 'Cadangan terakhir: ${_backupDate(last)}', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      const SizedBox(height: 14),
      Wrap(spacing: 10, runSpacing: 8, children: [
        FilledButton.icon(onPressed: saving ? null : _export, icon: const Icon(Icons.download_outlined), label: const Text('Simpan cadangan')),
        OutlinedButton.icon(onPressed: saving ? null : _restore, icon: const Icon(Icons.restore_rounded), label: const Text('Pulihkan cadangan')),
      ]),
      if (saving) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
    ]));
  }
}
