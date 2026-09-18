import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 低延迟分句器。
///
/// 目标不是"分得漂亮"，而是**尽快把第一句交给 TTS**。
/// 策略：硬标点立刻切；软标点（逗号等）只要够长也切；
/// 再兜底一个字符数上限，防止模型一直不吐标点导致首音无限推迟。
class SentenceSplitter {
  static const String _hard = '。！？!?…；;\n\r';
  static const String _soft = '，,、：:）)】」』"';

  final StringBuffer _buf = StringBuffer();
  int _emitted = 0;

  int get emittedCount => _emitted;
  String get pending => _buf.toString();

  /// 首次切分耗时（用于埋点）。
  int firstCutMs = -1;
  int _tokenAtMs = -1;

  /// 喂入增量文本，返回本次可以立刻送去合成的句子。
  List<String> push(String delta, {int nowMs = 0}) {
    if (_emitted == 0 && _tokenAtMs < 0) _tokenAtMs = nowMs;
    _buf.write(delta);
    final out = <String>[];
    String? s;
    while ((s = _take(nowMs)) != null) {
      out.add(s!);
    }
    return out;
  }

  String? _take(int nowMs) {
    final s = _buf.toString();
    if (s.trim().isEmpty) return null;
    final first = _emitted == 0;
    final softMin = first ? 5 : 9;
    final forceAt = first ? 12 : 22;

    int cut = -1;
    var score = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (_hard.contains(ch)) {
        cut = i;
        score = 3;
        break;
      }
      if (_soft.contains(ch) && i + 1 >= softMin && score < 2) {
        cut = i;
        score = 2;
      }
    }

    if (cut < 0 && s.length >= forceAt) {
      // 超过上限仍无标点：找一个相对自然的断点，绝不切在代理对中间。
      cut = _naturalBreak(s, forceAt);
      if (cut < 0) {
        if (s.length < forceAt + 6) return null;
        cut = forceAt - 1;
      }
    }
    if (cut < 0) return null;

    final head = s.substring(0, cut + 1);
    final rest = s.substring(cut + 1);
    _buf
      ..clear()
      ..write(rest);
    final cleaned = sanitizeForSpeech(head);
    if (cleaned.isEmpty) return _take(nowMs);
    _emitted++;
    if (_emitted == 1 && firstCutMs < 0 && _tokenAtMs >= 0) {
      firstCutMs = nowMs - _tokenAtMs;
    }
    return cleaned;
  }

  int _naturalBreak(String s, int from) {
    for (var i = from - 1; i > 2 && i > from - 10; i--) {
      final c = s[i];
      if (c == ' ' || c == '\u3000' || c == '/' || c == '|') return i;
    }
    return -1;
  }

  /// 收尾：把剩余内容整体吐出去。
  String? flush() {
    final s = _buf.toString();
    _buf.clear();
    if (s.trim().isEmpty) return null;
    final cleaned = sanitizeForSpeech(s);
    if (cleaned.isEmpty) return null;
    _emitted++;
    return cleaned;
  }

  void reset() {
    _buf.clear();
    _emitted = 0;
    firstCutMs = -1;
    _tokenAtMs = -1;
  }
}

