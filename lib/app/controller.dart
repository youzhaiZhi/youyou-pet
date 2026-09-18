import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/chat.dart';
import '../engine/pet_engine.dart';
import '../platform/native.dart';
import '../tts/tts.dart';

/// 应用设置。API Key 单独走加密存储，其余走普通偏好。
class AppSettings {
  AppSettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-4o-mini',
    this.temperature = 0.8,
    this.systemPrompt = defaultSystemPrompt,
    this.ttsMode = 'system',
    this.ttsBaseUrl = '',
    this.ttsModel = 'tts-1',
    this.ttsVoice = 'alloy',
    this.ttsSampleRate = 24000,
    this.ttsSpeed = 1.0,
    this.fallbackToSystem = true,
    this.placeholderSound = true,
    this.autoSpeak = true,
    this.showMetrics = false,
  });

  String baseUrl;
  String model;
  double temperature;
  String systemPrompt;

  /// 'system' | 'cloud'
  String ttsMode;
  String ttsBaseUrl;
  String ttsModel;
  String ttsVoice;
  int ttsSampleRate;
  double ttsSpeed;

  /// 云端 TTS 超时/失败时是否退回系统 TTS。
  bool fallbackToSystem;
  bool placeholderSound;
  bool autoSpeak;
  bool showMetrics;

  Map<String, Object?> toJson() => {
        'baseUrl': baseUrl,
        'model': model,
        'temperature': temperature,
        'systemPrompt': systemPrompt,
        'ttsMode': ttsMode,
        'ttsBaseUrl': ttsBaseUrl,
        'ttsModel': ttsModel,
        'ttsVoice': ttsVoice,
        'ttsSampleRate': ttsSampleRate,
        'ttsSpeed': ttsSpeed,
        'fallbackToSystem': fallbackToSystem,
        'placeholderSound': placeholderSound,
        'autoSpeak': autoSpeak,
        'showMetrics': showMetrics,
      };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings(
        baseUrl: j['baseUrl'] as String? ?? 'https://api.openai.com/v1',
        model: j['model'] as String? ?? 'gpt-4o-mini',
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.8,
        systemPrompt: j['systemPrompt'] as String? ?? defaultSystemPrompt,
        ttsMode: j['ttsMode'] as String? ?? 'system',
        ttsBaseUrl: j['ttsBaseUrl'] as String? ?? '',
        ttsModel: j['ttsModel'] as String? ?? 'tts-1',
        ttsVoice: j['ttsVoice'] as String? ?? 'alloy',
        ttsSampleRate: (j['ttsSampleRate'] as num?)?.toInt() ?? 24000,
        ttsSpeed: (j['ttsSpeed'] as num?)?.toDouble() ?? 1.0,
        fallbackToSystem: j['fallbackToSystem'] as bool? ?? true,
        placeholderSound: j['placeholderSound'] as bool? ?? true,
        autoSpeak: j['autoSpeak'] as bool? ?? true,
        showMetrics: j['showMetrics'] as bool? ?? false,
      );
}

/// 连接状态灯。
enum LinkStatus { ready, busy, error }

class PetController extends ChangeNotifier {
  PetController() {
    speech = SpeechPipeline(bridge);
    speech.engine = engine;
    speech.onState = (s) {
      if (s == PetState.speaking) {
        engine.setState(PetState.speaking);
      } else {
        // 音频播完时模型可能还在流式输出，那就回到"思考中"而不是闲置。
        engine.setState(streaming ? PetState.thinking : PetState.idle);
      }
      status = LinkStatus.ready;
      notifyListeners();
    };
  }

  final PetEngine engine = PetEngine();
  final NativeBridge bridge = NativeBridge.instance;
  final ChatClient chat = ChatClient();
  late final SpeechPipeline speech;

  AppSettings settings = AppSettings();
  String apiKey = '';

  /// 云端 TTS 的独立 Key。留空则复用 [apiKey]（见 ChatConfig.speechApiKey）。
  String ttsApiKey = '';

  LinkStatus status = LinkStatus.ready;

  /// 正在流式输出的回复文本（界面上以极简字幕呈现）。
  String liveText = '';
  bool streaming = false;
  bool recording = false;
  String? lastError;

  final List<Map<String, String>> _history = [];
  final SentenceSplitter _splitter = SentenceSplitter();
  int _replySeq = 0;

  String get metricsText {
    final m = speech.metrics;
    String f(int v) => v < 0 ? '—' : '$v ms';
    return '引擎 ${m.engine}\n'
        'ttft  ${f(m.ttftMs)}\n'
        '首句切分 ${f(m.firstCutMs)}\n'
        'ttfa  ${f(m.ttfaMs)}\n'
        '单句首字节 ${f(m.lastSynthFirstMs)}\n'
        '单句合成 ${f(m.lastSynthTotalMs)}\n'
        '句数 ${m.segments}  兜底 ${m.fallbacks}  占位音 ${m.placeholders}';
  }

  // ------------------------------------------------------------------ 初始化

  Future<void> init() async {
    bridge.bind();
    speech.attach();
    await bridge.requestHighRefreshRate();
    await bridge.keepScreenOn(true);
    await _load();
    engine.greet();
    notifyListeners();
  }

