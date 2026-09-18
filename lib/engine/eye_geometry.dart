import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'spring.dart';

/// 眼型参数（完全原创的几何族，未使用任何第三方素材）。
///
/// 眼睛不是"一堆手画多边形"，而是由 7 个标量生成的多边形。
/// 由此得到两个关键性质：
///  1) 任意两套参数都能线性过渡 —— 不存在顶点对应错乱、不需要顶点重采样；
///  2) 生成过程对标量连续 —— 因此"快照当前参数 → 追新目标"就是绝对平滑的形变。
class EyeParams {
  const EyeParams({
    this.w = 1,
    this.hTop = 0.20,
    this.hBot = 0.20,
    this.pTop = 0.18,
    this.pBot = 0.18,
    this.tilt = 0,
    this.yOff = 0,
  });

  /// 半宽（基准单位：1 = 眼睛半宽）
  final double w;

  /// 上缘幅度（正=向下弯，取正数表示"上缘在中心处向上抬起 hTop"）
  final double hTop;

  /// 下缘幅度（正=向下弯；负数表示下缘整体上凸，用于笑眼/弯月）
  final double hBot;

  /// 上缘锐度（越小越接近平直胶囊，0.5 ≈ 椭圆）
  final double pTop;

  /// 下缘锐度
  final double pBot;

  /// 绕眼睛中心的旋转（弧度，正值在屏幕坐标系里=右端向下）
  final double tilt;

  /// 垂直偏移（基准单位）
  final double yOff;

  /// 合法形状要求：中心处下缘必须在上缘之下。
  bool get valid => hTop + hBot > 0.012;
}

EyeParams lerpEye(EyeParams a, EyeParams b, double t) => EyeParams(
      w: lerpD(a.w, b.w, t),
      hTop: lerpD(a.hTop, b.hTop, t),
      hBot: lerpD(a.hBot, b.hBot, t),
      pTop: lerpD(a.pTop, b.pTop, t),
      pBot: lerpD(a.pBot, b.pBot, t),
      tilt: lerpD(a.tilt, b.tilt, t),
      yOff: lerpD(a.yOff, b.yOff, t),
    );

/// 眼型字典。全部为原创设计，仅保留黑底极简所需的少量形态。
///
/// 量纲说明：hTop/hBot 是相对**半宽**的半高，故
///     眼睛宽高比 = 2w / (hTop + hBot)
/// 绝对大小由 [kEyeHalfWidthRatio] 控制，本表只负责**比例**。
/// 因此每个眼型都按目标宽高比反解 h，而不是沿用同一量级的经验值 ——
/// 之前两次"眯着眼"就是这么来的：宽眼型抄了圆眼型的 h，
/// 结果 bar 被压成 5:1、thin 被压成 10:1 的横条。
enum EyeKey {
  /// 冷感横条（默认）
  bar,

  /// 略高、端部更圆（说话/聆听）
  soft,

  /// 细眼（思考/专注）
  thin,

  /// 圆眼（惊讶）
  round,

  /// 睁大（强调）
  wide,

  /// 上凸笑眼
  arc,

  /// 弯月（大笑）
  crescent,

  /// 半闭（困倦/慵懒）
  half,

  /// 闭合（眨眼/睡眠）
  closed,

  /// 怒（内角上抬）
  angry,

  /// 失落（内角下压）
  sad,
}

const Map<EyeKey, EyeParams> kEyeTable = {
  // 宽眼型，目标 1.55:1 —— 睁开的圆角条
  EyeKey.bar: EyeParams(w: 1.00, hTop: 0.645, hBot: 0.645, pTop: 0.18, pBot: 0.18),
  // 目标 1.32:1 —— 更圆、端部更软（聆听/说话）
  EyeKey.soft: EyeParams(w: 1.02, hTop: 0.790, hBot: 0.755, pTop: 0.30, pBot: 0.30),
  // 目标 3.15:1 —— 仍是明显的细眼（思考）
  EyeKey.thin: EyeParams(w: 1.06, hTop: 0.350, hBot: 0.323, pTop: 0.16, pBot: 0.16),
  // 收窄眼型，目标 ≈1:1 —— 正圆（惊讶）
  EyeKey.round: EyeParams(w: 0.66, hTop: 0.660, hBot: 0.660, pTop: 0.50, pBot: 0.50),
  EyeKey.wide: EyeParams(w: 0.80, hTop: 0.730, hBot: 0.699, pTop: 0.44, pBot: 0.46),
  // 弯月族：下缘整体上凸（hBot 为负），厚度 = hTop + |hBot|
  EyeKey.arc: EyeParams(w: 0.96, hTop: 0.560, hBot: -0.080, pTop: 0.24, pBot: 0.44),
  EyeKey.crescent: EyeParams(w: 1.00, hTop: 0.600, hBot: -0.169, pTop: 0.34, pBot: 0.52),
  // 半闭（困倦）：上缘下压到比下缘还浅
  EyeKey.half: EyeParams(w: 1.00, hTop: 0.240, hBot: 0.093, pTop: 0.18, pBot: 0.34),
  EyeKey.closed: EyeParams(w: 1.00, hTop: 0.063, hBot: 0.063, pTop: 0.18, pBot: 0.18),
  EyeKey.angry: EyeParams(w: 0.96, hTop: 0.630, hBot: 0.534, pTop: 0.16, pBot: 0.16, tilt: -0.20),
  EyeKey.sad: EyeParams(w: 0.98, hTop: 0.470, hBot: 0.421, pTop: 0.22, pBot: 0.22, tilt: 0.16),
};

/// 上下缘各自采样点数（含两端）。
const int kEyeSegments = 26;

/// 由参数生成闭多边形（基准单位）。
///
/// 上缘取 y = -hTop·cos^(2p)θ，x = sinθ，θ∈[-π/2, π/2]。
/// 因为 dx/dθ→0 而 dy/dθ→∞（p<0.5 时），端部自然收敛成竖直切线，
/// 也就是圆头 —— 用同一个公式同时得到"胶囊横条"和"椭圆"两类形状。
List<Offset> buildEyePolygon(EyeParams e, {double widthScale = 1}) {
  final pts = <Offset>[];
  final hw = e.w * widthScale;
  final sinT = math.sin(e.tilt);
  final cosT = math.cos(e.tilt);

  void add(double x, double y) {
    pts.add(Offset(x * cosT - y * sinT, x * sinT + y * cosT + e.yOff));
  }

  final denom = (kEyeSegments - 1).toDouble();
  for (int i = 0; i < kEyeSegments; i++) {
    final th = -math.pi / 2 + math.pi * i / denom;
    final x = math.sin(th) * hw;
    final c = math.cos(th);
    final y = -e.hTop * math.pow(c, 2 * e.pTop).toDouble();
    add(x, y);
  }
  for (int i = kEyeSegments - 2; i >= 1; i--) {
    final th = -math.pi / 2 + math.pi * i / denom;
    final x = math.sin(th) * hw;
    final c = math.cos(th);
    final y = e.hBot * math.pow(c, 2 * e.pBot).toDouble();
    add(x, y);
  }
  return pts;
}

/// 把多边形（基准单位）展开成可缓存的扁平 path 数据。
List<Offset> mirrorPolygon(List<Offset> src) =>
    src.map((p) => Offset(-p.dx, p.dy)).toList(growable: false);

/// 多边形几何中心（用于高光/回弹支点）。
Offset polyCentroid(List<Offset> p) {
  double sx = 0, sy = 0;
  for (final q in p) {
    sx += q.dx;
    sy += q.dy;
  }
  return Offset(sx / p.length, sy / p.length);
}