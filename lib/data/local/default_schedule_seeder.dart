import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Adds defaults once. Existing profile, templates and daily edits survive restarts.
class DefaultScheduleSeeder {
  static Future<void> seed(Database database) async {
    await database.transaction((transaction) async {
      await transaction.insert(
        'users',
        {'id': 1, 'name': 'Anggit', 'createdAt': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      for (var index = 0; index < blocks.length; index++) {
        final block = blocks[index];
        await transaction.insert(
          'schedule_templates',
          {
            'userId': 1,
            'title': block.title,
            'startTime': block.startTime,
            'endTime': block.endTime,
            'category': block.category,
            'sortOrder': index,
            'checklistJson': jsonEncode([
              for (final item in block.checklist) {'title': item, 'done': false},
            ]),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  static String daytimeProject(DateTime day) => switch (day.weekday) {
        DateTime.monday || DateTime.wednesday || DateTime.friday =>
          'Development RUMA App',
        DateTime.tuesday || DateTime.thursday || DateTime.saturday =>
          'Development Sidangode',
        _ => 'Perencanaan pekan dan istirahat',
      };

  static String eveningProject(DateTime day) => switch (day.weekday) {
        DateTime.monday || DateTime.thursday => 'Sidangode',
        DateTime.tuesday || DateTime.friday => 'Personal branding',
        DateTime.wednesday || DateTime.saturday => 'SUKHO RAMEN / evaluasi bisnis',
        _ => 'Perencanaan dan istirahat',
      };

  static const blocks = <ScheduleBlock>[
    ScheduleBlock('Start dan Aktivasi Diri', '04:30', '05:30', 'Wajib', [
      'HP hanya untuk cek jam',
      'Minum 1 gelas air putih',
      'Sholat berjamaah di masjid',
      'Push-up 20x',
      'Archer push-up 10x',
      'Plank 1 menit',
      'Sit-up 20x',
      'Tulis 3–5 prioritas: Top 1 Wajib, Top 2 Penting, Top 3 Jika sempat, keluarga, side job',
    ]),
    ScheduleBlock('Rumah dan Keluarga', '05:30', '07:00', 'Rutinitas', [
      'Sapu rumah', 'Mengepel', 'Mandi', 'Cuci dot', 'Menjaga Alshad',
      'Persiapan berangkat; sisakan buffer 15 menit sebelum 07.00',
    ]),
    ScheduleBlock('Sarapan dan Perjalanan', '07:00', '08:00', 'Rutinitas', [
      'Sarapan bersama istri', 'Berangkat kerja',
      'Fokus perjalanan tanpa scrolling media sosial',
    ]),
    ScheduleBlock('Persiapan Kerja dan Prioritas', '08:00', '09:30', 'Tim', [
      'Aktifkan Hermes Local', 'Seduh kopi',
      'Tulis to-do list tim: 3 slot', 'Tulis to-do list pribadi: 3 slot',
      'Tentukan Top 3; batasi menyusun daftar maksimal 20 menit',
      'Briefing singkat', 'Mulai tugas nomor satu',
    ]),
    ScheduleBlock('Fokus Utama', '09:30', '10:30', 'Wajib', [
      'Kerjakan Development RUMA App, update campaign marketing, atau Top 1',
      'Fokus 50 menit', 'Istirahat 10 menit tanpa HP',
    ]),
    ScheduleBlock('Eksekusi To-Do List', '10:30', '11:45', 'Penting', [
      'Istirahat 10 menit di luar ruangan tanpa HP',
      'Lanjutkan to-do list', 'Cek progres tim seperlunya',
    ]),
    ScheduleBlock('Istirahat Siang', '11:45', '13:00', 'Rutinitas', [
      'Sholat', 'Makan', 'Push-up 20x dan archer push-up 10x jika tubuh siap',
      'Opsional maksimal 1 match VALORANT hanya jika blok pagi tercapai; pasang alarm',
    ]),
    ScheduleBlock('Deep Work Proyek', '13:00', '14:00', 'Penting', [
      'Kerjakan proyek sesuai rotasi hari ini',
      'Boleh override proyek bila ada deadline aktif',
      'Catat hasil konkret blok fokus',
    ]),
    ScheduleBlock('Operasional dan Kontrol Tim', '14:00', '15:00', 'Tim', [
      'Selesaikan to-do list', 'Cek pekerjaan tim',
      'Follow-up tugas tertunda', 'Delegasi', 'Catat hambatan',
    ]),
    ScheduleBlock('Penutupan Pekerjaan', '15:00', '16:00', 'Rutinitas', [
      'Sholat Ashar', 'Latihan ringan jika tubuh siap',
      'Selesaikan tugas penting',
      'Catat status: Selesai, Belum selesai, Hambatan, Langkah pertama besok',
      'Pulang kerja',
    ]),
    ScheduleBlock('Keluarga dan Rumah', '17:00', '20:00', 'Pribadi', [
      '17.00–17.45: transisi sore, double cleanser, push-up 20x, archer push-up 10x, plank 1 menit, sit-up 20x, mandi',
      'Jika lelah: ganti latihan dengan stretching atau jalan kaki',
      '17.45–18.45: bermain dengan Alshad tanpa melihat HP',
      '18.45–20.00: sholat, makan bersama istri, membuat susu',
    ]),
    ScheduleBlock('Perencanaan Side Job', '20:00', '20:45', 'Side Job', [
      'Temani istri menidurkan Alshad',
      'Tulis to-do list untuk 1 proyek sesuai rotasi malam ini',
    ]),
    ScheduleBlock('Deep Work Side Job', '20:45', '21:45', 'Side Job', [
      'Fokus 50 menit pada satu proyek', 'Istirahat 10 menit tanpa media sosial hiburan',
      'Catat hasil 5 menit pada 21.45–21.50 di awal shutdown',
    ]),
    ScheduleBlock('Shutdown Ritual', '21:45', '22:00', 'Side Job', [
      '21.45–21.50: catat hasil hari ini', 'Tulis hambatan',
      'Siapkan jadwal besok', 'Bersiap tidur',
    ]),
  ];
}

class ScheduleBlock {
  const ScheduleBlock(
    this.title, this.startTime, this.endTime, this.category, this.checklist,
  );
  final String title;
  final String startTime;
  final String endTime;
  final String category;
  final List<String> checklist;
}
