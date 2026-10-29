import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mula/application/app_controller.dart';
import 'package:mula/data/local/app_database.dart';
import 'package:mula/data/wellbeing_repository.dart';
import 'package:mula/domain/app_snapshot.dart';
import 'package:mula/features/wellbeing/application/wellbeing_providers.dart';
import 'package:mula/features/wellbeing/presentation/anxiety_session_page.dart';

void main() {
  testWidgets('resumed grounding displays saved checks and sends the next change', (tester) async {
    final now = DateTime(2026, 10, 29, 9);
    final repository = _SavedSessionRepository({
      'id': 'saved-session', 'startedAt': now.toUtc().toIso8601String(),
      'before': 8, 'plannedSeconds': 120, 'phase': 'grounding',
      'grounding': [true, false, false, false, false],
    });
    await tester.pumpWidget(ProviderScope(overrides: [
      wellbeingRepositoryProvider.overrideWithValue(repository),
      clockProvider.overrideWithValue(now.add(const Duration(minutes: 3))),
    ], child: const MaterialApp(home: AnxietySessionPage())));
    await tester.pumpAndSettle();
    expect(find.text('Kenali sekitarmu · 5–4–3–2–1'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).at(0)).value, isTrue);
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pumpAndSettle();
    expect(repository.savedGroundingIndex, 1);
    expect(repository.savedGroundingValue, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running breathing screen uses the original saved timestamp', (tester) async {
    final now = DateTime(2026, 10, 29, 9);
    final repository = _SavedSessionRepository({
      'id': 'saved-session', 'startedAt': now.toUtc().toIso8601String(),
      'before': 6, 'plannedSeconds': 120, 'phase': 'breathing',
      'grounding': [false, false, false, false, false],
    });
    await tester.pumpWidget(ProviderScope(overrides: [
      wellbeingRepositoryProvider.overrideWithValue(repository),
      clockProvider.overrideWithValue(now.add(const Duration(seconds: 67))),
    ], child: const MaterialApp(home: AnxietySessionPage())));
    await tester.pumpAndSettle();
    expect(find.text('0:53 tersisa'), findsOneWidget);
    expect(find.text('Hembuskan dengan nyaman'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _SavedSessionRepository extends WellbeingRepository {
  _SavedSessionRepository(this.savedSession) : super(AppDatabase());
  final DbRow savedSession;
  int? savedGroundingIndex;
  bool? savedGroundingValue;

  @override
  Future<DbRow?> activeSession() async => savedSession;

  @override
  Future<void> setGrounding(int index, bool value) async {
    savedGroundingIndex = index;
    savedGroundingValue = value;
  }
}
