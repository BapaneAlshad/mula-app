/// A wall-clock session survives screen locks and process restarts.
class FocusClock {
  const FocusClock({required this.startedAt, required this.plannedSeconds});

  final DateTime startedAt;
  final int plannedSeconds;

  int elapsedAt(DateTime now) =>
      now.difference(startedAt).inSeconds.clamp(0, plannedSeconds).toInt();

  int remainingAt(DateTime now) => plannedSeconds - elapsedAt(now);

  bool isCompleteAt(DateTime now) => remainingAt(now) == 0;
}
