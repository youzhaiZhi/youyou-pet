import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ai/chat.dart';
import '../engine/pet_engine.dart';
import '../platform/native.dart';

/// 延迟埋点。四个指标缺一不可，否则没法判断瓶颈在哪一环。
class SpeechMetrics {
  int ttftMs = -1; // 模型首 token
  int firstCutMs = -1; // 首句切分耗时
  int ttfaMs = -1; // 首音真正出声
  int lastSynthFirstMs = -1; // 单句合成首字节
  int lastSynthTotalMs = -1; // 单句合成总耗时
  int segments = 0;
  int fallbacks = 0;
  int placeholders = 0;
  String engine = '-';

  void reset() {
    ttftMs = -1;
    firstCutMs = -1;
    ttfaMs = -1;
    lastSynthFirstMs = -1;
    lastSynthTotalMs = -1;
    segments = 0;
    fallbacks = 0;
    placeholders = 0;
  }
}

abstract class TtsProvider {
  String get label;

  /// 采样率（仅 PCM 直出路径有意义）。
  int get sampleRate;

  /// true = 我们自己拿 PCM 直出（低延迟路径）；false = 交给系统 TTS 引擎。
  bool get isPcm;

  Stream<Uint8List> synthesize(String text, ChatConfig cfg);

  Future<void> warmup(ChatConfig cfg) async {}
}

class _NeedsFallback implements Exception {
  _NeedsFallback(this.message);
  final String message;
  @override
  String toString() => message;
}

/// OpenAI 兼容的 /v1/audio/speech。优先走 SSE 增量，拿不到就退回整段 PCM 流。
class OpenAiTtsProvider extends TtsProvider {
  OpenAiTtsProvider();

  HttpClient? _http;
  String _origin = '';

  @override
  String get label => '云端 TTS';
  @override
  int get sampleRate => 24000;
  @override
  bool get isPcm => true;

  HttpClient _clientFor(String url) {
    final uri = Uri.parse(url);
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    if (_http == null || origin != _origin) {
      _http?.close(force: true);
      _http = HttpClient()
        ..idleTimeout = const Duration(minutes: 10)
        ..maxConnectionsPerHost = 6
        ..connectionTimeout = const Duration(seconds: 10);
      _origin = origin;
    }
    return _http!;
  }

  @override
  Future<void> warmup(ChatConfig cfg) async {
    try {
      final c = _clientFor(cfg.speechEndpoint);
      final req = await c.openUrl('GET', Uri.parse(cfg.speechEndpoint));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
      final resp = await req.close().timeout(const Duration(seconds: 5));
      await resp.drain<void>().catchError((_) => null);
    } catch (_) {}
  }

  @override
  Stream<Uint8List> synthesize(String text, ChatConfig cfg) async* {
    if (text.trim().isEmpty) return;
    try {
      yield* _request(text, cfg, sse: true);
    } on _NeedsFallback {
      // 网关不认 stream_format：退回"整段 PCM + 分块传输"，仍能首字节即播。
      yield* _request(text, cfg, sse: false);
    }
  }

  Stream<Uint8List> _request(String text, ChatConfig cfg, {required bool sse}) async* {
    final client = _clientFor(cfg.speechEndpoint);
    final req = await client.postUrl(Uri.parse(cfg.speechEndpoint));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    if (cfg.apiKey.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
    }
    final body = <String, Object?>{
      'model': cfg.ttsModel,
      'input': text,
      'voice': cfg.ttsVoice,
      'response_format': 'pcm',
      'speed': cfg.ttsSpeed,
    };
    if (sse) body['stream_format'] = 'sse';
    req.add(utf8.encode(jsonEncode(body)));

    final resp = await req.close();
    if (resp.statusCode != 200) {
      final detail = await resp.transform(utf8.decoder).join();
      final brief = detail.length > 160 ? detail.substring(0, 160) : detail;
      if (sse && resp.statusCode >= 400 && resp.statusCode < 500) {
        throw _NeedsFallback('speech HTTP ${resp.statusCode}: $brief');
      }
      throw HttpException('speech HTTP ${resp.statusCode}: $brief');
    }

    final mime = resp.headers.contentType?.mimeType ?? '';
    if (!mime.contains('event-stream')) {
      // 有些网关忽略 stream_format，直接回整段音频 —— 那就当裸 PCM 用。
      yield* _rawPcm(resp);
      return;
    }
    yield* _ssePcm(resp);
  }

