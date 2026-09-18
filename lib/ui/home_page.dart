import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../engine/pet_engine.dart';
import '../render/pet_painter.dart';
import 'settings_page.dart';

const Color kBg = Color(0xFF000000);
const Color kField = Color(0xFF1C1C1E);
const Color kGray = Color(0xFF8E8E93);
const Color kDim = Color(0xFF636366);
const Color kRed = Color(0xFFFF3B30);
const Color kGreen = Color(0xFF30D158);
const Color kYellow = Color(0xFFFFD60A);

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final PetController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  late final AnimationController _pulse;

  PetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((elapsed) {
      c.engine.update(elapsed.inMicroseconds / 1000.0);
    })..start();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _pulse.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final inset = View.of(context).viewInsets.bottom;
    c.engine.setKeyboardOpen(inset > 40);
  }

  Future<void> _submit() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    _focus.unfocus();
    await c.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final micSize = size.width * 0.127;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: kBg,
        resizeToAvoidBottomInset: true,
        body: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            return Stack(
              children: [
                // 角色本体（纯黑背景上只剩一双发光的眼睛）
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: PetPainter(c.engine),
                      isComplex: true,
                      willChange: true,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),

                // 拖动 / 点击让眼睛跟随
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: c.poke,
                    onPanUpdate: (d) {
                      final unit = size.width * kEyeHalfWidthRatio;
                      final local = d.localPosition;
                      final dx = (local.dx - size.width / 2) / unit;
                      final dy = (local.dy - size.height * kEyeCenterYRatio) / unit;
                      c.engine.setPointer(Offset2(
                        (dx * 0.32).clamp(-0.85, 0.85),
                        (dy * 0.32).clamp(-0.7, 0.7),
                      ));
                    },
                    onPanEnd: (_) => c.engine.setPointer(null),
                  ),
                ),

                _brandRow(size),
                _gear(size),
                _subtitle(size),

                if (c.settings.showMetrics) _metrics(size),

                _bottomBar(size, bottomInset, micSize),
              ],
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 顶部

  Widget _brandRow(Size size) {
    final color = switch (c.status) {
      LinkStatus.ready => kGreen,
      LinkStatus.busy => kYellow,
      LinkStatus.error => kRed,
    };
    return Positioned(
      left: 22,
      top: MediaQuery.paddingOf(context).top + 16,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          const Text(
            'Y O U Y O U',
            style: TextStyle(
              color: kGray,
              fontSize: 11,
              letterSpacing: 3.6,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  Widget _gear(Size size) {
    return Positioned(
      right: 12,
      top: MediaQuery.paddingOf(context).top + 6,
      child: IconButton(
        splashRadius: 20,
        icon: const Icon(Icons.settings_outlined, color: kGray, size: 20),
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SettingsPage(controller: c)),
          );
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // ------------------------------------------------------------ 字幕（极简）

  Widget _subtitle(Size size) {
    final hasError = c.lastError != null && c.lastError!.isNotEmpty;
    final hasLive = c.liveText.isNotEmpty;
    final configured = c.settings.baseUrl.isNotEmpty && c.apiKey.isNotEmpty;

    // 优先级：报错 > 实时字幕 > 未配置时的引导。
    // 已配置且静默时整块移除 —— 引导语不该在配好之后还常驻。
    final String? text = hasError
        ? c.lastError
        : hasLive
            ? c.liveText
            : configured
                ? null
                : '点右上角齿轮，填入你自己的 API 地址与 Key';
    if (text == null) return const SizedBox.shrink();

    return Positioned(
      left: size.width * 0.13,
      right: size.width * 0.13,
      top: size.height * 0.52,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 420),
        opacity: (hasError || hasLive) ? 1 : 0.42,
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: hasError ? kRed : kGray,
            fontSize: 14.5,
            height: 1.55,
            decoration: TextDecoration.none,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _metrics(Size size) {
    return Positioned(
      left: 22,
      top: MediaQuery.paddingOf(context).top + 58,
      child: IgnorePointer(
        child: Text(
          c.metricsText,
          style: const TextStyle(
            color: kDim,
            fontSize: 10.5,
            height: 1.5,
            fontFamily: 'monospace',
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 底部

  Widget _bottomBar(Size size, double bottomInset, double micSize) {
    final active = c.streaming || c.speech.busy;
    return Positioned(
      left: 0,
      right: 0,
      bottom: (bottomInset > 0 ? 14 : 26) + MediaQuery.paddingOf(context).bottom * 0.4,
      child: Column(
        children: [
          SizedBox(
            width: size.width * 0.82,
            height: 52,
            child: TextField(
              controller: _input,
              focusNode: _focus,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: Colors.white70,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                isCollapsed: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 17),
                hintText: '说点什么…',
                hintStyle: TextStyle(color: kDim, fontSize: 15),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                fillColor: kField,
                filled: true,
              ),
            ),
          ),
          SizedBox(height: bottomInset > 0 ? 12 : 22),
          _micButton(micSize, active),
        ],
      ),
    );
  }

  Widget _micButton(double micSize, bool active) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final breathe = c.recording ? 1 + 0.055 * _pulse.value : 1.0;
        return GestureDetector(
          onTap: () {
            if (active) {
              c.stopAll();
            } else {
              c.toggleMic((partial) {
                _input.text = partial;
                _input.selection =
                    TextSelection.collapsed(offset: _input.text.length);
              });
            }
            setState(() {});
          },
          child: Transform.scale(
            scale: breathe,
            child: Container(
              width: micSize,
              height: micSize,
              decoration: const BoxDecoration(
                color: kField,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  active ? Icons.stop_rounded : Icons.mic_none_rounded,
                  size: micSize * 0.42,
                  color: active ? Colors.white : kRed,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}