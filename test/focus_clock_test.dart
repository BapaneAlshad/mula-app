import 'package:flutter_test/flutter_test.dart';
import 'package:mula/domain/focus_clock.dart';

void main() {
  test('screen-lock gap and process restart use elapsed timestamps', () {
    final started = DateTime(2026, 10, 21, 9, 30);
    final restored = FocusClock(startedAt: started, plannedSeconds: 3000);
    expect(restored.remainingAt(started.add(const Duration(minutes: 32))), 1080);
    expect(restored.isCompleteAt(started.add(const Duration(hours: 2))), isTrue);
    expect(restored.elapsedAt(started.add(const Duration(hours: 2))), 3000);
  });

  test('a clock correction never makes elapsed negative', () {
    final started = DateTime(2026, 10, 21, 9, 30);
    final clock = FocusClock(startedAt: started, plannedSeconds: 300);
    expect(clock.remainingAt(started.subtract(const Duration(minutes: 1))), 300);
  });
}
