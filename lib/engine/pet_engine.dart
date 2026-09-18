import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'eye_geometry.dart';
import 'spring.dart';

/// 角色状态。UI 只写状态，绝不直接写动画值。
enum PetState { idle, listening, thinking, speaking, error }

/// 叠加特效层。
enum OverlayKind { dots, wave, bang, micRing }

/// 可随时打断的临时动作（首尾归零的包络叠加，可安全叠加多个）。
enum PetAction { hop, tilt, wobble }

/// 每个状态的目标描述。
class StateProfile {
  const StateProfile({
    required this.base,
    required this.cycle,
    required this.holdMs,
    required this.blinkMs,
    required this.gazeDrift,
    required this.overlay,
  });

  final EyeKey base;
  final List<EyeKey> cycle;
  final List<double> holdMs;
  final List<double> blinkMs;
  final bool gazeDrift;

  /// 该状态的叠加特效。null = 无叠加层（不要用"空特效"占位，
  /// 否则会留下一个权重恒为 1 却永不绘制的僵尸层）。
  final OverlayKind? overlay;
}

const Map<PetState, StateProfile> kProfiles = {
  PetState.idle: StateProfile(
    base: EyeKey.bar,
    cycle: [EyeKey.bar, EyeKey.bar, EyeKey.soft, EyeKey.thin],
    holdMs: [9000, 17000],
    blinkMs: [6000, 14000],
    gazeDrift: true,
    // 什么都不做时不该有"思考中"的三点 —— 那是 thinking 的语汇。
    overlay: null,
  ),
  PetState.listening: StateProfile(
    base: EyeKey.soft,
    cycle: [EyeKey.soft, EyeKey.round, EyeKey.soft, EyeKey.bar],
    holdMs: [2200, 4200],
    blinkMs: [3000, 7000],
    gazeDrift: false,
    overlay: OverlayKind.micRing,
  ),
  PetState.thinking: StateProfile(
    base: EyeKey.thin,
    cycle: [EyeKey.thin, EyeKey.thin, EyeKey.bar],
    holdMs: [1500, 2800],
    blinkMs: [4000, 9000],
    gazeDrift: true,
    overlay: OverlayKind.dots,
  ),
  PetState.speaking: StateProfile(
    base: EyeKey.soft,
    cycle: [EyeKey.soft, EyeKey.arc, EyeKey.soft, EyeKey.wide],
    holdMs: [1700, 3200],
    blinkMs: [4000, 9000],
    gazeDrift: true,
    overlay: OverlayKind.wave,
  ),
  PetState.error: StateProfile(
    base: EyeKey.angry,
    cycle: [EyeKey.angry, EyeKey.sad, EyeKey.angry],
    holdMs: [1900, 3200],
    blinkMs: [3000, 6000],
    gazeDrift: false,
    overlay: OverlayKind.bang,
  ),
};

/// 眼睛中心距屏幕中线的水平距离（基准单位：1 = 眼睛半宽）。
/// 由 UI 规格反推：眼宽 12.7% 屏宽 + 眼间距 13% 屏宽。
const double kEyeCenterX = 2.024;

/// 眨眼低谷值。黑底上眨眼要比深色背景更明显，故压到 0.02。
const double kBlinkFloor = 0.02;

class OverlayLayer {
  OverlayLayer(this.kind, double startWeight) : weight = Spring(9, 1, startWeight);
  final OverlayKind kind;
  final Spring weight;
}

class _ActionRunner {
  _ActionRunner(this.kind, this.startMs, this.durationMs, this.dir);
  final PetAction kind;
  final double startMs;
  final double durationMs;
  final double dir;

  double get progress => clamp((_nowMs - startMs) / durationMs, 0, 1);
  double _nowMs = 0;

  /// 首尾恒为 0 的包络，允许中途被抢占而不产生跳变。
  double envelope() => math.sin(math.pi * progress);

  bool get done => progress >= 1;
}

/// 桌宠引擎：所有可视量都是弹簧，状态机只写 target。
class PetEngine {
  PetEngine() {
    _applyState(PetState.idle, hard: true);
  }

  final math.Random _rnd = math.Random(20260919);

  /// 绘制驱动：painter 监听这个 notifier，不触发 widget rebuild。
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  PetState _state = PetState.idle;
  PetState get state => _state;

  double _nowMs = 0;
  double _lastElapsedMs = -1;

