import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/features/today/presentation/today_page.dart';
import 'package:mula/features/wellbeing/application/wellbeing_providers.dart';
import 'package:mula/features/wellbeing/presentation/anxiety_session_page.dart';

void main() {
  testWidgets('quick actions work at narrow phone width', (tester) async {
    _viewport(tester, const Size(320, 1800));
    final controller = _TodayController(_snapshot());
    await tester.pumpWidget(_page(controller));
    await tester.pumpAndSettle();

    expect(find.text('23/100'), findsOneWidget);
    expect(find.text('Tambah Tugas'), findsOneWidget);
    expect(find.text('Mulai 5 Menit'), findsOneWidget);
    expect(find.text('Saya sedang cemas'), findsOneWidget);
    expect(find.text('Parkir Pikiran'), findsOneWidget);
    await tester.tap(find.text('Mulai 5 Menit'));
    await tester.pumpAndSettle();
    expect(controller.fiveMinuteStarts, 1);
    expect(controller.selectedTabs, [1]);
    await tester.tap(find.text('Saya sedang cemas'));
    await tester.pumpAndSettle();
    expect(controller.sanctuaryReason, 'Cemas');
    expect(find.byType(AnxietySessionPage), findsOneWidget);
    expect(find.text('Mulai sesi tenang'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AnxietySessionPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('minimum mode replaces dense schedule with seven saved checks',
      (tester) async {
    _viewport(tester, const Size(500, 2300));
    final controller = _TodayController(_snapshot(mode: 'Minimum'));
    await tester.pumpWidget(_page(controller));
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsNWidgets(7));
    expect(find.text('Blok jadwal padat'), findsNothing);
    expect(find.text('PRIORITAS HARI INI'), findsNothing);
    expect(find.text('Ritme hari ini'), findsNothing);
    expect(find.text('Sholat'), findsOneWidget);
    expect(find.text('Tidur lebih awal'), findsOneWidget);

    await tester.tap(find.text('Sholat'));
    await tester.pumpAndSettle();
    expect(controller.savedStatuses, [(101, 'Selesai')]);
    final first = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile).first,
    );
    expect(first.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adaptation requires one of six valid reasons before saving',
      (tester) async {
    _viewport(tester, const Size(500, 1600));
    final controller = _TodayController(_snapshot());
    await tester.pumpWidget(_page(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hari Adaptasi'));
    await tester.pumpAndSettle();
    expect(controller.savedMode, isNull);
    for (final reason in const [
      'Sakit',
      'Kondisi keluarga',
      'Tugas darurat',
      'Kelelahan berat',
      'Perjalanan',
      'Acara/kewajiban penting',
    ]) {
      expect(find.text(reason), findsOneWidget);
    }
    await tester.tap(find.text('Sakit'));
    await tester.pumpAndSettle();
    expect(controller.savedMode, 'Adaptasi');
    expect(controller.savedReason, 'Sakit');
    expect(find.textContaining('streak tetap terjaga'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an open game still requires closing confirmation in minimum mode',
      (tester) async {
    _viewport(tester, const Size(500, 2300));
    final controller = _TodayController(_snapshot(
      mode: 'Minimum',
      game: {
        'id': 42,
        'startedAt': '2026-10-21T11:50:00',
        'alarmAt': '2026-10-21T12:35:00',
        'cutoffAt': '2026-10-21T13:00:00',
        'confirmedAt': null,
        'status': 'Berjalan',
      },
    ));
    await tester.pumpWidget(_page(controller, now: DateTime(2026, 10, 21, 13, 5)));
    await tester.pumpAndSettle();

    expect(find.text('Main 1 Match VALORANT'), findsOneWidget);
    expect(find.textContaining('Akses VALORANT besok dikunci'), findsOneWidget);
    final confirm = find.text('Game Sudah Ditutup & Kembali Bekerja');
    expect(confirm, findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(controller.gameConfirmations, 1);
    expect(confirm, findsNothing);
    expect(find.byType(CheckboxListTile), findsNWidgets(7));
    expect(tester.takeException(), isNull);
  });
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _page(_TodayController controller, {DateTime? now}) => ProviderScope(
      overrides: [
        appControllerProvider.overrideWith(() => controller),
        clockProvider.overrideWithValue(now ?? DateTime(2026, 10, 21, 9)),
        anxietySessionProvider.overrideWith((ref) async => null),
      ],
      child: Consumer(builder: (context, ref, child) {
        final snapshot = ref.watch(appControllerProvider).valueOrNull;
        return MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: snapshot == null
                ? const SizedBox.shrink()
                : TodayPage(snapshot: snapshot),
          ),
        );
      }),
    );

AppSnapshot _snapshot({String mode = 'Normal', DbRow? game}) => AppSnapshot(
      user: {'id': 1, 'name': 'Anggit'},
      templates: [
        {'id': 1, 'startTime': '08:00', 'endTime': '09:30'},
      ],
      tasks: [
        {
          'id': 1,
          'title': 'Blok jadwal padat',
          'sourceScheduleId': 1,
          'category': 'Tim',
          'priority': 'Reguler',
          'status': 'Belum mulai',
          'estimatedMinutes': 90,
        },
      ],
      thoughts: [],
      activeFocus: null,
      score: {
        'totalScore': 23,
        'dayMode': mode,
        'moodScore': 5,
        'anxietyScore': 4,
      },
      history: [],
      preferences: {},
      date: '2026-10-21',
      minimumTasks: [
        for (final entry in const [
          ('prayer', 'Sholat'),
          ('water', 'Minum air'),
          ('movement', 'Olahraga 5–10 menit atau stretching'),
          ('main', 'Menyelesaikan satu tugas utama selama 25 menit'),
          ('family', 'Meluangkan waktu berkualitas untuk keluarga'),
          ('closing', 'Menulis satu catatan penutupan hari'),
          ('sleep', 'Tidur lebih awal'),
        ].asMap().entries)
          {
            'id': 101 + entry.key,
            'minimumKey': entry.value.$1,
            'title': entry.value.$2,
            'status': 'Belum mulai',
            'estimatedMinutes': 25,
            'priority': 'Reguler',
          },
      ],
      valorantSession: game,
      valorantGate: {
        'allowed': false,
        'reason': 'Selesaikan target pagi terlebih dahulu.',
        'morningAchieved': false,
        'quotaUsed': game != null,
        'penalty': false,
      },
      streak: 3,
    );

AppSnapshot _copySnapshot(
  AppSnapshot value, {
  DbRow? score,
  List<DbRow>? minimumTasks,
  DbRow? game,
}) =>
    AppSnapshot(
      user: value.user,
      templates: value.templates,
      tasks: value.tasks,
      thoughts: value.thoughts,
      activeFocus: value.activeFocus,
      score: score ?? value.score,
      history: value.history,
      preferences: value.preferences,
      date: value.date,
      minimumTasks: minimumTasks ?? value.minimumTasks,
      planningSession: value.planningSession,
      valorantSession: game ?? value.valorantSession,
      valorantGate: value.valorantGate,
      streak: value.streak,
    );

class _TodayController extends AppController {
  _TodayController(this.initial);

  final AppSnapshot initial;
  int fiveMinuteStarts = 0;
  int gameConfirmations = 0;
  final selectedTabs = <int>[];
  final savedStatuses = <(int, String)>[];
  String? sanctuaryReason;
  String? savedMode;
  String? savedReason;

  @override
  Future<AppSnapshot> build() async => initial;

  @override
  Future<void> startFiveMinutes() async {
    fiveMinuteStarts++;
  }

  @override
  Future<void> setSelectedTab(int index) async {
    selectedTabs.add(index);
  }

  @override
  Future<void> enterSanctuary(String reason) async {
    sanctuaryReason = reason;
  }

  @override
  Future<void> setDayMode(String mode, {String? reason}) async {
    savedMode = mode;
    savedReason = reason;
    final previous = state.requireValue;
    state = AsyncData(_copySnapshot(previous, score: {
      ...previous.score,
      'dayMode': mode,
      'adaptationReason': reason,
      'consequencesDisabled': mode == 'Adaptasi' ? 1 : 0,
      'streakProtected': mode == 'Adaptasi' ? 1 : 0,
    }));
  }

  @override
  Future<void> setTaskStatus(int id, String status, {String? reason}) async {
    savedStatuses.add((id, status));
    final previous = state.requireValue;
    state = AsyncData(_copySnapshot(previous, minimumTasks: [
      for (final task in previous.minimumTasks)
        if (task.number('id') == id) {...task, 'status': status} else task,
    ]));
  }

  @override
  Future<void> confirmValorantClosed() async {
    gameConfirmations++;
    final previous = state.requireValue;
    state = AsyncData(_copySnapshot(previous, game: {
      ...previous.valorantSession!,
      'confirmedAt': '2026-10-21T13:05:00',
      'status': 'Ditutup',
    }));
  }
}
