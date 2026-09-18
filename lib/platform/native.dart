import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 原生事件（由 Kotlin 侧回调上来）。
class NativeEvent {
  const NativeEvent(this.name, this.args);
  final String name;
  final Map<String, dynamic> args;
}

/// 与 Android 原生层的唯一通道。
///
/// 之所以不用第三方插件：TTS 低延迟要求"PCM 直出 + AudioTrack MODE_STREAM 小缓冲"，
/// 现成插件普遍经过多层队列，首音会被拖到 600ms 以上。这里由我们自己控制缓冲深度。
/// 另外零第三方依赖也让云端构建更稳。
class NativeBridge {
  NativeBridge._();

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _ch = MethodChannel('youyou/pet');

  final _events = StreamController<NativeEvent>.broadcast();
  Stream<NativeEvent> get events => _events.stream;

  bool get _android => !kIsWeb && Platform.isAndroid;

  Function(String text, bool isFinal)? onAsrResult;
  void Function()? onTtsStart;
  void Function()? onTtsDone;
  void Function()? onAudioDrained;
  void Function()? onAudioStarted;

  bool _bound = false;

  void bind() {
    if (_bound) return;
    _bound = true;
    _ch.setMethodCallHandler((call) async {
      final args = (call.arguments is Map)
          ? Map<String, dynamic>.from(call.arguments as Map)
          : <String, dynamic>{};
      switch (call.method) {
        case 'asr':
          final text = (args['text'] as String?) ?? '';
          onAsrResult?.call(text, (args['final'] as bool?) ?? false);
        case 'ttsStart':
          onTtsStart?.call();
        case 'ttsDone':
          onTtsDone?.call();
        case 'audioDrained':
          onAudioDrained?.call();
        case 'audioStarted':
          onAudioStarted?.call();
      }
      _events.add(NativeEvent(call.method, args));
      return null;
    });
  }

  // ------------------------------------------------------------------ 音频输出

  /// 建立一个常驻的流式 AudioTrack（24kHz / 单声道 / 16bit）。
  Future<bool> audioInit({int sampleRate = 24000}) async {
    if (!_android) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('audioInit', {'sampleRate': sampleRate});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 写入一段 PCM。**不要 await 太久** —— 原生侧只是入队后立刻返回。
  Future<void> audioWrite(Uint8List pcm) async {
    if (!_android || pcm.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('audioWrite', pcm);
    } catch (_) {}
  }

  /// 标记"本句数据已写完"，原生侧会在真正播完后回调 audioDrained。
  Future<void> audioMark() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('audioMark');
    } catch (_) {}
  }

  /// 打断：立即停播并清空队列。
  Future<void> audioStop() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('audioStop');
    } catch (_) {}
  }

  /// 已写入但尚未播出的毫秒数（用于首音判定与进度统计）。
  Future<int> audioPendingMs() async {
    if (!_android) return 0;
    try {
      return await _ch.invokeMethod<int>('audioPendingMs') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 首音迟迟不来时播一个占位音（独立的轻量轨道，不占用主队列）。
  Future<void> playBlip() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('playBlip');
    } catch (_) {}
  }

  // ------------------------------------------------------------------ 系统 TTS

  Future<bool> systemTtsInit() async {
    if (!_android) return false;
    try {
      return await _ch.invokeMethod<bool>('ttsInit') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> systemTtsSpeak(String text) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('ttsSpeak', {'text': text});
    } catch (_) {}
  }

  Future<void> systemTtsStop() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('ttsStop');
    } catch (_) {}
  }

  // --------------------------------------------------------------------- 语音识别

  Future<bool> requestMic() async {
    if (!_android) return false;
    try {
      return await _ch.invokeMethod<bool>('requestMic') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> asrStart() async {
    if (!_android) return false;
    try {
      return await _ch.invokeMethod<bool>('asrStart') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> asrStop() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('asrStop');
    } catch (_) {}
  }

  // --------------------------------------------------------------------- 系统

  Future<void> requestHighRefreshRate() async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('highRefreshRate');
    } catch (_) {}
  }

  Future<void> keepScreenOn(bool on) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  // --------------------------------------------------------------------- 存储

  Future<String?> secretGet(String key) async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<String>('secretGet', {'key': key});
    } catch (_) {
      return null;
    }
  }

  Future<void> secretSet(String key, String value) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('secretSet', {'key': key, 'value': value});
    } catch (_) {}
  }

  Future<String?> prefsGet(String key) async {
    if (!_android) return null;
    try {
      return await _ch.invokeMethod<String>('prefsGet', {'key': key});
    } catch (_) {
      return null;
    }
  }

  Future<void> prefsSet(String key, String value) async {
    if (!_android) return;
    try {
      await _ch.invokeMethod<void>('prefsSet', {'key': key, 'value': value});
    } catch (_) {}
  }
}