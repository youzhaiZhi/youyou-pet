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

// ---------------------------------------------------------------- 声明式动效
//
// 借鉴 emotion-ball 的"表情是纯数据对象"思路：动效不再写死在 update() 里，
// 而是由 [AnimPrim]（常驻连续波形）与 [Sequence]（有限时长关键帧表演）描述。
// 引擎只负责把数据叠加成偏移量 —— 状态机仍然一行具体数值都不写。

/// 动画原语的作用对象。
enum AnimTarget { gazeX, gazeY, groupX, groupY, tilt, scale }

/// 波形类型。它比幅度/周期更能决定"看起来像什么"。
enum AnimType {
  /// 匀速正弦漂移：呼吸、漂浮
  drift,

  /// 扫视：快速移动 + 长停留（tanh 压缩），模拟眼跳
  glance,

  /// 单向脉冲（半波整流，只朝一个方向顶）：心跳式缩放
  pulse,

  /// 抖动：基频叠加三次谐波，比纯正弦更"慌"
  shake,
}

/// 一条声明式动画原语：作用对象 + 波形 + 幅度 + 周期（+ 相位）。
class AnimPrim {
  const AnimPrim(
    this.target,
    this.type,
    this.amp,
    this.periodMs, {
    this.phase = 0,
  });

  final AnimTarget target;
  final AnimType type;

  /// 幅度（单位与目标一致：group/gaze 为"眼睛半宽"，tilt 为弧度，scale 为增量）。
  final double amp;

  /// 周期（毫秒）。
  final double periodMs;

  /// 相位（0..1，用于让多条同频原语错开）。
  final double phase;
}

/// 关键帧表演结束后如何收尾。
enum SettleKind {
  /// 停在末帧（保持该表情不动，直到状态再次变化）
  hold,

  /// 回到状态基准态，继续常规的眼型游走
  base,

  /// 立刻接入下一段表演（马上从 cycle 里取下一个表情）
  next,
}

/// 关键帧表演中的一帧。未填写的通道保持"上一帧的值 / 引擎默认"。
class SeqFrame {
  const SeqFrame(
    this.atMs, {
    this.eye,
    this.blink,
    this.gazeX,
    this.gazeY,
    this.groupY,
    this.scale,
    this.tilt,
  });

  final double atMs;

  /// 眼型（离散通道：只在跨帧时切换，切换走快照式形变，故依然连续）。
  final EyeKey? eye;

  /// 以下为标量通道：在相邻两帧之间用 easeInOut 连续插值。
  final double? blink;
  final double? gazeX;
  final double? gazeY;
  final double? groupY;
  final double? scale;
  final double? tilt;
}

/// 有限时长的一段表演。
class Sequence {
  const Sequence(this.frames, {this.settle = SettleKind.base});

  final List<SeqFrame> frames;
  final SettleKind settle;

  double get durationMs => frames.last.atMs;
}

/// 打招呼表演：睁大 → 圆眼 → 弯月笑 → 回基准。
const Sequence kGreetSequence = Sequence([
  SeqFrame(0, eye: EyeKey.wide, blink: 1.12, groupY: -0.14, gazeY: -0.06),
  SeqFrame(200, eye: EyeKey.round, blink: 1.0),
  SeqFrame(560, eye: EyeKey.smile, groupY: 0.07),
  SeqFrame(1250, eye: EyeKey.soft),
  SeqFrame(2000, eye: EyeKey.bar, groupY: 0),
]);

// ------------------------------------------------------------------ 情绪层
//
// 情绪与状态**正交**：状态回答"它在干什么"（待机/聆听/思考/说话/出错），
// 情绪回答"它此刻什么心情"。因此情绪不改 PetState 语义，
// 只做两件事：① 决定这段心情下的眼型轮转；② 叠加这段心情专属的动效。
// 情绪可以独立于状态变化（AI 说到好笑的地方，眼睛立刻变），
// 也可以被状态打断（出错时强制回到 error 的表情）。

/// 情绪。tag 是与模型约定的线格式（仅这一个词进入传输协议）。
enum Emotion {
  neutral,
  happy,
  excited,
  curious,
  shy,
  proud,
  worried,
  sad,
  angry,
  sleepy,
}

