/// A small, offline assistant for turning broad intentions into observable work.
class AbstractTaskSuggestion {
  const AbstractTaskSuggestion({required this.title, required this.steps});

  final String title;
  final List<String> steps;
}

class AbstractTaskConverter {
  const AbstractTaskConverter._();

  static AbstractTaskSuggestion? suggest(String title) {
    final trimmed = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.isEmpty) return null;
    final normalized = trimmed.toLowerCase();

    // Concrete objects and a checkable output already describe useful work.
    if (RegExp(
      r'\b(login|logout|bug|commit|test|testing|halaman|endpoint|fungsi|tabel|'
      r'laporan|dokumen|email|artikel|invoice|form|stretching)\b',
    ).hasMatch(normalized)) {
      return null;
    }
    if (RegExp(r'\b\d+\s+(gelas|halaman|soal|kilometer|km|langkah|poin|item)\b')
        .hasMatch(normalized)) {
      return null;
    }

    final broadStart = RegExp(
      r'^(lanjut(?:kan)?(?:\s+dev(?:elop(?:ment)?)?)?|kerjakan|mengerjakan|'
      r'garap|menggarap|urus|mengurus|bereskan|selesaikan|menyelesaikan)\b',
    ).hasMatch(normalized);
    if (normalized.contains('ruma') && broadStart) {
      return const AbstractTaskSuggestion(
        title: 'Menyelesaikan fungsi login RUMA App dan menjalankan testing',
        steps: ['Menyelesaikan satu alur login', 'Menjalankan testing alur login'],
      );
    }
    if (normalized.contains('sidangode') && broadStart) {
      return const AbstractTaskSuggestion(
        title: 'Menyelesaikan satu bug Sidangode dan membuat satu commit terukur',
        steps: ['Memilih dan memperbaiki satu bug', 'Memeriksa hasil dan membuat satu commit'],
      );
    }
    if (RegExp(r'^(belajar|lanjut belajar|belajar lagi)(\s+\S+){0,4}$')
        .hasMatch(normalized)) {
      return const AbstractTaskSuggestion(
        title: 'Membaca 5 halaman materi dan menulis 3 poin catatan',
        steps: ['Membaca 5 halaman materi', 'Menulis 3 poin yang dipahami'],
      );
    }
    if (RegExp(r'^(olahraga|latihan|bergerak)(\s+\S+){0,2}$')
        .hasMatch(normalized)) {
      return const AbstractTaskSuggestion(
        title: 'Melakukan stretching seluruh tubuh selama 10 menit',
        steps: ['Menyiapkan ruang bergerak', 'Melakukan stretching selama 10 menit'],
      );
    }
    if (RegExp(r'^(bereskan|rapikan|membersihkan|bersihkan) (rumah|kamar|ruangan)$')
        .hasMatch(normalized)) {
      return const AbstractTaskSuggestion(
        title: 'Merapikan meja selama 10 menit dan membuang sampah di meja',
        steps: ['Mengembalikan barang di meja ke tempatnya', 'Membuang sampah di meja'],
      );
    }
    if (RegExp(r'^(kerja|bekerja|lanjut kerja|tugas|proyek|lanjut proyek)$')
        .hasMatch(normalized)) {
      return const AbstractTaskSuggestion(
        title: 'Menyelesaikan satu item tugas utama selama 25 menit dan mencatat hasilnya',
        steps: ['Memilih satu item yang bisa diselesaikan', 'Mengerjakan 25 menit dan mencatat hasil'],
      );
    }
    if (broadStart && trimmed.split(' ').length <= 6) {
      final object = trimmed.replaceFirst(
        RegExp(
          r'^(lanjut(?:kan)?(?:\s+dev(?:elop(?:ment)?)?)?|kerjakan|mengerjakan|'
          r'garap|menggarap|urus|mengurus|bereskan|selesaikan|menyelesaikan)\s*',
          caseSensitive: false,
        ),
        '',
      );
      if (object.isNotEmpty) {
        return AbstractTaskSuggestion(
          title: 'Menyelesaikan satu item $object selama 25 menit dan mencatat hasilnya',
          steps: ['Memilih satu item $object yang bisa diperiksa', 'Mengerjakan 25 menit dan mencatat hasil'],
        );
      }
    }
    return null;
  }
}
