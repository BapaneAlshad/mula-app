typedef DbRow = Map<String, Object?>;

extension RowValue on DbRow {
  String text(String key, [String fallback = '']) =>
      this[key]?.toString() ?? fallback;

  int number(String key, [int fallback = 0]) {
    final value = this[key];
    return value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
  }

  bool flag(String key) => this[key] == true || number(key) == 1;
}

class AppSnapshot {
  const AppSnapshot({
    required this.user,
    required this.templates,
    required this.tasks,
    required this.thoughts,
    required this.activeFocus,
    required this.score,
    required this.history,
    required this.preferences,
    required this.date,
  });

  final DbRow user;
  final List<DbRow> templates;
  final List<DbRow> tasks;
  final List<DbRow> thoughts;
  final DbRow? activeFocus;
  final DbRow score;
  final List<DbRow> history;
  final Map<String, String> preferences;
  final String date;
}