class EmotionProfile {
  const EmotionProfile({
    required this.tag,
    required this.label,
    this.eyes = const [],
    this.anims = const [],
    this.blinkScale = 1.0,
    this.glowBias = 0.0,
    this.tiltBias = 0.0,
    this.entry,
  });

  /// 线格式标记（模型输出的就是这个词）。
  final String tag;

  /// 中文名（仅用于 system prompt 里给模型看清选项）。
  final String label;

  /// 该情绪下的眼型轮转表。空 = 沿用状态自己的 cycle（neutral 就是这样）。
  final List<EyeKey> eyes;

  /// 该情绪专属的叠加动效（与状态动效求和，互不抢占）。
  final List<AnimPrim> anims;

  /// 眨眼间隔倍率。<1 更频繁（紧张），>1 更慢（疲惫/低落）。
  final double blinkScale;

  /// 发光增益。
  final double glowBias;

  /// 头部恒定倾斜（弧度，情绪性的"歪头"）。
  final double tiltBias;

  /// 切换到该情绪时补一个临时动作（可打断，首尾归零）。
  final PetAction? entry;
}

const Map<Emotion, EmotionProfile> kEmotions = {
  Emotion.neutral: EmotionProfile(tag: 'neutral', label: '平静'),
  Emotion.happy: EmotionProfile(
    tag: 'happy',
    label: '开心',
    eyes: [EyeKey.smile, EyeKey.arc, EyeKey.smile, EyeKey.soft],
    // 单向脉冲 = 轻快的上跳感（平均值上扬，不会显得忽大忽小）
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.pulse, 0.100, 900),
      AnimPrim(AnimTarget.scale, AnimType.pulse, 0.020, 900),
    ],
  ),
  Emotion.excited: EmotionProfile(
    tag: 'excited',
    label: '兴奋',
    eyes: [EyeKey.wide, EyeKey.round, EyeKey.smile, EyeKey.wide],
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.pulse, 0.180, 700),
      AnimPrim(AnimTarget.scale, AnimType.pulse, 0.035, 700),
      AnimPrim(AnimTarget.groupX, AnimType.shake, 0.030, 700),
    ],
    entry: PetAction.hop,
  ),
  Emotion.curious: EmotionProfile(
    tag: 'curious',
    label: '好奇',
    eyes: [EyeKey.curious, EyeKey.round, EyeKey.curious, EyeKey.soft],
    anims: [
      AnimPrim(AnimTarget.gazeX, AnimType.glance, 0.100, 2200),
      AnimPrim(AnimTarget.gazeY, AnimType.drift, 0.060, 2600),
      AnimPrim(AnimTarget.tilt, AnimType.drift, 0.030, 3000),
    ],
  ),
  Emotion.shy: EmotionProfile(
    tag: 'shy',
    label: '害羞',
    eyes: [EyeKey.shy, EyeKey.shy, EyeKey.soft, EyeKey.doze],
    anims: [
      // 视线向下（pulse 只朝正方向 = 屏幕下方）
      AnimPrim(AnimTarget.gazeY, AnimType.pulse, 0.090, 3400),
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.060, 3600),
      AnimPrim(AnimTarget.tilt, AnimType.drift, 0.050, 4200),
    ],
    blinkScale: 0.7,
  ),
  Emotion.proud: EmotionProfile(
    tag: 'proud',
    label: '得意',
    eyes: [EyeKey.crescent, EyeKey.smile, EyeKey.arc],
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.080, 3000),
      AnimPrim(AnimTarget.tilt, AnimType.drift, -0.040, 3400),
    ],
  ),
  Emotion.worried: EmotionProfile(
    tag: 'worried',
    label: '担心',
    eyes: [EyeKey.sad, EyeKey.shy, EyeKey.sad, EyeKey.helpless],
    anims: [
      AnimPrim(AnimTarget.gazeX, AnimType.shake, 0.020, 900),
      AnimPrim(AnimTarget.tilt, AnimType.drift, 0.035, 2600),
    ],
    blinkScale: 0.75,
  ),
  Emotion.sad: EmotionProfile(
    tag: 'sad',
    label: '难过',
    eyes: [EyeKey.sad, EyeKey.helpless, EyeKey.sad, EyeKey.doze],
    anims: [
      // 负向脉冲 = 整体下沉
      AnimPrim(AnimTarget.groupY, AnimType.pulse, -0.120, 5200),
      AnimPrim(AnimTarget.gazeY, AnimType.pulse, 0.100, 5600),
    ],
    blinkScale: 1.6,
  ),
  Emotion.angry: EmotionProfile(
    tag: 'angry',
    label: '生气',
    eyes: [EyeKey.angry, EyeKey.angry, EyeKey.helpless],
    anims: [
      AnimPrim(AnimTarget.groupX, AnimType.shake, 0.020, 520),
      AnimPrim(AnimTarget.tilt, AnimType.shake, 0.008, 600),
    ],
    blinkScale: 0.85,
    glowBias: 0.10,
    entry: PetAction.wobble,
  ),
  Emotion.sleepy: EmotionProfile(
    tag: 'sleepy',
    label: '困倦',
    eyes: [EyeKey.doze, EyeKey.half, EyeKey.doze, EyeKey.closed],
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.100, 6200),
      AnimPrim(AnimTarget.gazeY, AnimType.pulse, 0.060, 7000),
    ],
    blinkScale: 1.4,
  ),
};

