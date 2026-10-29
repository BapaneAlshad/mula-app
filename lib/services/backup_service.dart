import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../data/local/app_database.dart';

abstract class BackupDocuments {
  Future<bool> save(String filename, String contents);
  Future<String?> open();
}

class AndroidBackupDocuments implements BackupDocuments {
  static const _channel = MethodChannel('mula/device');

  @override
  Future<bool> save(String filename, String contents) async =>
      await _channel.invokeMethod<bool>('saveBackupDocument', {
        'filename': filename,
        'contents': contents,
      }) ?? false;

  @override
  Future<String?> open() => _channel.invokeMethod<String>('openBackupDocument');
}

class BackupPreview {
  BackupPreview._(this._source, this.createdAt, Map<String, int> counts)
      : counts = Map.unmodifiable(counts);

  final String _source;
  final DateTime createdAt;
  final Map<String, int> counts;
  int get totalRows => counts.values.fold(0, (sum, count) => sum + count);
}

/// Portable, versioned snapshots read under a SQLite transaction. Restores use
/// SQL inserts with foreign keys enabled; any invalid row rolls everything back.
class BackupService {
  BackupService(this._database, {BackupDocuments? documents, DateTime Function()? now})
      : _documents = documents ?? AndroidBackupDocuments(),
        _now = now ?? DateTime.now;

  final AppDatabase _database;
  final BackupDocuments _documents;
  final DateTime Function() _now;
  static const maxBytes = 8 * 1024 * 1024;
  static const _tables = [
    'users', 'schedule_templates', 'daily_tasks', 'focus_sessions',
    'thought_parkings', 'anxiety_sessions', 'daily_scores', 'app_preferences',
    'planning_sessions', 'valorant_sessions',
  ];

  Future<String> encodeBackup() async {
    final database = await _database.database;
    return database.transaction((transaction) async {
      final tables = <String, Object?>{};
      for (final table in _tables) {
        tables[table] = await transaction.query(table);
      }
      _ensureIdle(tables);
      final version = Sqflite.firstIntValue(await transaction.rawQuery('PRAGMA user_version'))!;
      final contents = jsonEncode({
        'app': 'MULA', 'formatVersion': 1, 'schemaVersion': version,
        'createdAt': _now().toUtc().toIso8601String(), 'tables': tables,
      });
      _checkSize(contents);
      return contents;
    });
  }