  Future<void> _load() async {
    final raw = await bridge.prefsGet('settings');
    if (raw != null && raw.isNotEmpty) {
      try {
        settings = AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    apiKey = await bridge.secretGet('apiKey') ?? '';
    ttsApiKey = await bridge.secretGet('ttsApiKey') ?? '';
    _applySpeechConfig();
    if (settings.ttsMode == 'system') {
      unawaited(bridge.systemTtsInit());
    }
  }

  Future<void> save() async {
    await bridge.prefsSet('settings', jsonEncode(settings.toJson()));
    await bridge.secretSet('apiKey', apiKey);
    await bridge.secretSet('ttsApiKey', ttsApiKey);
    _applySpeechConfig();
    if (settings.ttsMode == 'system') {
      unawaited(bridge.systemTtsInit());
    }
    notifyListeners();
  }

  ChatConfig get chatConfig => ChatConfig(
        baseUrl: settings.baseUrl,
        apiKey: apiKey,
        model: settings.model,
        temperature: settings.temperature,
        systemPrompt: settings.systemPrompt,
        ttsBaseUrl: settings.ttsBaseUrl,
        ttsApiKey: ttsApiKey,
        ttsModel: settings.ttsModel,
        ttsVoice: settings.ttsVoice,
        ttsSampleRate: settings.ttsSampleRate,
        ttsSpeed: settings.ttsSpeed,
        useSystemTts: settings.fallbackToSystem,
        placeholderSound: settings.placeholderSound,
      );

  void _applySpeechConfig() {
    final cfg = chatConfig;
    final TtsProvider provider = settings.ttsMode == 'cloud'
        ? OpenAiTtsProvider()
        : SystemTtsProvider(bridge);
    speech.configure(cfg, provider);
    unawaited(bridge.audioInit(sampleRate: settings.ttsSampleRate));
    if (apiKey.isNotEmpty) {
      unawaited(chat.warmup(cfg.chatEndpoint, apiKey));
    }
  }

  // -------------------------------------------------------------------- 对话

  Future<void> send(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || streaming) return;
    if ((settings.baseUrl.isEmpty) || apiKey.isEmpty) {
      _fail('还没配置 API，点右上角齿轮填一下地址和 Key');
      return;
    }

    await speech.stop();
    status = LinkStatus.busy;
    streaming = true;
    liveText = '';
    lastError = null;
    engine.setState(PetState.thinking);
    engine.trigger(PetAction.hop);
    notifyListeners();

    speech.beginReply();
    _splitter.reset();
    final seq = ++_replySeq;

    _history.add({'role': 'user', 'content': text});
    if (_history.length > 24) _history.removeAt(0);

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': settings.systemPrompt},
      ..._history,
    ];

    final buf = StringBuffer();
    try {
      final stream = chat.stream(
        messages,
        chatConfig,
        onFirstToken: (ms) {
          speech.metrics.ttftMs = ms;
          notifyListeners();
        },
      );
      await for (final piece in stream) {
        if (seq != _replySeq) return;
        buf.write(piece);
        liveText = buf.toString();
        notifyListeners();
        for (final s in _splitter.push(
          piece,
          nowMs: DateTime.now().millisecondsSinceEpoch,
        )) {
          if (seq != _replySeq) return;
          if (speech.metrics.firstCutMs < 0) {
            speech.metrics.firstCutMs = _splitter.firstCutMs;
          }
          if (settings.autoSpeak) speech.enqueue(s);
        }
      }
      final tail = _splitter.flush();
      if (settings.autoSpeak && tail != null) speech.enqueue(tail);
      speech.finish();

      final answer = buf.toString().trim();
      if (answer.isNotEmpty) {
        _history.add({'role': 'assistant', 'content': answer});
        if (_history.length > 24) _history.removeAt(0);
      }
      status = LinkStatus.ready;
    } catch (e) {
      _fail('连接失败：$e');
      await speech.stop();
    } finally {
      if (seq == _replySeq) {
        streaming = false;
        if (engine.state != PetState.error) {
          engine.setState(PetState.idle);
        }
        notifyListeners();
      }
    }
  }

  void _fail(String message) {
    lastError = message;
    status = LinkStatus.error;
    engine.setState(PetState.error);
    notifyListeners();
    Timer(const Duration(milliseconds: 2600), () {
      if (!streaming) {
        engine.setState(PetState.idle);
        status = LinkStatus.ready;
      }
      notifyListeners();
    });
  }

  Future<void> stopAll() async {
    _replySeq++;
    streaming = false;
    await speech.stop();
    engine.setState(PetState.idle);
    status = LinkStatus.ready;
    notifyListeners();
  }

  // -------------------------------------------------------------------- 语音

  Future<void> toggleMic(void Function(String partial) onPartial) async {
    if (recording) {
      recording = false;
      await bridge.asrStop();
      engine.setState(PetState.idle);
      notifyListeners();
      return;
    }
    final granted = await bridge.requestMic();
    if (!granted) {
      _fail('没有麦克风权限');
      return;
    }
    bridge.onAsrResult = (text, isFinal) {
      onPartial(text);
      if (isFinal) {
        recording = false;
        engine.setState(PetState.idle);
        notifyListeners();
      }
    };
    final ok = await bridge.asrStart();
    if (!ok) {
      _fail('语音识别不可用，请直接用键盘输入');
      return;
    }
    recording = true;
    engine.setState(PetState.listening);
    notifyListeners();
  }

  void poke() {
    engine.trigger(PetAction.tilt);
  }

  @override
  void dispose() {
    chat.close();
    super.dispose();
  }
}