/// 线格式 → 情绪。未知标记一律当作 neutral（绝不因模型的错别字而崩）。
Emotion emotionFromTag(String tag) {
  for (final e in kEmotions.entries) {
    if (e.value.tag == tag) return e.key;
  }
  return Emotion.neutral;
}

/// 给 system prompt 用的情绪清单，与枚举同源，避免两边写歪。
String emotionTagList() =>
    kEmotions.values.map((e) => '${e.tag}（${e.label}）').join('、');

/// 每个状态的目标描述。
class StateProfile {
  const StateProfile({
    required this.base,
    required this.cycle,
    required this.holdMs,
    required this.blinkMs,
    required this.gazeDrift,
    required this.overlay,
    this.anims = const [],
    this.sequence,
  });

  final EyeKey base;
  final List<EyeKey> cycle;
  final List<double> holdMs;
  final List<double> blinkMs;
  final bool gazeDrift;

  /// 该状态的叠加特效。null = 无叠加层（不要用"空特效"占位，
  /// 否则会留下一个权重恒为 1 却永不绘制的僵尸层）。
  final OverlayKind? overlay;

  /// 常驻动效：呼吸、漂浮、扫视、脉冲。状态存续期间一直叠加。
  final List<AnimPrim> anims;

  /// 进入该状态时先演一段有限时长的表情戏；结束后按 settle 收尾。
  final Sequence? sequence;
}