/// 去掉不适合朗读的 Markdown / 符号，避免 TTS 念出 "星号 星号"。
String sanitizeForSpeech(String input) {
  var s = input;
  s = s.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
  s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  s = s.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
  s = s.replaceAll(RegExp(r'[*_#>~]'), '');
  s = s.replaceAll(RegExp(r'^\s*[-+]\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '');
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
  s = s.replaceAll(RegExp(r'\n+'), '，');
  return s.trim();
}

/// OpenAI 兼容接口配置。
class ChatConfig {
  const ChatConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.8,
    this.systemPrompt = defaultSystemPrompt,
    this.ttsBaseUrl = '',
    this.ttsApiKey = '',
    this.ttsModel = 'tts-1',
    this.ttsVoice = 'alloy',
    this.ttsSampleRate = 24000,
    this.ttsSpeed = 1.0,
    this.useSystemTts = true,
    this.placeholderSound = true,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final String systemPrompt;

  final String ttsBaseUrl;
  final String ttsApiKey;
  final String ttsModel;
  final String ttsVoice;
  final int ttsSampleRate;
  final double ttsSpeed;
  final bool useSystemTts;
  final bool placeholderSound;

  String get chatEndpoint => joinUrl(baseUrl, '/chat/completions');
  String get speechEndpoint => joinUrl(ttsBaseUrl.isEmpty ? baseUrl : ttsBaseUrl, '/audio/speech');

  /// 云端 TTS 用哪把 Key：填了就分家，留空则复用对话 Key。
  String get speechApiKey => ttsApiKey.isEmpty ? apiKey : ttsApiKey;

  ChatConfig copyWith(Map<String, Object?> patch) => ChatConfig(
        baseUrl: (patch['baseUrl'] as String?) ?? baseUrl,
        apiKey: (patch['apiKey'] as String?) ?? apiKey,
        model: (patch['model'] as String?) ?? model,
        temperature: (patch['temperature'] as double?) ?? temperature,
        systemPrompt: (patch['systemPrompt'] as String?) ?? systemPrompt,
        ttsBaseUrl: (patch['ttsBaseUrl'] as String?) ?? ttsBaseUrl,
        ttsApiKey: (patch['ttsApiKey'] as String?) ?? ttsApiKey,
        ttsModel: (patch['ttsModel'] as String?) ?? ttsModel,
        ttsVoice: (patch['ttsVoice'] as String?) ?? ttsVoice,
        ttsSampleRate: (patch['ttsSampleRate'] as int?) ?? ttsSampleRate,
        ttsSpeed: (patch['ttsSpeed'] as double?) ?? ttsSpeed,
        useSystemTts: (patch['useSystemTts'] as bool?) ?? useSystemTts,
        placeholderSound: (patch['placeholderSound'] as bool?) ?? placeholderSound,
      );
}

const String defaultSystemPrompt =
    '你是一只住在手机里的桌面小生物，名字叫"悠悠"。你只有一双会发光的眼睛，'
    '没有嘴巴，也不会做表情，所有情绪都靠眼神表达。\n'
    '说话风格：口语、简短、温暖、有点俏皮。每次回复控制在 1~3 句，不要用 Markdown、'
    '不要用列表、不要用括号补充说明——因为你的话会被直接朗读出来，任何符号都会变成噪音。';

/// 把 base 与 path 拼成合法 URL（自动补 /v1 之外的重复斜杠）。
String joinUrl(String base, String path) {
  var b = base.trim();
  if (b.isEmpty) return b;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (!b.startsWith('http://') && !b.startsWith('https://')) {
    b = 'https://$b';
  }
  return '$b$path';
}

/// 流式对话客户端。复用同一个 HttpClient ⇒ 复用 TCP 连接 ⇒ 省掉每轮的握手开销。
class ChatClient {
  HttpClient? _client;
  String _origin = '';

  HttpClient _clientFor(String url) {
    final uri = Uri.parse(url);
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    if (_client == null || origin != _origin) {
      _client?.close(force: true);
      final c = HttpClient()
        ..idleTimeout = const Duration(minutes: 10)
        ..maxConnectionsPerHost = 6
        ..connectionTimeout = const Duration(seconds: 12)
        ..autoUncompress = false;
      _client = c;
      _origin = origin;
    }
    return _client!;
  }

  /// 预热：提前把 TCP/TLS 连接建好，正式请求就只剩往返时间。
  Future<void> warmup(String url, String apiKey) async {
    if (url.isEmpty) return;
    try {
      final c = _clientFor(url);
      final req = await c.openUrl('GET', Uri.parse(url));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      await resp.drain<void>().catchError((_) {});
    } catch (_) {
      // 预热失败无所谓，正常请求仍然会走一遍。
    }
  }

  /// 发起流式请求，逐段吐出模型增量文本。
  Stream<String> stream(
    List<Map<String, String>> messages,
    ChatConfig cfg, {
    void Function(int ttftMs)? onFirstToken,
  }) async* {
    final client = _clientFor(cfg.chatEndpoint);
    final req = await client.postUrl(Uri.parse(cfg.chatEndpoint));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    req.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    if (cfg.apiKey.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
    }
    req.add(utf8.encode(jsonEncode({
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': true,
    })));

    final resp = await req.close();
    if (resp.statusCode != 200) {
      final body = await resp.transform(utf8.decoder).join();
      throw HttpException('HTTP ${resp.statusCode}: ${_brief(body)}');
    }

    final started = DateTime.now();
    var gotFirst = false;
    final lines = resp
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty || line.startsWith(':')) continue;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;
      Map<String, dynamic> obj;
      try {
        obj = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final choices = obj['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = (choices[0] as Map)['delta'];
      if (delta is! Map) continue;
      final piece = delta['content'];
      if (piece is! String || piece.isEmpty) continue;
      if (!gotFirst) {
        gotFirst = true;
        onFirstToken?.call(DateTime.now().difference(started).inMilliseconds);
      }
      yield piece;
    }
  }

  /// 非流式兜底（少数网关不支持 stream）。
  Future<String> complete(List<Map<String, String>> messages, ChatConfig cfg) async {
    final client = _clientFor(cfg.chatEndpoint);
    final req = await client.postUrl(Uri.parse(cfg.chatEndpoint));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    if (cfg.apiKey.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
    }
    req.add(utf8.encode(jsonEncode({
      'model': cfg.model,
      'messages': messages,
      'temperature': cfg.temperature,
      'stream': false,
    })));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}: ${_brief(body)}');
    }
    final obj = jsonDecode(body) as Map<String, dynamic>;
    final choices = obj['choices'] as List;
    final msg = (choices.first as Map)['message'] as Map;
    return (msg['content'] as String?) ?? '';
  }

  void close() {
    _client?.close(force: true);
    _client = null;
    _origin = '';
  }

  static String _brief(String body) =>
      body.length > 180 ? '${body.substring(0, 180)}…' : body;
}