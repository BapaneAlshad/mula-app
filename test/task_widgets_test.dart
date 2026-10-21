import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/features/tasks/presentation/task_card.dart';
import 'package:mula/features/tasks/presentation/task_editor.dart';

void main() {
  testWidgets('task editor validates, converts broad work and saves a complete draft', (tester) async {
    final controller = _TaskController();
    await tester.pumpWidget(_host(controller, editor: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-editor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-task')));
    await tester.pumpAndSettle();
    expect(find.text('Isi judul tugas.'), findsOneWidget);
    expect(controller.saved, isNull);

    await _enter(tester, 'task-title', 'Lanjut dev RUMA App');
    await tester.ensureVisible(find.byKey(const ValueKey('apply-task-conversion')));
    await tester.tap(find.byKey(const ValueKey('apply-task-conversion')));
    await tester.pumpAndSettle();
    final title = tester.widget<TextFormField>(find.byKey(const ValueKey('task-title'))).controller!.text;
    expect(title, contains('fungsi login RUMA App'));
    expect(find.byKey(const ValueKey('apply-task-conversion')), findsNothing);
    await _enter(tester, 'task-description', 'Uji alur berhasil dan gagal.');
    await _enter(tester, 'task-minutes', '35');
    await _select(tester, 'task-energy', 'Rendah');
    await _enter(tester, 'task-point-weight', '60');

    await tester.ensureVisible(find.byKey(const ValueKey('task-deadline')));
    await tester.tap(find.byKey(const ValueKey('task-deadline')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-task')));
    await tester.pumpAndSettle();

    expect(controller.saved, isNotNull);
    final saved = controller.saved!;
    expect(saved['title'], title);
    expect(saved['description'], 'Uji alur berhasil dan gagal.');
    expect(saved['category'], 'Tim');
    expect(saved['priority'], 'Top 3');
    expect(saved['estimatedMinutes'], 35);
    expect(saved['energyLevel'], 'Rendah');
    expect(saved['pointWeight'], 60);
    expect(saved['subtasks'], hasLength(2));
    expect(DateTime.parse(saved.text('deadline')), DateTime(2026, 10, 21, 8).toUtc());
    expect(find.byKey(const ValueKey('task-title')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save retains the editable draft and succeeds when retried', (tester) async {
    final controller = _TaskController()..failSave = true;
    await tester.pumpWidget(_host(controller, editor: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-editor')));
    await tester.pumpAndSettle();
    await _enter(tester, 'task-title', 'Menulis laporan pengujian');
    await tester.tap(find.byKey(const ValueKey('save-task')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-save-error')), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('task-title'))).controller!.text, 'Menulis laporan pengujian');
    expect(controller.saved, isNull);

    controller.failSave = false;
    await tester.tap(find.byKey(const ValueKey('save-task')));
    await tester.pumpAndSettle();
    expect(controller.saved!.text('title'), 'Menulis laporan pengujian');
    expect(find.byKey(const ValueKey('task-save-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right swipe keeps the task visible and Undo restores the full captured row', (tester) async {
    final controller = _TaskController();
    await tester.pumpWidget(_host(controller, cardId: 1));
    await tester.pumpAndSettle();
    final before = Map<String, Object?>.from(controller.tasks.first);
    await tester.drag(find.byKey(const ValueKey('task-swipe-1')), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(controller.tasks.first.text('status'), 'Selesai');
    expect(find.text('Menulis laporan pengujian'), findsOneWidget);
    final snackbar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackbar.duration, const Duration(seconds: 5));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(controller.tasks.first, before);
    expect(controller.undoCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('left swipe requires a reason before persisting a skipped task', (tester) async {
    final controller = _TaskController();
    await tester.pumpWidget(_host(controller, cardId: 1));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('task-swipe-1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Lewati dengan alasan'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-task-status')));
    await tester.pumpAndSettle();
    expect(find.text('Pilih atau tulis alasan singkat.'), findsOneWidget);
    expect(controller.tasks.first.text('status'), 'Belum mulai');
    await _enter(tester, 'task-status-note', 'Menunggu akses dari tim.');
    await tester.tap(find.byKey(const ValueKey('save-task-status')));
    await tester.pumpAndSettle();
    expect(controller.tasks.first.text('status'), 'Dilewati');
    expect(controller.tasks.first.text('skippedReason'), 'Menunggu akses dari tim.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Top 2 focus requires an explicit soft gate override', (tester) async {
    final controller = _TaskController();
    await tester.pumpWidget(_host(controller, cardId: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Memperbaiki bug profil'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mulai fokus 25 menit'));
    await tester.tap(find.text('Mulai fokus 25 menit'));
    await tester.pumpAndSettle();
    expect(find.text('Beri Top 1 langkah pertama'), findsOneWidget);
    await tester.tap(find.text('Kembali ke Top 1'));
    await tester.pumpAndSettle();
    expect(controller.focusOverrides, isEmpty);

    await tester.tap(find.text('Mulai fokus 25 menit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tetap mulai sekali ini'));
    await tester.pumpAndSettle();
    expect(controller.focusOverrides, [true]);
    expect(controller.selectedTab, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

Widget _host(_TaskController controller, {bool editor = false, int? cardId}) => ProviderScope(
  overrides: [
    appControllerProvider.overrideWith(() => controller),
    clockProvider.overrideWithValue(DateTime(2026, 10, 21, 8)),
  ],
  child: MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(body: Consumer(builder: (context, ref, child) {
      final snapshot = ref.watch(appControllerProvider).valueOrNull;
      if (snapshot == null) return const SizedBox.shrink();
      return SingleChildScrollView(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          if (editor) FilledButton(
            key: const ValueKey('open-editor'),
            onPressed: () => showTaskEditor(context, ref, initialCategory: 'Tim', initialPriority: 'Top 3'),
            child: const Text('Olah tugas'),
          ),
          if (cardId != null) TaskCard(task: snapshot.tasks.singleWhere((task) => task.number('id') == cardId)),
        ]),
      ));
    })),
  ),
);

class _TaskController extends AppController {
  final List<DbRow> tasks = [
    {'id': 1, 'date': '2026-10-21', 'title': 'Menulis laporan pengujian', 'category': 'Tim',
      'priority': 'Top 1', 'status': 'Belum mulai', 'estimatedMinutes': 25, 'energyLevel': 'Sedang',
      'points': 12, 'subtasksJson': '[{"title":"Catat hasil","done":true},{"title":"Periksa hasil","done":false}]'},
    {'id': 2, 'date': '2026-10-21', 'title': 'Memperbaiki bug profil', 'category': 'Tim',
      'priority': 'Top 2', 'status': 'Belum mulai', 'estimatedMinutes': 25, 'energyLevel': 'Rendah', 'points': 8},
  ];
  DbRow? saved;
  bool failSave = false;
  int undoCount = 0;
  int selectedTab = 0;
  final List<bool> focusOverrides = [];

  AppSnapshot _snapshot() => AppSnapshot(
    user: const {'id': 1, 'name': 'Anggit'},
    templates: const [],
    tasks: tasks.map((task) => Map<String, Object?>.from(task)).toList(),
    thoughts: const [],
    activeFocus: null,
    score: const {'totalScore': 0},
    history: const [],
    preferences: {'selectedTab': '$selectedTab'},
    date: '2026-10-21',
  );

  @override
  Future<AppSnapshot> build() async => _snapshot();

  @override
  Future<void> saveTask({int? taskId, required String title, required String description,
    required String category, String? deadline, required int estimatedMinutes,
    required String energyLevel, required String priority, required List<DbRow> subtasks,
    required int pointWeight}) async {
    if (failSave) throw StateError('Penyimpanan tes sementara gagal.');
    saved = {'id': taskId, 'title': title, 'description': description, 'category': category,
      'deadline': deadline, 'estimatedMinutes': estimatedMinutes, 'energyLevel': energyLevel,
      'priority': priority, 'subtasks': subtasks, 'pointWeight': pointWeight};
  }

  @override
  Future<DbRow> completeTaskWithUndo(int taskId) async {
    final task = tasks.singleWhere((task) => task.number('id') == taskId);
    final previous = Map<String, Object?>.from(task);
    task['status'] = 'Selesai';
    task['subtasksJson'] = jsonEncode([
      {'title': 'Catat hasil', 'done': true}, {'title': 'Periksa hasil', 'done': true},
    ]);
    state = AsyncData(_snapshot());
    return previous;
  }

  @override
  Future<void> restoreTask(DbRow previous) async {
    final index = tasks.indexWhere((task) => task['id'] == previous['id']);
    tasks[index] = Map<String, Object?>.from(previous);
    undoCount++;
    state = AsyncData(_snapshot());
  }

  @override
  Future<void> setTaskStatus(int id, String status, {String? reason}) async {
    final task = tasks.singleWhere((task) => task.number('id') == id);
    task['status'] = status;
    task['skippedReason'] = reason;
    state = AsyncData(_snapshot());
  }

  @override
  Future<void> startFocus({int? taskId, required int plannedSeconds, required String mode,
    bool allowPriorityOverride = false}) async {
    focusOverrides.add(allowPriorityOverride);
  }

  @override
  Future<void> setSelectedTab(int index) async {
    selectedTab = index;
    state = AsyncData(_snapshot());
  }
}