const Map<PetState, StateProfile> kProfiles = {
  PetState.idle: StateProfile(
    base: EyeKey.bar,
    cycle: [EyeKey.bar, EyeKey.bar, EyeKey.soft, EyeKey.thin, EyeKey.curious, EyeKey.bar],
    holdMs: [9000, 17000],
    blinkMs: [6000, 14000],
    gazeDrift: true,
    // 什么都不做时不该有"思考中"的三点 —— 那是 thinking 的语汇。
    overlay: null,
    anims: [
      // 低频漂浮 + 呼吸：没人理它的时候，它也在"活着"。
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.30, 11000),
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.16, 4600, phase: 0.5),
      // 心跳式缩放（单向脉冲，只朝上顶，不会显得忽大忽小）
      AnimPrim(AnimTarget.scale, AnimType.pulse, 0.012, 4600),
      // 无意识扫视
      AnimPrim(AnimTarget.gazeX, AnimType.glance, 0.050, 6100),
      AnimPrim(AnimTarget.gazeY, AnimType.drift, 0.028, 7300),
    ],
  ),
  PetState.listening: StateProfile(
    base: EyeKey.soft,
    cycle: [EyeKey.soft, EyeKey.round, EyeKey.curious, EyeKey.soft, EyeKey.bar],
    holdMs: [2200, 4200],
    blinkMs: [3000, 7000],
    gazeDrift: false,
    overlay: OverlayKind.micRing,
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.055, 3400),
      AnimPrim(AnimTarget.gazeY, AnimType.drift, 0.030, 4100, phase: 0.2),
    ],
    // 听到的一瞬间"竖起来"：好奇地抬眼看。
    sequence: Sequence([
      SeqFrame(0, eye: EyeKey.curious, blink: 1.04, gazeY: -0.10),
      SeqFrame(540, eye: EyeKey.soft, gazeY: -0.02),
    ]),
  ),
  PetState.thinking: StateProfile(
    base: EyeKey.thin,
    cycle: [EyeKey.thin, EyeKey.thin, EyeKey.helpless, EyeKey.bar],
    holdMs: [1500, 2800],
    blinkMs: [4000, 9000],
    gazeDrift: true,
    overlay: OverlayKind.dots,
    anims: [
      AnimPrim(AnimTarget.tilt, AnimType.drift, 0.020, 4800),
      AnimPrim(AnimTarget.gazeX, AnimType.glance, 0.075, 2600),
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.070, 5200),
    ],
    // 专注一会儿后叹口气；settle=next 让它自动接回眼型游走。
    sequence: Sequence([
      SeqFrame(0, eye: EyeKey.thin, tilt: 0.05, gazeY: -0.14),
      SeqFrame(900, eye: EyeKey.thin, tilt: 0.05, gazeY: -0.10),
      SeqFrame(1500, eye: EyeKey.helpless, tilt: 0.12, gazeY: 0.06),
      SeqFrame(2100, eye: EyeKey.thin, tilt: 0.05, gazeY: -0.12),
    ], settle: SettleKind.next),
  ),
  PetState.speaking: StateProfile(
    base: EyeKey.soft,
    cycle: [EyeKey.soft, EyeKey.arc, EyeKey.smile, EyeKey.soft, EyeKey.wide],
    holdMs: [1700, 3200],
    blinkMs: [4000, 9000],
    gazeDrift: true,
    overlay: OverlayKind.wave,
    anims: [
      AnimPrim(AnimTarget.groupY, AnimType.drift, 0.050, 2900),
      AnimPrim(AnimTarget.gazeY, AnimType.drift, 0.032, 3700, phase: 0.35),
    ],
    // 开口先笑一下。
    sequence: Sequence([
      SeqFrame(0, eye: EyeKey.smile, blink: 1.05),
      SeqFrame(620, eye: EyeKey.soft),
    ]),
  ),
  PetState.error: StateProfile(
    base: EyeKey.angry,
    cycle: [EyeKey.angry, EyeKey.sad, EyeKey.angry],
    holdMs: [1900, 3200],
    blinkMs: [3000, 6000],
    gazeDrift: false,
    overlay: OverlayKind.bang,
    anims: [
      AnimPrim(AnimTarget.groupX, AnimType.shake, 0.055, 620),
      AnimPrim(AnimTarget.tilt, AnimType.shake, 0.012, 740),
    ],
    // 惊慌 → 生气，然后停住（settle=hold，出错时表情固定，不再游走）。
    sequence: Sequence([
      SeqFrame(0, eye: EyeKey.panic, blink: 1.16, groupY: -0.18, scale: 0.04),
      SeqFrame(280, eye: EyeKey.panic, groupY: -0.06),
      SeqFrame(660, eye: EyeKey.angry, groupY: 0.04),
    ], settle: SettleKind.hold),
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

  // ---- 声明式动效 ----
  List<AnimPrim> _anims = const [];
  Sequence? _seq;
  double _seqStartMs = 0;
  int _seqCursor = 0;

  // ---- 情绪层（与状态正交，只影响眼型轮转与叠加动效）----
  Emotion _emotion = Emotion.neutral;
  Emotion get emotion => _emotion;
  List<AnimPrim> _emoAnims = const [];

  /// settle=hold 时冻结眼型游走（表情停住不再换）。
  bool _seqHold = false;

  /// 关键帧表演对群组变换的临时覆盖（null = 该通道未被表演占用）。
  double? _seqGroupY;
  double? _seqTilt;
  double? _seqScale;

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

  /// 设置情绪。与 [setState] 完全独立：情绪不改变状态机，只换"脸色"。
  /// 立刻生效（不等下一次眼型游走），否则观众会觉得它反应迟钝。
  void setEmotion(Emotion next) {
    if (next == _emotion) return;
    _emotion = next;
    final e = kEmotions[next]!;
    _emoAnims = e.anims;
    if (_state != PetState.error) {
      _cycleIndex = 0;
      _morphTo(_activeCycle.first);
      _nextEyeAt = _nowMs + randRange(_rnd, 1600, 3000);
    }
    final entry = e.entry;
    if (entry != null) trigger(entry);
  }

  /// 当前生效的眼型轮转表：情绪优先，出错状态强制用状态自己的表。
  List<EyeKey> get _activeCycle {
    final p = kProfiles[_state]!;
    if (_state == PetState.error) return p.cycle;
    final eyes = kEmotions[_emotion]!.eyes;
    return eyes.isEmpty ? p.cycle : eyes;
  }

  /// 眨眼间隔（受情绪倍率影响：紧张更快、低落更慢）。
  double _nextBlinkDelay(StateProfile p) {
    final s = kEmotions[_emotion]!.blinkScale;
    return randRange(_rnd, p.blinkMs[0] * s, p.blinkMs[1] * s);
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
    playSequence(kGreetSequence);
  }

  /// 外部也可以点播一段表演（例如打招呼）；同样只写 target / 关键帧，
  /// 不直接写动画值，因此任何时刻打断都不会跳变。
  void playSequence(Sequence seq) {
    _seq = seq;
    _seqStartMs = _nowMs;
    _seqCursor = 0;
    _seqGroupY = null;
    _seqTilt = null;
    _seqScale = null;
    _seqHold = false;
    final f = seq.frames.first;
    if (f.eye != null) _morphTo(f.eye!);
    if (f.blink != null) _blink.to(f.blink!);
    if (f.gazeX != null) _gazeX.to(f.gazeX!);
    if (f.gazeY != null) _gazeY.to(f.gazeY!);
  }

  /// 硬重置（仅在引擎刚创建 / 尺寸剧变时使用）。
  void hardReset(PetState state) => _applyState(state, hard: true);

  // ------------------------------------------------------------------ 状态机

  void _applyState(PetState next, {required bool hard}) {
    _state = next;
    final p = kProfiles[next]!;
    _cycleIndex = 0;
    _eyeCycleKey = _activeCycle.first;
    _anims = p.anims;

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
    _nextBlinkAt = _nowMs + _nextBlinkDelay(p);
    _nextGazeAt = _nowMs + randRange(_rnd, 900, 1800);
    _blinkStep = 0;
    _blinkStepAt = -1;
    _fade.to(1);

    _applyOverlay(p.overlay);
    if (next == PetState.speaking) _energy.to(0.2);

    // 先演入场表情戏（若有），随后交给常规循环。
    _seq = null;
    _seqGroupY = null;
    _seqTilt = null;
    _seqScale = null;
    _seqHold = false;
    final seq = p.sequence;
    if (seq != null) playSequence(seq);
  }

  /// 快照当前实际形态后追新眼型 —— 唯一的眼型切换入口。
  void _morphTo(EyeKey k) {
    if (k == _eyeKey) return;
    _eyeFrom = _currentEyeParams();
    _eyeKey = k;
    _morph.snap(0, keepVelocity: true);
    _morph.to(1);
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
    _nextBlinkAt = _nowMs + _nextBlinkDelay(p);
    _nextGazeAt = _nowMs + randRange(_rnd, 900, 1800);
    _nextActionAt = _nowMs + randRange(_rnd, 4000, 8000);
  }

  void _timers() {
    final p = kProfiles[_state]!;

    // 关键帧表演优先：它占用期间，眼型游走 / 眨眼 / 视线漂移全部让位，
    // 否则同一帧里会有两个写入者互相抢 target。
    _stepSequence();
    final inSeq = _seq != null;

    // 眼型游走
    if (!inSeq && !_seqHold && _nowMs >= _nextEyeAt) {
      _cycleIndex++;
      final cyc = _activeCycle;
      _eyeCycleKey = cyc[_cycleIndex % cyc.length];
      _morphTo(_eyeCycleKey);
      _nextEyeAt = _nowMs + randRange(_rnd, p.holdMs[0], p.holdMs[1]);
    }

    // 眨眼（时间线驱动的目标序列，仍然只写 target）
    if (!inSeq) {
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
          var next = _nextBlinkDelay(p);
          if (_rnd.nextDouble() < 0.12) next = 420; // 偶发连眨
          _nextBlinkAt = _nowMs + next;
        }
      }
    }

    // 视线漂移
    if (!inSeq && _nowMs >= _nextGazeAt) {
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

  /// 推进关键帧表演：眼型是离散通道（跨帧时做快照式形变），
  /// 标量通道在相邻两帧之间用 easeInOut 连续插值，因此整段表演无跳变。
  void _stepSequence() {
    final seq = _seq;
    if (seq == null) return;
    final frames = seq.frames;
    final t = _nowMs - _seqStartMs;

    while (_seqCursor + 1 < frames.length && t >= frames[_seqCursor + 1].atMs) {
      _seqCursor++;
      final e = frames[_seqCursor].eye;
      if (e != null) _morphTo(e);
    }

    final a = frames[_seqCursor];
    final b = _seqCursor + 1 < frames.length ? frames[_seqCursor + 1] : null;
    final span = b == null ? 0.0 : b.atMs - a.atMs;
    final k = (b == null || span <= 0) ? 1.0 : easeInOut((t - a.atMs) / span);

    final blink = _lerpOpt(a.blink, b?.blink, k);
    if (blink != null) _blink.to(blink);
    final gx = _lerpOpt(a.gazeX, b?.gazeX, k);
    if (gx != null) _gazeX.to(gx);
    final gy = _lerpOpt(a.gazeY, b?.gazeY, k);
    if (gy != null) _gazeY.to(gy);

    _seqGroupY = _lerpOpt(a.groupY, b?.groupY, k);
    _seqTilt = _lerpOpt(a.tilt, b?.tilt, k);
    _seqScale = _lerpOpt(a.scale, b?.scale, k);

    if (t < seq.durationMs) return;

    // 收尾
    final p = kProfiles[_state]!;
    _seq = null;
    _seqGroupY = null;
    _seqTilt = null;
    _seqScale = null;
    switch (seq.settle) {
      case SettleKind.base:
        // 让末帧表情停一会儿，再回到常规游走。
        _nextEyeAt = _nowMs + randRange(_rnd, p.holdMs[0], p.holdMs[1]);
      case SettleKind.hold:
        _seqHold = true;
      case SettleKind.next:
        _nextEyeAt = _nowMs; // 立刻接入下一段表演
    }
  }

  static double? _lerpOpt(double? a, double? b, double k) {
    if (a == null) return b;
    if (b == null) return a;
    return lerpD(a, b, k);
  }

  /// 波形求值：同一组 (幅度, 周期) 换波形即换观感。
  static double _wave(AnimType type, double nowMs, double periodMs, double phase) {
    final t = nowMs / periodMs + phase;
    final s = math.sin(2 * math.pi * t);
    switch (type) {
      case AnimType.drift:
        return s;
      case AnimType.glance:
        const k = 2.6;
        return (math.exp(k * s) - math.exp(-k * s)) / (math.exp(k) - math.exp(-k));
      case AnimType.pulse:
        return (s + 1) * 0.5;
      case AnimType.shake:
        return s + 0.35 * math.sin(6 * math.pi * t);
    }
  }

  /// 把状态动效与情绪动效按作用对象求和。
  double _anim(AnimTarget target) {
    double v = 0;
    for (final a in _anims) {
      if (a.target == target) v += a.amp * _wave(a.type, _nowMs, a.periodMs, a.phase);
    }
    for (final a in _emoAnims) {
      if (a.target == target) v += a.amp * _wave(a.type, _nowMs, a.periodMs, a.phase);
    }
    return v;
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

    gazeX = _gazeX.value + _anim(AnimTarget.gazeX);
    gazeY = _gazeY.value + _anim(AnimTarget.gazeY);

    // 群组变换：漂浮 + 键盘上移 + 临时动作包络 + 声明式动效 + 关键帧覆盖
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

    final emo = kEmotions[_emotion]!;
    groupX = sideAct + _anim(AnimTarget.groupX);
    groupY = _bob.value +
        act +
        _lift.value +
        _anim(AnimTarget.groupY) +
        (_seqGroupY ?? 0) -
        0.35 * live -
        (_state == PetState.speaking ? 0.12 * live : 0);
    groupTilt = tiltAct + _anim(AnimTarget.tilt) + (_seqTilt ?? 0) + emo.tiltBias;
    groupScale = _scale.value *
        _liftScale.value *
        pulse *
        (1 + _anim(AnimTarget.scale) + (_seqScale ?? 0));
    opacity = clamp(_fade.value, 0, 1);
    glow = clamp(
      0.32 + 0.75 * live + (_state == PetState.thinking ? 0.12 : 0) + emo.glowBias,
      0,
      1.4,
    );
  }
}

/// 轻量 2D 向量（避免 engine 依赖 material）。
@immutable
class Offset2 {
  const Offset2(this.x, this.y);
  final double x;
  final double y;
}