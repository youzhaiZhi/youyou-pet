import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/eye_geometry.dart';
import '../engine/pet_engine.dart';

/// 眼睛宽度占屏宽比例（UI 规格：12.7%），半宽即 6.35%。
const double kEyeHalfWidthRatio = 0.0635;

/// 双眼中线所在屏高比例（UI 规格：38%）。
const double kEyeCenterYRatio = 0.38;

const Color _inkWhite = Color(0xFFFFFFFF);
const Color _errInk = Color(0xFFFF5B4A);

/// 纯黑界面上的"只剩一双白眼睛"的角色渲染器。
class PetPainter extends CustomPainter {
  PetPainter(this.engine) : super(repaint: engine.frameTick);

  final PetEngine engine;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width * kEyeHalfWidthRatio;
    if (unit <= 0) return;
    final center = Offset(size.width / 2, size.height * kEyeCenterYRatio);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.translate(engine.groupX * unit, engine.groupY * unit);
    canvas.rotate(engine.groupTilt);
    canvas.scale(engine.groupScale);

    _paintEye(canvas, unit, engine.eyeLeft, -kEyeCenterX);
    _paintEye(canvas, unit, engine.eyeRight, kEyeCenterX);

    for (final layer in engine.layers) {
      final w = layer.weight.value;
      if (w <= 0.004) continue;
      canvas.save();
      canvas.scale(unit);
      switch (layer.kind) {
        case OverlayKind.dots:
          _paintDots(canvas, w);
        case OverlayKind.wave:
          _paintWave(canvas, w, engine.energy);
        case OverlayKind.bang:
          _paintBang(canvas, w);
        case OverlayKind.micRing:
          _paintMicRing(canvas, w);
      }
      canvas.restore();
    }

    canvas.restore();
  }

  // ------------------------------------------------------------------ 眼睛

  void _paintEye(Canvas canvas, double unit, EyeParams params, double cx) {
    canvas.save();
    canvas.translate(cx * unit, 0);
    canvas.translate(engine.gazeX * unit, engine.gazeY * unit);
    canvas.scale(unit);

    final poly = buildEyePolygon(params);
    final path = Path()..moveTo(poly[0].dx, poly[0].dy);
    for (int i = 1; i < poly.length; i++) {
      path.lineTo(poly[i].dx, poly[i].dy);
    }
    path.close();

    final glow = engine.glow;
    final alpha = engine.opacity;

    // 柔光分两层：大范围晕开 + 贴边收紧，再叠实体。
    // 与规格一致的做法（MaskFilter.blur），黑底上才有的"发光眼睛"观感。
    // 注意：sigma 处于已缩放的画布坐标系（1 = 眼睛半宽），故取值远小于 1。
    final wide = Paint()
      ..color = _inkWhite.withValues(alpha: (0.30 * glow).clamp(0, 1) * alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.19);
    canvas.drawPath(path, wide);

    final tight = Paint()
      ..color = _inkWhite.withValues(alpha: (0.50 * glow).clamp(0, 1) * alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.062);
    canvas.drawPath(path, tight);

    final solid = Paint()..color = _inkWhite.withValues(alpha: 0.99 * alpha);
    canvas.drawPath(path, solid);

    canvas.restore();
  }

  // ------------------------------------------------------------------ 特效

  /// 思考：三点依次起伏。
  void _paintDots(Canvas canvas, double w) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < 3; i++) {
      final t = ((engine.nowMs * 0.00095 + i * 0.18) % 1.0);
      final s = math.sin(math.pi * t);
      paint.color = _inkWhite.withValues(alpha: (0.28 + 0.62 * s) * w);
      canvas.drawCircle(
        Offset((i - 1) * 0.78, -2.45 - 0.3 * s),
        0.155 + 0.02 * s,
        paint,
      );
    }
  }

  /// 说话：声波条，幅度由真实音频能量驱动。
  void _paintWave(Canvas canvas, double w, double energy) {
    const n = 9;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.115;
    for (int i = 0; i < n; i++) {
      final osc = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(engine.nowMs * 0.0115 + i * 0.86));
      final half = (0.1 + 1.35 * energy) * osc;
      final x = (i - (n - 1) / 2) * 0.4;
      paint.color = _inkWhite.withValues(alpha: (0.30 + 0.35 * energy) * w);
      canvas.drawLine(Offset(x, 2.25 - half), Offset(x, 2.25 + half), paint);
    }
  }

  /// 出错：感叹号 + 轻微抖动。
  void _paintBang(Canvas canvas, double w) {
    final shake = 0.09 * math.sin(engine.nowMs * 0.028);
    final paint = Paint()..color = _errInk.withValues(alpha: 0.88 * w);
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(shake, -2.95), width: 0.24, height: 0.82),
      const Radius.circular(0.12),
    );
    canvas.drawRRect(rrect, paint);
    canvas.drawCircle(Offset(shake, -2.28), 0.145, paint);
  }

  /// 聆听：向外扩散的涟漪。
  void _paintMicRing(Canvas canvas, double w) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.07;
    const period = 2400.0;
    for (int i = 0; i < 2; i++) {
      final t = (((engine.nowMs + i * period / 2) % period) / period);
      final r = 0.55 + 1.15 * t;
      paint.color = _inkWhite.withValues(alpha: (1 - t) * 0.42 * w);
      canvas.drawCircle(const Offset(0, 2.15), r, paint);
    }
    final breathe = 1 + 0.07 * math.sin(engine.nowMs * 0.0042);
    paint
      ..color = _inkWhite.withValues(alpha: 0.5 * w)
      ..strokeWidth = 0.06;
    canvas.drawCircle(const Offset(0, 2.15), 0.42 * breathe, paint);
  }

  @override
  bool shouldRepaint(covariant PetPainter oldDelegate) => false;

  @override
  bool hitTest(ui.Offset position) => false;
}