  Stream<Uint8List> _rawPcm(Stream<List<int>> resp) async* {
    final acc = <int>[];
    await for (final chunk in resp) {
      acc.addAll(chunk);
      final even = acc.length - (acc.length % 2);
      if (even > 0) {
        yield Uint8List.fromList(acc.sublist(0, even));
        acc.removeRange(0, even);
      }
    }
    if (acc.isNotEmpty) yield Uint8List.fromList(acc);
  }

  Stream<Uint8List> _ssePcm(Stream<List<int>> resp) async* {
    final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty || line.startsWith('event:')) continue;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final obj = jsonDecode(payload) as Map<String, dynamic>;
        final b64 = obj['audio'] ?? obj['delta'];
        if (b64 is String && b64.isNotEmpty) {
          yield base64.decode(b64);
        }
      } catch (_) {
        continue;
      }
    }
  }

  void dispose() {
    _http?.close(force: true);
    _http = null;
  }
}

/// 系统 TTS：开箱可用，不需要任何配置，同时是云端 TTS 的兜底。
class SystemTtsProvider extends TtsProvider {
  SystemTtsProvider(this.bridge);
  final NativeBridge bridge;

  @override
  String get label => '系统 TTS';
  @override
  int get sampleRate => 0;
  @override
  bool get isPcm => false;

  @override
  Stream<Uint8List> synthesize(String text, ChatConfig cfg) => const Stream.empty();
}

class _Seg {
  _Seg(this.text, this.index);
  final String text;
  final int index;
  final List<Uint8List> buf = [];
  final Stopwatch sw = Stopwatch();
  StreamSubscription<Uint8List>? sub;
  Timer? blipTimer;
  Timer? guardTimer;
  bool dispatched = false;
  bool done = false;
  bool systemMode = false;
  bool systemSpoken = false;
  int firstByteMs = -1;
  int totalMs = -1;

  void disposeTimers() {
    blipTimer?.cancel();
    guardTimer?.cancel();
    blipTimer = null;
    guardTimer = null;
  }
}

/// 语音播报流水线：分句 → 合成 → PCM 直出 → 播完回收。
///
/// 低延迟的几条措施：
///  1. 常驻 HttpClient / AudioTrack，连接与音频轨都不重建
///  2. 首句软门槛切分，不让 TTS 等整段回复
///  3. 流水线预取：正在播第 N 句时，第 N+1、N+2 句已经在合成
///  4. 分级兜底：800ms 没声音给占位音，1.2s 没声音切系统 TTS
class SpeechPipeline {
  SpeechPipeline(this.bridge);

  final NativeBridge bridge;
  final SpeechMetrics metrics = SpeechMetrics();

  PetEngine? engine;
  void Function(PetState state)? onState;

  TtsProvider provider = SystemTtsProvider(NativeBridge.instance);
  ChatConfig cfg = const ChatConfig(baseUrl: '', apiKey: '', model: '');

  final List<_Seg> _segs = [];
  int _cursor = 0;
  Timer? _tick;
  bool _running = false;
  bool _utteranceOpen = false;
  bool _systemBusy = false;
  int _systemOutstanding = 0;
  int _pendingMs = 0;
  int _replyStartedAtMs = -1;
  bool _firstAudioReported = false;

  static const int _lookaheadMs = 350;
  static const int _blipAfterMs = 800;
  static const int _fallbackAfterMs = 1200;

  /// 实际输出采样率（须与原生 AudioTrack 一致）。
  int pcmSampleRate = 24000;

  /// 每秒字节数，用于把 PCM 长度换算成毫秒。
  double get _bytesPerMs => pcmSampleRate * 2 / 1000.0;

