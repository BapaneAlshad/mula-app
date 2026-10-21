import 'package:flutter_test/flutter_test.dart';
import 'package:mula/features/tasks/domain/abstract_task_converter.dart';

void main() {
  test('broad RUMA and Sidangode intentions receive concrete offline actions', () {
    final ruma = AbstractTaskConverter.suggest('  Lanjut dev   RUMA App  ');
    expect(ruma, isNotNull);
    expect(ruma!.title, contains('fungsi login RUMA App'));
    expect(ruma.title, contains('testing'));
    expect(ruma.steps, hasLength(2));

    final sidangode = AbstractTaskConverter.suggest('Kerjakan Sidangode');
    expect(sidangode!.title, contains('satu bug Sidangode'));
    expect(sidangode.title, contains('satu commit'));
  });

  test('measurable deliverables are not replaced or repeatedly converted', () {
    for (final title in [
      'Menyelesaikan fungsi login dan menjalankan testing',
      'Memperbaiki bug Sidangode pada halaman profil',
      'Membaca 5 halaman materi',
      'Minum 2 gelas air',
      'Menulis laporan pengujian RUMA App',
    ]) {
      expect(AbstractTaskConverter.suggest(title), isNull, reason: title);
    }
    for (final title in ['Lanjut dev RUMA App', 'Kerjakan Sidangode', 'Belajar', 'Olahraga', 'Kerja']) {
      final suggestion = AbstractTaskConverter.suggest(title)!;
      expect(AbstractTaskConverter.suggest(suggestion.title), isNull, reason: suggestion.title);
    }
  });

  test('generic work gets a limited action while blank input stays blank', () {
    expect(AbstractTaskConverter.suggest('  '), isNull);
    final suggestion = AbstractTaskConverter.suggest('Kerjakan proyek pelanggan');
    expect(suggestion!.title, contains('proyek pelanggan'));
    expect(suggestion.title, contains('25 menit'));
    expect(suggestion.title, contains('mencatat hasilnya'));
    expect(AbstractTaskConverter.suggest('Belajar')!.title, contains('3 poin catatan'));
  });
}