  Future<bool> exportBackup() async {
    final contents = await encodeBackup();
    final saved = await _documents.save(_filename('cadangan'), contents);
    if (saved) {
      final database = await _database.database;
      await database.insert('app_preferences', {
        'key': 'lastBackupAt', 'value': _now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return saved;
  }

  Future<BackupPreview?> inspectBackup() async {
    final contents = await _documents.open();
    return contents == null ? null : inspect(contents);
  }

  Future<BackupPreview> inspect(String contents) async {
    final database = await _database.database;
    final decoded = await _decode(contents, database);
    return BackupPreview._(contents, DateTime.parse(decoded['createdAt'] as String), {
      for (final entry in (decoded['tables'] as Map<String, Object?>).entries)
        entry.key: (entry.value as List).length,
    });
  }

  /// A separate recovery document must be saved before replacing anything.
  Future<void> restoreBackup(BackupPreview preview) async {
    final database = await _database.database;
    final decoded = await _decode(preview._source, database);
    final recovery = await encodeBackup();
    final recoveryTables = (jsonDecode(recovery) as Map<String, dynamic>)['tables'] as Map<String, dynamic>;
    final expectedSnapshot = _snapshotSignature(recoveryTables);
    if (!await _documents.save(_filename('sebelum-pemulihan'), recovery)) {
      throw StateError('Pemulihan dibatalkan. Cadangan data saat ini belum disimpan.');
    }
    final tables = decoded['tables'] as Map<String, Object?>;
    await database.transaction((transaction) async {
      final current = <String, Object?>{};
      for (final table in _tables) {
        current[table] = await transaction.query(table);
      }
      _ensureIdle(current);
      if (_snapshotSignature(current) != expectedSnapshot) {
        throw StateError('Data berubah saat lokasi cadangan dipilih. Tidak ada data yang diganti; ulangi pemulihan untuk menyimpan cadangan pengaman terbaru.');
      }
      for (final table in _tables.reversed) {
        await transaction.delete(table);
      }
      for (final table in _tables) {
        for (final value in tables[table] as List) {
          final row = Map<String, Object?>.from(value as Map);
          if (table == 'app_preferences' &&
              (row['key'].toString().startsWith('alarmTest') ||
               ['lastUnlockAt', 'anxietySession', 'reminderStatus'].contains(row['key']))) {
            continue;
          }
          await transaction.insert(table, row);
        }
      }
      final brokenReferences = await transaction.rawQuery('PRAGMA foreign_key_check');
      if (brokenReferences.isNotEmpty) {
        throw const FormatException('Relasi data dalam cadangan tidak valid.');
      }
      await transaction.insert('app_preferences', {
        'key': 'lastRestoreAt', 'value': _now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  String _filename(String kind) =>
      'mula-$kind-${_now().toUtc().toIso8601String().replaceAll(':', '-')}.json';

  // Compare complete rows independently of SQLite's unspecified SELECT order.
  // This catches writes from other providers or background engines while the
  // native save picker is open, before any DELETE can run.
  static String _snapshotSignature(Map<String, Object?> tables) => jsonEncode({
    for (final table in _tables)
      table: (tables[table] as List).map((value) {
        final row = value as Map;
        final keys = row.keys.cast<String>().toList()..sort();
        return jsonEncode({for (final key in keys) key: row[key]});
      }).toList()..sort(),
  });

  static void _checkSize(String contents) {
    if (contents.length > maxBytes || utf8.encode(contents).length > maxBytes) {
      throw const FormatException('Ukuran cadangan melebihi batas 8 MB.');
    }
  }

  Future<Map<String, Object?>> _decode(String contents, DatabaseExecutor database) async {
    _checkSize(contents);
    final Object? value;
    try {
      value = jsonDecode(contents);
    } on FormatException {
      throw const FormatException('Berkas bukan cadangan JSON MULA yang valid.');
    }
    if (value is! Map<String, dynamic> || value['app'] != 'MULA' ||
        value['formatVersion'] != 1 || value['schemaVersion'] is! int) {
      throw const FormatException('Format cadangan tidak didukung.');
    }
    final version = Sqflite.firstIntValue(await database.rawQuery('PRAGMA user_version'))!;
    if (value['schemaVersion'] != version) {
      throw const FormatException('Versi database cadangan tidak didukung aplikasi ini.');
    }
    if (value['createdAt'] is! String || DateTime.tryParse(value['createdAt'] as String) == null) {
      throw const FormatException('Tanggal cadangan tidak valid.');
    }
    final tables = value['tables'];
    if (tables is! Map<String, dynamic> || tables.length != _tables.length ||
        !_tables.every(tables.containsKey)) {
      throw const FormatException('Daftar tabel cadangan tidak lengkap atau tidak dikenal.');
    }
    var count = 0;
    for (final table in _tables) {
      final rows = tables[table];
      if (rows is! List || rows.length > 50000) {
        throw const FormatException('Jumlah data dalam cadangan tidak valid.');
      }
      count += rows.length;
      if (count > 100000) throw const FormatException('Cadangan memuat terlalu banyak data.');
      // Table identifiers are hard-coded above, never supplied by a document.
      final schema = await database.rawQuery('PRAGMA table_info($table)');
      final columns = {for (final column in schema) column['name'] as String: column};
      for (final row in rows) {
        if (row is! Map<String, dynamic> || row.length != columns.length ||
            row.keys.any((key) => !columns.containsKey(key)) ||
            columns.keys.any((key) => !row.containsKey(key))) {
          throw FormatException('Kolom tidak lengkap atau tidak dikenal pada $table.');
        }
        for (final entry in row.entries) {
          final field = entry.value;
          if (field != null && field is! String && field is! int) {
            throw FormatException('Tipe data ${entry.key} pada $table tidak valid.');
          }
          final type = columns[entry.key]!['type'] as String;
          if ((field != null && type == 'INTEGER' && field is! int) ||
              (field != null && type == 'TEXT' && field is! String) ||
              (field is String && field.length > 100000)) {
            throw FormatException('Nilai ${entry.key} pada $table tidak valid.');
          }
        }
        for (final column in columns.values) {
          final key = column['name'] as String;
          if (column['notnull'] == 1 && row[key] == null) {
            throw FormatException('Kolom wajib $key pada $table belum diisi.');
          }
        }
        if (table != 'app_preferences' && (row['id'] is! int || (row['id'] as int) < 1)) {
          throw FormatException('Identitas data pada $table tidak valid.');
        }
        if (table != 'users' && table != 'app_preferences' && row['userId'] != 1) {
          throw const FormatException('Cadangan harus berisi satu profil MULA.');
        }
        _validateContent(table, row);
      }
    }
    if ((tables['users'] as List).length != 1 ||
        ((tables['users'] as List).single as Map)['id'] != 1) {
      throw const FormatException('Profil pemilik cadangan tidak valid.');
    }
    _ensureIdle(tables);
    return Map<String, Object?>.from(value);
  }

  static void _validateContent(String table, Map<String, dynamic> row) {
    if (table == 'app_preferences' &&
        (row['key'] is! String || (row['key'] as String).isEmpty ||
         (row['key'] as String).length > 100 || row['value'] is! String)) {
      throw const FormatException('Kunci preferensi cadangan tidak valid.');
    }
    for (final key in ['createdAt', 'completedAt', 'startedAt', 'deadlineAt',
        'alarmAt', 'cutoffAt', 'confirmedAt', 'reviewAt', 'deadline']) {
      final value = row[key];
      if (value != null && (value is! String || DateTime.tryParse(value) == null)) {
        throw FormatException('Timestamp $key pada $table tidak valid.');
      }
    }
    for (final key in ['startTime', 'endTime', 'scheduleStartTime', 'scheduleEndTime', 'wakeTime', 'sleepTime', 'workStartTime', 'workEndTime']) {
      final value = row[key];
      if (value != null && (value is! String ||
          !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value))) {
        throw FormatException('Jam $key pada $table tidak valid.');
      }
    }
    for (final key in ['date', 'effectiveFrom']) {
      if (!row.containsKey(key) || row[key] == '') continue;
      final date = row[key];
      final parsed = date is String ? DateTime.tryParse(date) : null;
      if (parsed == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date as String) ||
          '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}' != date) {
        throw FormatException('Tanggal pada $table tidak valid.');
      }
    }
    for (final key in ['checklistJson', 'subtasksJson', 'daysOfWeek']) {
      if (!row.containsKey(key)) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(row[key] as String);
      } catch (_) {
        throw FormatException('Daftar $key pada $table tidak valid.');
      }
      if (decoded is! List || decoded.length > 1000) {
        throw FormatException('Daftar $key pada $table tidak valid.');
      }
      if (key == 'daysOfWeek') {
        if (decoded.isEmpty || decoded.length > 7 || decoded.toSet().length != decoded.length ||
            decoded.any((day) => day is! int || day < 1 || day > 7)) {
          throw const FormatException('Hari jadwal tidak valid.');
        }
      } else if (decoded.any((item) => item is! Map || item['title'] is! String || item['done'] is! bool)) {
        throw FormatException('Checklist pada $table tidak valid.');
      }
    }
  }

  static void _ensureIdle(Map<String, Object?> tables) {
    for (final table in ['focus_sessions', 'planning_sessions', 'valorant_sessions']) {
      final rows = tables[table] as List? ?? const [];
      if (rows.any((row) => (row as Map)['status'] == 'Berjalan')) {
        throw StateError('Akhiri sesi fokus, perencanaan, dan game sebelum membuat atau memulihkan cadangan.');
      }
    }
    final preferences = tables['app_preferences'] as List? ?? const [];
    if (preferences.any((row) => (row as Map)['key'] == 'anxietySession' &&
        !['', 'null'].contains(row['value']))) {
      throw StateError('Selesaikan sesi ruang tenang sebelum membuat atau memulihkan cadangan.');
    }
  }
}
