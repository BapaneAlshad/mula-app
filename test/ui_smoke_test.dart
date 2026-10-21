import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/ui/mula_shell.dart';
import 'package:mula/ui/onboarding_screen.dart';

void main() {
  testWidgets('onboarding validates the name and sends a complete profile', (tester) async {
    final controller = _UiController();
    await tester.pumpWidget(ProviderScope(
      overrides: [appControllerProvider.overrideWith(() => controller)],
      child: MaterialApp(home: OnboardingScreen(snapshot: _snapshot())),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.ensureVisible(find.text('Mulai langkah pertama'));
    await tester.tap(find.text('Mulai langkah pertama'));
    await tester.pumpAndSettle();
    expect(find.text('Isi nama panggilanmu.'), findsOneWidget);
    expect(controller.savedName, isNull);

    await tester.enterText(find.byType(TextFormField).first, 'Anggit Baru');
    await tester.ensureVisible(find.text('Mulai langkah pertama'));
    await tester.tap(find.text('Mulai langkah pertama'));
    await tester.pumpAndSettle();
    expect(controller.savedName, 'Anggit Baru');
    expect(controller.savedWakeTime, '04:30');
    expect(controller.savedSleepTime, '22:00');
    expect(controller.savedStrictness, 'Lembut');
    expect(controller.savedOnboarding, isTrue);
  });

  testWidgets('all five destinations call the controller and render their page', (tester) async {
    final controller = _UiController();
    await tester.pumpWidget(_shell(controller));
    await tester.pumpAndSettle();
    expect(find.text('SKOR HARI INI'), findsOneWidget);

    for (final destination in <String, String>{
      'Fokus': 'Satu hal.\nSepenuh hadir.',
      'Pikiran': 'Letakkan dulu.\nLepaskan sejenak.',
      'Progres': 'Tumbuh dengan\nritmemu sendiri.',
      'Pengaturan': 'Sistem yang\nmenemanimu.',
      'Hari Ini': 'SKOR HARI INI',
    }.entries) {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(destination.key)));
      await tester.pumpAndSettle();
      expect(find.text(destination.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(controller.selectedTabs, [1, 2, 3, 4, 0]);
  });

  testWidgets('locked thoughts hide sensitive content', (tester) async {
    final controller = _UiController(locked: true);
    await tester.pumpWidget(_shell(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Pikiran')));
    await tester.pumpAndSettle();
    expect(find.text('Catatan pikiran terkunci'), findsOneWidget);
    expect(find.text('Catatan sensitif untuk tes'), findsNothing);
    expect(find.text('Buka ruang pikiran'), findsOneWidget);
  });
}

Widget _shell(_UiController controller) => ProviderScope(
  overrides: [
    appControllerProvider.overrideWith(() => controller),
    clockProvider.overrideWithValue(DateTime(2026, 10, 21, 9)),
  ],
  child: Consumer(builder: (context, ref, child) {
    final data = ref.watch(appControllerProvider).valueOrNull;
    return MaterialApp(theme: ThemeData(useMaterial3: true), home: data == null ? const SizedBox.shrink() : MulaShell(snapshot: data));
  }),
);

AppSnapshot _snapshot({String tab = '0', bool locked = false}) => AppSnapshot(
  user: {'id': 1, 'name': 'Anggit', 'wakeTime': '04:30', 'sleepTime': '22:00', 'strictnessLevel': 'Lembut', 'onboardingCompleted': 1},
  templates: [],
  tasks: [],
  thoughts: [{'id': 1, 'content': 'Catatan sensitif untuk tes', 'type': 'Ide', 'intensity': 5, 'status': 'Terparkir', 'createdAt': '2026-10-21T09:00:00'}],
  activeFocus: null,
  score: {'totalScore': 0, 'moodScore': 5, 'anxietyScore': 5},
  history: [],
  preferences: {'selectedTab': tab, 'privacyLock': '$locked'},
  date: '2026-10-21',
);

class _UiController extends AppController {
  _UiController({this.locked = false});
  final bool locked;
  final List<int> selectedTabs = [];
  String? savedName;
  String? savedWakeTime;
  String? savedSleepTime;
  String? savedStrictness;
  bool? savedOnboarding;

  @override
  Future<AppSnapshot> build() async => _snapshot(locked: locked);

  @override
  Future<void> setSelectedTab(int index) async {
    selectedTabs.add(index);
    state = AsyncData(_snapshot(tab: '$index', locked: locked));
  }

  @override
  Future<void> saveUser({required String name, required String wakeTime, required String sleepTime, required String strictnessLevel, required bool onboardingCompleted}) async {
    savedName = name;
    savedWakeTime = wakeTime;
    savedSleepTime = sleepTime;
    savedStrictness = strictnessLevel;
    savedOnboarding = onboardingCompleted;
  }
}
