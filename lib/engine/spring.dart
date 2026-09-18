import 'dart:math' as math;

/// 固定子步长积分：无论屏幕是 60Hz 还是 120Hz，弹簧轨迹完全一致。
/// 这是"任意状态可随时切换且无卡顿"的数值前提。
const double kFixedStep = 1 / 120.0;

/// 二阶弹簧（单位质量）：x'' = -2·damp·freq·x' - freq²·(x - target)
///
/// 约定：**状态机只允许调用 [to] 写目标**，绝不直接写位置或速度。
/// 任何"等当前动画播完再切"的做法都会破坏连续性，一律禁止。
class Spring {
  Spring(this.freq, this.damp, double initial)
      : _x = initial,
        _t = initial,
        _v = 0;

  final double freq;
  final double damp;

  double _x;
  double _v;
  double _t;

  double get value => _x;
  double get target => _t;
  double get velocity => _v;

  /// 唯一允许的写入口。
  void to(double target) {
    _t = target;
  }

  /// 瞬时归位（仅初始化 / 硬重置时使用，保留速度可选）。
  void snap(double value, {bool keepVelocity = false}) {
    _x = value;
    _t = value;
    if (!keepVelocity) _v = 0;
  }

  /// 立刻把位置推到目标（用于外部强制对齐，例如尺寸变化）。
  void settle() {
    _x = _t;
    _v = 0;
  }

  bool get atRest => (_x - _t).abs() < 1e-4 && _v.abs() < 1e-3;
}

/// 推进一个弹簧。dt 为秒，内部自动切成 1/120s 的固定子步。
void stepSpring(Spring s, double dt) {
  if (dt <= 0 || !dt.isFinite) return;
  int steps = (dt / kFixedStep).ceil();
  if (steps < 1) steps = 1;
  if (steps > 12) steps = 12; // 掉帧/回前台时防止数值爆炸
  final h = dt / steps;
  final w = s.freq;
  final z = s.damp;
  final w2 = w * w;
  final c = 2 * z * w;
  for (int i = 0; i < steps; i++) {
    s._v += (-c * s._v - w2 * (s._x - s._t)) * h;
    s._x += s._v * h;
    // NaN / 发散兜底：必须保留。极端参数下二阶积分可能发散，
    // 一旦污染会永久黑屏，所以就地收口。
    if (!s._x.isFinite || !s._v.isFinite) {
      s._x = s._t;
      s._v = 0;
    }
  }
}

/// 把弹簧从当前位置起跳到一个新的目标值，
/// 位置不变（视觉连续）、速度保留（动量连续），只改目标。
void retarget(Spring s, double target) => s.to(target);

double clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double lerpD(double a, double b, double t) => a + (b - a) * t;

double easeInOut(double t) {
  final p = clamp(t, 0, 1);
  return p < 0.5 ? 2 * p * p : 1 - math.pow(-2 * p + 2, 2).toDouble() / 2;
}

double easeOut(double t) {
  final p = clamp(t, 0, 1);
  return 1 - math.pow(1 - p, 3).toDouble();
}

double randRange(math.Random r, double a, double b) => a + r.nextDouble() * (b - a);