  // ---- 弹簧 ----
  final Spring _gazeX = Spring(13, 1, 0);
  final Spring _gazeY = Spring(13, 1, 0);
  final Spring _blink = Spring(26, 1, 1);
  final Spring _scale = Spring(9, 0.85, 1);
  final Spring _morph = Spring(11, 1, 1);
  final Spring _bob = Spring(4, 0.9, 0);
  final Spring _lift = Spring(7, 0.95, 0);
  final Spring _liftScale = Spring(7, 0.95, 1);
  final Spring _energy = Spring(14, 1, 0);
  final Spring _fade = Spring(9, 1, 1);

  // ---- 眼型快照式插值 ----
  EyeParams _eyeFrom = kEyeTable[EyeKey.bar]!;
  EyeKey _eyeKey = EyeKey.bar;
  EyeKey _eyeCycleKey = EyeKey.bar;

  double _nextEyeAt = 0;
  double _nextBlinkAt = 0;
  double _nextGazeAt = 0;
  double _blinkStepAt = -1;
  int _blinkStep = 0;
  double _nextActionAt = 0;

  final List<OverlayLayer> _layers = [];
  final List<_ActionRunner> _actions = [];
  bool _playing = false;

  Offset2 _gazeTarget = const Offset2(0, 0);
  Offset2? _pointerGaze;

  int _cycleIndex = 0;

  /// 供 painter 读取的当前帧数据（全部由 update() 计算）。
  EyeParams eyeLeft = kEyeTable[EyeKey.bar]!;
  EyeParams eyeRight = kEyeTable[EyeKey.bar]!;
  double gazeX = 0;
  double gazeY = 0;
  double groupX = 0;
  double groupY = 0;
  double groupScale = 1;
  double groupTilt = 0;
  double opacity = 1;
  double energy = 0;
  double glow = 0;

  List<OverlayLayer> get layers => _layers;
  double get nowMs => _nowMs;

  // ---------------------------------------------------------------- 外部输入

  void setState(PetState next) {
    if (next == _state) return;
    _applyState(next, hard: false);
  }

  void setPlaying(bool playing) {
    _playing = playing;
    if (!playing) _energy.to(0);
  }

  void pushEnergy(double v) {
    _energy.to(clamp(v, 0, 1));
  }

  /// 键盘弹起 / 收起：只写 target，弹簧负责上移与轻微缩小。
  void setKeyboardOpen(bool open) {
    _lift.to(open ? -1.15 : 0);
    _liftScale.to(open ? 0.9 : 1);
  }

  /// 拖动让眼睛跟随。
  void setPointer(Offset2? p) {
    _pointerGaze = p;
    if (p != null) _gazeX.to(p.x);
    if (p != null) _gazeY.to(p.y);
  }

  /// 主动打断并叠加一个临时动作（不会清空正在跑的动作，因此绝不跳变）。
  void trigger(PetAction action, {double dir = 0}) {
    final base = switch (action) {
      PetAction.hop => 620.0,
      PetAction.tilt => 780.0,
      PetAction.wobble => 900.0,
    };
    _actions.add(_ActionRunner(
      action,
      _nowMs,
      base,
      dir == 0 ? (_rnd.nextBool() ? 1 : -1) : dir,
    ));
    if (_actions.length > 6) _actions.removeAt(0);
  }

  void greet() {
    _bob.snap(-1.5, keepVelocity: false);
    trigger(PetAction.hop);
  }

  /// 硬重置（仅在引擎刚创建 / 尺寸剧变时使用）。
  void hardReset(PetState state) => _applyState(state, hard: true);

  // ------------------------------------------------------------------ 状态机

  void _applyState(PetState next, {required bool hard}) {
    _state = next;
    final p = kProfiles[next]!;
    _cycleIndex = 0;
    _eyeCycleKey = p.base;

    if (hard) {
      _eyeFrom = kEyeTable[_eyeCycleKey]!;
      _eyeKey = _eyeCycleKey;
      _morph.snap(1);
    } else {
      // 关键：快照"当前实际中间形态"作为起点，而不是旧目标值。
      _eyeFrom = _currentEyeParams();
      _eyeKey = _eyeCycleKey;
      _morph.snap(0, keepVelocity: true);
      _morph.to(1);
    }

    _nextEyeAt = _nowMs + p.holdMs[0] * 0.35;
    _nextBlinkAt = _nowMs + randRange(_rnd, p.blinkMs[0], p.blinkMs[1]);
    _nextGazeAt = _nowMs + randRange(_rnd, 900, 1800);
    _blinkStep = 0;
    _blinkStepAt = -1;
    _fade.to(1);

    _applyOverlay(p.overlay);
    if (next == PetState.speaking) _energy.to(0.2);
  }

