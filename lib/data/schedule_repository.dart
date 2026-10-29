import 'dart:convert';

import '../domain/app_snapshot.dart';
import 'local/app_database.dart';
import 'mula_repository.dart';

/// Recurring edits take effect tomorrow; daily task snapshots retain history.
class ScheduleRepository {
  ScheduleRepository(this.database, {DateTime Function()? now}) : now = now ?? DateTime.now;
  final AppDatabase database;
  final DateTime Function() now;
  static const categories = ['Wajib', 'Penting', 'Jika Sempat', 'Rutinitas', 'Tim', 'Pribadi', 'Side Job'];

  Future<void> save({int? id, required String title, required String startTime,
    required String endTime, required String category, required List<int> days,
    required bool active, required List<String> checklist}) async {
    if (title.trim().isEmpty || title.trim().length > 160) {
      throw ArgumentError('Judul harus berisi 1–160 karakter.');
    }
    final start = _minutes(startTime);
    final end = _minutes(endTime);
    if (end <= start) throw ArgumentError('Jam selesai harus setelah jam mulai pada hari yang sama.');
    if (!categories.contains(category)) throw ArgumentError('Kategori tidak valid.');
    if (days.isEmpty || days.toSet().length != days.length || days.any((day) => day < 1 || day > 7)) {
      throw ArgumentError('Pilih setidaknya satu hari yang valid.');
    }
    if (checklist.length > 30 || checklist.any((item) => item.trim().isEmpty || item.length > 300)) {
      throw ArgumentError('Maksimal 30 checklist, masing-masing 1–300 karakter.');
    }
    final db = await database.database;
    await db.transaction((transaction) async {
      final templates = await transaction.query('schedule_templates', where: 'userId = 1');
      if (id != null && !templates.any((row) => row.number('id') == id)) {
        throw StateError('Blok jadwal tidak ditemukan.');
      }
      if (active) {
        for (final other in templates.where((row) => row.flag('isActive') && row.number('id') != id)) {
          final otherDays = (jsonDecode(other.text('daysOfWeek')) as List).cast<int>();
          if (days.any(otherDays.contains) && start < _minutes(other.text('endTime')) &&
              end > _minutes(other.text('startTime'))) {
            throw StateError('Bertabrakan dengan blok “${other.text('title')}”. Ubah jam atau harinya.');
          }
        }
      }
      final tomorrow = now().add(const Duration(days: 1));
      final values = <String, Object?>{
        'userId': 1, 'title': title.trim(), 'startTime': startTime, 'endTime': endTime,
        'category': category, 'daysOfWeek': jsonEncode(days.toList()..sort()),
        'isActive': active ? 1 : 0, 'effectiveFrom': MulaRepository.dateKey(tomorrow),
        'checklistJson': jsonEncode([for (final item in checklist) {'title': item.trim(), 'done': false}]),
      };
      if (id == null) {
        final orders = templates.map((row) => row.number('sortOrder')).toList()..sort();
        values['sortOrder'] = orders.isEmpty || orders.last < 1000 ? 1000 : orders.last + 1;
        await transaction.insert('schedule_templates', values);
      } else {
        await transaction.update('schedule_templates', values, where: 'id = ? AND userId = 1', whereArgs: [id]);
      }
    });
  }

  static int _minutes(String value) {
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
      throw ArgumentError('Gunakan jam HH:mm yang valid.');
    }
    final parts = value.split(':').map(int.parse).toList();
    return parts[0] * 60 + parts[1];
  }
}