  void attach() {
    bridge.onAudioDrained = _onDrained;
    bridge.onTtsDone = _onTtsDone;
    bridge.onAudioStarted = onAudioStarted;
  }

  void configure(ChatConfig c, TtsProvider p) {
    cfg = c;
    provider = p;
    pcmSampleRate = p.isPcm ? c.ttsSampleRate : 0;
    metrics.engine = p.label;
    if (p is OpenAiTtsProvider) {
      // 预热连接：把 TCP/TLS 握手挪到用户还在打字的时候。
      unawaited(p.warmup(c));
    }
  }

  bool get busy => _utteranceOpen || _segs.isNotEmpty || _systemOutstanding > 0;

  /// 新一轮回复开始：清空上一轮。
  void beginReply() {
    _systemOutstanding = 0;
    _clear();
    metrics.reset();
    metrics.engine = provider.label;
    _replyStartedAtMs = -1;
    _firstAudioReported = false;
  }

  /// 打断当前播报（用户重新提问 / 关掉播报）。
  Future<void> stop() async {
    _clear();
    _systemOutstanding = 0;
    engine?.setPlaying(false);
    onState?.call(PetState.idle);
    await bridge.audioStop();
    await bridge.systemTtsStop();
  }

  void _clear() {
    for (final s in _segs) {
      unawaited(s.sub?.cancel());
      s.sub = null;
      s.disposeTimers();
    }
    _segs.clear();
    _cursor = 0;
    _utteranceOpen = false;
    _systemBusy = false;
    _pendingMs = 0;
    _stopTick();
  }

  /// 送入一句待播报文本（按顺序调用）。
  void enqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    if (_replyStartedAtMs < 0) {
      _replyStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    metrics.segments++;
    _utteranceOpen = true;

    if (!provider.isPcm) {
      _systemOutstanding++;
      _systemBusy = true;
      engine?.setPlaying(true);
      onState?.call(PetState.speaking);
      unawaited(bridge.systemTtsSpeak(t));
      return;
    }

    final seg = _Seg(t, _segs.length);
    _segs.add(seg);
    engine?.setPlaying(true);
    onState?.call(PetState.speaking);
    _ensureTick();
    _dispatch();
  }

  /// 本轮回复的文本已经全部送出。
  void finish() {
    _utteranceOpen = false;
    if (!provider.isPcm) {
      if (_systemOutstanding == 0 && _segs.isEmpty) {
        engine?.setPlaying(false);
        onState?.call(PetState.idle);
      }
      return;
    }
    _dispatch();
    if (_segs.isEmpty || _cursor >= _segs.length) {
      // 没有任何待播内容
      if (_segs.isEmpty) {
        engine?.setPlaying(false);
        onState?.call(PetState.idle);
        _stopTick();
      }
    }
    _pump();
  }

  // ------------------------------------------------------------------ 调度

  void _ensureTick() {
    if (_running) return;
    _running = true;
    _tick = Timer.periodic(const Duration(milliseconds: 24), (_) => _pump());
  }

  void _stopTick() {
    _running = false;
    _tick?.cancel();
    _tick = null;
  }

  /// 预取：正在写第 cursor 句时，最多提前合成到 cursor+2。
  void _dispatch() {
    final limit = math.min(_segs.length, _cursor + 3);
    for (var i = 0; i < limit; i++) {
      final seg = _segs[i];
      if (seg.dispatched) continue;
      seg.dispatched = true;
      _start(seg);
    }
  }