  void _applyOverlay(OverlayKind? kind) {
    for (final l in _layers) {
      l.weight.to(l.kind == kind ? 1 : 0);
    }
    // 无叠加层：旧层已降到 0，直接返回，不再新建。
    if (kind == null) return;
    if (!_layers.any((l) => l.kind == kind)) {
      final l = OverlayLayer(kind, 0);
      l.weight.to(1);
      _layers.add(l);
    }
  }

  EyeParams _currentEyeParams() => lerpEye(
        _eyeFrom,
        kEyeTable[_eyeKey]!,
        clamp(_morph.value, 0, 1),
      );

  // -------------------------------------------------------------------- 主循环

  void update(double elapsedMs) {
    if (_lastElapsedMs < 0) {
      _lastElapsedMs = elapsedMs;
      _nowMs = elapsedMs;
      _scheduleAll();
      _derive();
      frameTick.value++;
      return;
    }
    double dt = (elapsedMs - _lastElapsedMs) / 1000.0;
    _lastElapsedMs = elapsedMs;
    if (dt <= 0) return;
    if (dt > 0.12) dt = 0.12; // 后台返回：限制单帧步进
    _nowMs = elapsedMs;

    _timers();
    _stepAll(dt);
    _derive();
    frameTick.value++;
  }

  void _scheduleAll() {
    final p = kProfiles[_state]!;
    _nextEyeAt = _nowMs + randRange(_rnd, 800, 1600);
    _nextBlinkAt = _nowMs + randRange(_rnd, p.blinkMs[0], p.blinkMs[1]);
    _nextGazeAt = _nowMs + randRange(_rnd, 900, 1800);
    _nextActionAt = _nowMs + randRange(_rnd, 4000, 8000);
  }

  void _timers() {
    final p = kProfiles[_state]!;

    // 眼型游走
    if (_nowMs >= _nextEyeAt) {
      _cycleIndex++;
      _eyeCycleKey = p.cycle[_cycleIndex % p.cycle.length];
      if (_eyeCycleKey != _eyeKey) {
        _eyeFrom = _currentEyeParams();
        _eyeKey = _eyeCycleKey;
        _morph.snap(0, keepVelocity: true);
        _morph.to(1);
      }
      _nextEyeAt = _nowMs + randRange(_rnd, p.holdMs[0], p.holdMs[1]);
    }

    // 眨眼（时间线驱动的目标序列，仍然只写 target）
    if (_blinkStepAt < 0 && _nowMs >= _nextBlinkAt) {
      _blinkStep = 0;
      _blinkStepAt = _nowMs;
    }
    if (_blinkStepAt >= 0) {
      final t = _nowMs - _blinkStepAt;
      if (_blinkStep == 0 && t >= 0) {
        _blink.to(kBlinkFloor);
        _blinkStep = 1;
      }
      if (_blinkStep == 1 && t >= 60) {
        _blink.to(kBlinkFloor);
        _blinkStep = 2;
      }
      if (_blinkStep == 2 && t >= 140) {
        _blink.to(1.08);
        _blinkStep = 3;
      }
      if (_blinkStep == 3 && t >= 300) {
        _blink.to(1);
        _blinkStep = 4;
        _blinkStepAt = -1;
        var next = randRange(_rnd, p.blinkMs[0], p.blinkMs[1]);
        if (_rnd.nextDouble() < 0.12) next = 420; // 偶发连眨
        _nextBlinkAt = _nowMs + next;
      }
    }

    // 视线漂移
    if (_nowMs >= _nextGazeAt) {
      _nextGazeAt = _nowMs + randRange(_rnd, 1400, 3600);
      if (_pointerGaze != null) {
        _gazeX.to(_pointerGaze!.x);
        _gazeY.to(_pointerGaze!.y);
      } else if (p.gazeDrift) {
        final amp = _state == PetState.thinking ? 0.42 : 0.3;
        _gazeTarget = Offset2(
          randRange(_rnd, -amp, amp),
          randRange(_rnd, -amp * 0.6, amp * 0.6),
        );
        _gazeX.to(_gazeTarget.x);
        _gazeY.to(_gazeTarget.y);
      } else {
        _gazeX.to(randRange(_rnd, -0.12, 0.12));
        _gazeY.to(randRange(_rnd, -0.1, 0.1));
      }
    }

    // 空闲时的小动作
    if (_state == PetState.idle && _nowMs >= _nextActionAt) {
      _nextActionAt = _nowMs + randRange(_rnd, 4500, 9000);
      if (_actions.isEmpty) {
        const all = PetAction.values;
        trigger(all[_rnd.nextInt(all.length)]);
      }
    }

    for (final a in _actions) {
      a._nowMs = _nowMs;
    }
    _actions.removeWhere((a) => a.done);
  }

