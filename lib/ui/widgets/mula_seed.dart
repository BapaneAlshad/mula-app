import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small, original plant whose growth follows the calculated daily score.
class MulaSeed extends StatelessWidget {
  const MulaSeed({super.key, required this.score, this.size = 112});

  final int score;
  final double size;

  String get stage => score >= 85
      ? 'Berbunga'
      : score >= 60
          ? 'Berdaun'
          : score >= 25
              ? 'Tunas'
              : 'Benih';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'MULA Seed: $stage. Progres $score dari 100 poin.',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _SeedPainter(
            score: score,
            stem: colors.primary,
            leaf: colors.secondary,
            earth: colors.tertiary,
            flower: colors.tertiaryContainer,
          ),
        ),
      ),
    );
  }
}

class _SeedPainter extends CustomPainter {
  const _SeedPainter({
    required this.score,
    required this.stem,
    required this.leaf,
    required this.earth,
    required this.flower,
  });

  final int score;
  final Color stem;
  final Color leaf;
  final Color earth;
  final Color flower;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 120, size.height / 120);
    final paint = Paint()..isAntiAlias = true;
    paint.color = earth.withValues(alpha: .15);
    canvas.drawOval(const Rect.fromLTWH(18, 94, 84, 13), paint);
    paint.color = earth;
    paint.strokeWidth = 2;
    paint.strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(31, 99), const Offset(89, 99), paint);

    if (score < 25) {
      paint.color = stem;
      canvas.save();
      canvas.translate(60, 85);
      canvas.rotate(-.4);
      canvas.drawOval(const Rect.fromLTWH(-8, -11, 16, 22), paint);
      canvas.restore();
      paint.color = leaf;
      paint.strokeWidth = 1.8;
      canvas.drawLine(const Offset(58, 88), const Offset(63, 79), paint);
    } else {
      final top = score >= 85 ? 31.0 : score >= 60 ? 30.0 : 48.0;
      paint.color = stem;
      paint.strokeWidth = 3;
      paint.style = PaintingStyle.stroke;
      canvas.drawPath(
        Path()
          ..moveTo(60, 98)
          ..cubicTo(53, 77, 66, 58, 60, top),
        paint,
      );
      paint.style = PaintingStyle.fill;
      _drawLeaf(canvas, paint, const Offset(59, 74), false, 23);
      _drawLeaf(canvas, paint, const Offset(61, 61), true, 25);
      if (score >= 60) {
        _drawLeaf(canvas, paint, const Offset(61, 45), false, 21);
        _drawLeaf(canvas, paint, const Offset(57, 86), true, 18);
      }
      if (score >= 85) {
        for (var i = 0; i < 6; i++) {
          final angle = i * math.pi / 3;
          paint.color = flower;
          canvas.drawCircle(
            Offset(60 + math.cos(angle) * 10, 27 + math.sin(angle) * 10),
            7.5,
            paint,
          );
        }
        paint.color = earth;
        canvas.drawCircle(const Offset(60, 27), 6, paint);
      }
    }
    canvas.restore();
  }

  void _drawLeaf(Canvas canvas, Paint paint, Offset origin, bool right, double length) {
    final direction = right ? 1.0 : -1.0;
    paint.color = right ? leaf : stem;
    canvas.drawPath(
      Path()
        ..moveTo(origin.dx, origin.dy)
        ..quadraticBezierTo(origin.dx + direction * length, origin.dy + 2,
            origin.dx + direction * length, origin.dy - length * .72)
        ..quadraticBezierTo(origin.dx + direction * 2, origin.dy - length,
            origin.dx, origin.dy),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SeedPainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.stem != stem ||
      oldDelegate.leaf != leaf || oldDelegate.earth != earth || oldDelegate.flower != flower;
}