  void _start(_Seg seg) {
    seg.sw.start();
    seg.blipTimer = Timer(Duration(milliseconds: _blipAfterMs), () {
      if (seg.firstByteMs < 0 && !seg.done && cfg.placeholderSound) {
        metrics.placeholders++;
        unawaited(bridge.playBlip());
      }
    });
    seg.guardTimer = Timer(Duration(milliseconds: _fallbackAfterMs), () {
      if (seg.firstByteMs < 0 && !seg.done) {
        unawaited(seg.sub?.cancel());
        seg.sub = null;
        seg.done = true;
        seg.buf.clear();
        seg.systemMode = cfg.useSystemTts;
        if (cfg.useSystemTts) metrics.fallbacks++;
      }
    });

    seg.sub = provider.synthesize(seg.text, cfg).listen(
      (chunk) {
        if (seg.firstByteMs < 0) {
          seg.firstByteMs = seg.sw.elapsedMilliseconds;
        }
        seg.buf.add(chunk);
        if (_running && _cursor == seg.index) _pump();
      },
      onError: (_) {
        seg.done = true;
        seg.buf.clear();
        seg.disposeTimers();
        seg.systemMode = cfg.useSystemTts;
        if (cfg.useSystemTts) metrics.fallbacks++;
        if (_running) _pump();
      },
      onDone: () {
        seg.totalMs = seg.sw.elapsedMilliseconds;
        seg.done = true;
        seg.disposeTimers();
        if (_running) _pump();
      },
      cancelOnError: true,
    );
  }

  void _pump() {
    if (!_running) return;
    _refreshPending();

    if (_cursor >= _segs.length) {
      if (!_utteranceOpen) _stopTick();
      return;
    }

    _dispatch();
    final seg = _segs[_cursor];

    // 该句退回系统 TTS：等主轨播空再交给系统引擎，避免两条音轨重叠。
    if (seg.systemMode) {
      if (_pendingMs > 90) return;
      if (!seg.systemSpoken) {
        seg.systemSpoken = true;
        _systemBusy = true;
        _systemOutstanding++;
        engine?.setPlaying(true);
        unawaited(bridge.systemTtsSpeak(seg.text));
      }
      if (!_systemBusy) _advance();
      return;
    }

    while (seg.buf.isNotEmpty && _pendingMs < _lookaheadMs) {
      final chunk = seg.buf.removeAt(0);
      _pendingMs += (chunk.length / _bytesPerMs).round();
      unawaited(bridge.audioWrite(chunk));
      _feedEnergy(chunk);
    }

    if (seg.buf.isEmpty && seg.done) {
      metrics.lastSynthFirstMs = seg.firstByteMs;
      metrics.lastSynthTotalMs = seg.totalMs;
      unawaited(bridge.audioMark());
      _advance();
    }
  }

  void _advance() {
    _disposeSeg(_segs[_cursor]);
    _cursor++;
    if (_cursor >= _segs.length && !_utteranceOpen) {
      _stopTick();
      return;
    }
    _dispatch();
  }

  void _disposeSeg(_Seg seg) {
    seg.disposeTimers();
    seg.sub = null;
  }

  void _refreshPending() {
    unawaited(
      bridge.audioPendingMs().then((v) {
        if (_running) _pendingMs = v;
      }),
    );
  }

  void _feedEnergy(Uint8List pcm) {
    final e = engine;
    if (e == null) return;
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      var s = pcm[i] | (pcm[i + 1] << 8);
      if (s >= 32768) s -= 65536;
      sum += s * s;
      n++;
    }
    if (n == 0) return;
    final rms = math.sqrt(sum / n) / 32768.0;
    e.pushEnergy((rms * 3.4).clamp(0.0, 1.0));
  }

  // ---------------------------------------------------------------- 原生回调

  void _onDrained() {
    if (_segs.isNotEmpty && _cursor < _segs.length) return;
    engine?.setPlaying(false);
    if (!_utteranceOpen && _systemOutstanding <= 0) {
      onState?.call(PetState.idle);
    }
  }

  void _onTtsDone() {
    _systemBusy = false;
    if (_systemOutstanding > 0) _systemOutstanding--;
    if (!provider.isPcm) {
      if (_systemOutstanding <= 0 && !_utteranceOpen) {
        engine?.setPlaying(false);
        onState?.call(PetState.idle);
      }
      return;
    }
    _ensureTick();
    _pump();
  }

  /// 原生 audioStarted → 首音真正出声，这时才记 ttfa。
  void onAudioStarted() {
    if (_replyStartedAtMs < 0 || _firstAudioReported) return;
    _firstAudioReported = true;
    metrics.ttfaMs = DateTime.now().millisecondsSinceEpoch - _replyStartedAtMs;
  }
}