  void _stepAll(double dt) {
    stepSpring(_gazeX, dt);
    stepSpring(_gazeY, dt);
    stepSpring(_blink, dt);
    stepSpring(_scale, dt);
    stepSpring(_morph, dt);
    stepSpring(_bob, dt);
    stepSpring(_lift, dt);
    stepSpring(_liftScale, dt);
    stepSpring(_energy, dt);
    stepSpring(_fade, dt);
    for (final l in _layers) {
      stepSpring(l.weight, dt);
    }
    _layers.removeWhere((l) => l.weight.target == 0 && l.weight.value < 0.004);
  }

  void _derive() {
    final base = _currentEyeParams();
    final blink = clamp(_blink.value, kBlinkFloor, 1.25);
    final p = kProfiles[_state]!;

    // 说话时的轻微"发声"脉冲：由真实 PCM 能量驱动，缺失时退化为程序化呼吸。
    final procedural = _playing
        ? 0.28 +
            0.24 * math.sin(_nowMs * 0.0091) +
            0.16 * math.sin(_nowMs * 0.0223 + 1.7)
        : 0.0;
    final live = _playing
        ? clamp(math.max(_energy.value * 1.45, procedural * 0.55), 0, 1)
        : clamp(_energy.value, 0, 1);
    energy = live;

    final pulse = 1 + 0.028 * live;

    final eyeNow = EyeParams(
      w: base.w,
      hTop: math.max(base.hTop * blink, 0.012),
      hBot: math.max(base.hBot * blink, 0.012),
      pTop: base.pTop,
      pBot: base.pBot,
      tilt: base.tilt,
      yOff: base.yOff + (_state == PetState.error ? 0.04 : 0),
    );

    eyeLeft = EyeParams(
      w: eyeNow.w,
      hTop: eyeNow.hTop,
      hBot: eyeNow.hBot,
      pTop: eyeNow.pTop,
      pBot: eyeNow.pBot,
      tilt: eyeNow.tilt,
      yOff: eyeNow.yOff,
    );
    eyeRight = EyeParams(
      w: eyeNow.w,
      hTop: eyeNow.hTop,
      hBot: eyeNow.hBot,
      pTop: eyeNow.pTop,
      pBot: eyeNow.pBot,
      tilt: -eyeNow.tilt,
      yOff: eyeNow.yOff,
    );

    gazeX = _gazeX.value;
    gazeY = _gazeY.value;

    // 群组变换：漂浮 + 键盘上移 + 临时动作包络
    double act = 0, tiltAct = 0, sideAct = 0;
    for (final a in _actions) {
      final e = a.envelope();
      switch (a.kind) {
        case PetAction.hop:
          act += -1.7 * e;
        case PetAction.tilt:
          tiltAct += 0.15 * e * a.dir;
        case PetAction.wobble:
          sideAct += 0.5 * e * a.dir;
      }
    }

    final breathe = math.sin(_nowMs * 0.0009) * 0.09;
    groupX = sideAct + breathe * 0.6;
    groupY = _bob.value + act + _lift.value + breathe - 0.35 * live;
    groupTilt = tiltAct + (_state == PetState.thinking ? 0.02 * math.sin(_nowMs * 0.0013) : 0);
    groupScale = _scale.value * _liftScale.value * pulse;
    opacity = clamp(_fade.value, 0, 1);
    glow = clamp(0.32 + 0.75 * live + (_state == PetState.thinking ? 0.12 : 0), 0, 1.4);

    // 说话时眼球轻微上抬（配合声波），非说话时回到基准
    if (p.overlay == OverlayKind.wave) {
      groupY -= 0.12 * live;
    }
  }
}

/// 轻量 2D 向量（避免 engine 依赖 material）。
@immutable
class Offset2 {
  const Offset2(this.x, this.y);
  final double x;
  final double y;
}