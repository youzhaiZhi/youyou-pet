import 'package:flutter/material.dart';

import '../app/controller.dart';
import 'home_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final PetController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _prompt;
  late final TextEditingController _ttsBase;
  late final TextEditingController _ttsKey;
  late final TextEditingController _ttsModel;
  late final TextEditingController _ttsVoice;
  late double _temp;
  late String _ttsMode;
  late int _rate;
  late double _speed;
  late bool _fallback;
  late bool _blip;
  late bool _autoSpeak;
  late bool _metrics;
  bool _reveal = false;
  bool _revealTts = false;

  PetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final s = c.settings;
    _baseUrl = TextEditingController(text: s.baseUrl);
    _key = TextEditingController(text: c.apiKey);
    _model = TextEditingController(text: s.model);
    _prompt = TextEditingController(text: s.systemPrompt);
    _ttsBase = TextEditingController(text: s.ttsBaseUrl);
    _ttsKey = TextEditingController(text: c.ttsApiKey);
    _ttsModel = TextEditingController(text: s.ttsModel);
    _ttsVoice = TextEditingController(text: s.ttsVoice);
    _temp = s.temperature;
    _ttsMode = s.ttsMode;
    _rate = s.ttsSampleRate;
    _speed = s.ttsSpeed;
    _fallback = s.fallbackToSystem;
    _blip = s.placeholderSound;
    _autoSpeak = s.autoSpeak;
    _metrics = s.showMetrics;
  }

  @override
  void dispose() {
    for (final t in [_baseUrl, _key, _model, _prompt, _ttsBase, _ttsKey, _ttsModel, _ttsVoice]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final s = c.settings;
    s.baseUrl = _baseUrl.text.trim();
    s.model = _model.text.trim();
    s.systemPrompt = _prompt.text;
    s.ttsBaseUrl = _ttsBase.text.trim();
    s.ttsModel = _ttsModel.text.trim();
    s.ttsVoice = _ttsVoice.text.trim();
    s.temperature = _temp;
    s.ttsMode = _ttsMode;
    s.ttsSampleRate = _rate;
    s.ttsSpeed = _speed;
    s.fallbackToSystem = _fallback;
    s.placeholderSound = _blip;
    s.autoSpeak = _autoSpeak;
    s.showMetrics = _metrics;
    c.apiKey = _key.text.trim();
    c.ttsApiKey = _ttsKey.text.trim();
    await c.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已保存'),
          duration: Duration(milliseconds: 900),
          backgroundColor: kField,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        centerTitle: false,
        titleSpacing: 4,
        iconTheme: const IconThemeData(color: kGray),
        title: const Text(
          '设置',
          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 40),
        children: [
          _section('对话 API'),
          _field('接口地址', _baseUrl, hint: 'https://api.openai.com/v1'),
          _field(
            'API Key',
            _key,
            hint: 'sk-...',
            obscure: !_reveal,
            trailing: IconButton(
              splashRadius: 18,
              icon: Icon(
                _reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18,
                color: kDim,
              ),
              onPressed: () => setState(() => _reveal = !_reveal),
            ),
          ),
          _field('模型', _model, hint: 'gpt-4o-mini'),
          _slider('温度 ${_temp.toStringAsFixed(2)}', _temp, 0, 1.5, (v) {
            setState(() => _temp = v);
          }),
          const SizedBox(height: 6),
          _field('人格提示词', _prompt, maxLines: 6),

          const SizedBox(height: 14),
          _section('语音播报'),
          _segment('引擎', ['system', 'cloud'], ['系统 TTS', '云端 TTS'], _ttsMode, (v) {
            setState(() => _ttsMode = v);
          }),
          if (_ttsMode == 'cloud') ...[
            _field('TTS 地址（留空则同对话地址）', _ttsBase, hint: 'https://api.openai.com/v1'),
            _field(
              'TTS API Key（留空则复用对话 Key）',
              _ttsKey,
              hint: 'sk-...',
              obscure: !_revealTts,
              trailing: IconButton(
                splashRadius: 18,
                icon: Icon(
                  _revealTts ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18,
                  color: kDim,
                ),
                onPressed: () => setState(() => _revealTts = !_revealTts),
              ),
            ),
            _field('TTS 模型', _ttsModel, hint: 'tts-1'),
            _field('音色', _ttsVoice, hint: 'alloy'),
            _segment(
              '采样率',
              ['16000', '22050', '24000'],
              ['16k', '22.05k', '24k'],
              '$_rate',
              (v) => setState(() => _rate = int.parse(v)),
            ),
            _slider('语速 ${_speed.toStringAsFixed(2)}', _speed, 0.5, 2.0, (v) {
              setState(() => _speed = v);
            }),
            _switch('超时自动退回系统 TTS', _fallback, (v) => setState(() => _fallback = v)),
            _note('云端 TTS 走 SSE 增量直出 PCM，首音通常 300ms 内；'
                '超过 1.2s 拿不到声音会自动改用系统 TTS，保证不会没反应。'),
          ],
          _switch('首音等待时给一个提示音（800ms）', _blip, (v) => setState(() => _blip = v)),
          _switch('收到回复自动朗读', _autoSpeak, (v) => setState(() => _autoSpeak = v)),
          _switch('显示延迟埋点', _metrics, (v) => setState(() => _metrics = v)),
          _note('埋点含义：ttft = 模型首 token；首句切分 = 从首个 token 到第一句送进 TTS；'
              'ttfa = 从文本送出到真正出声；单句首字节 = 单次合成的首包延迟。'),

          const SizedBox(height: 22),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              onPressed: _save,
              child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 组件

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
        child: Text(
          title,
          style: const TextStyle(
            color: kDim,
            fontSize: 12,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        child: Text(
          text,
          style: const TextStyle(color: kDim, fontSize: 11.5, height: 1.55),
        ),
      );

  Widget _field(
    String label,
    TextEditingController ctl, {
    String? hint,
    int maxLines = 1,
    bool obscure = false,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(label, style: const TextStyle(color: kGray, fontSize: 12.5)),
          ),
          Container(
            decoration: BoxDecoration(
              color: kField,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ctl,
                    obscureText: obscure,
                    maxLines: maxLines,
                    minLines: maxLines > 1 ? maxLines : 1,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    cursorColor: Colors.white70,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 15),
                      border: InputBorder.none,
                      hintText: hint,
                      hintStyle: const TextStyle(color: kDim, fontSize: 14),
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Text(label, style: const TextStyle(color: kGray, fontSize: 12.5)),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: const Color(0xFF2C2C2E),
              thumbColor: Colors.white,
              overlayColor: Colors.white10,
              trackHeight: 2,
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ],
      ),
    );
  }

  Widget _segment(
    String label,
    List<String> values,
    List<String> labels,
    String current,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(label, style: const TextStyle(color: kGray, fontSize: 12.5)),
          ),
          Container(
            decoration: BoxDecoration(
              color: kField,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(3),
            child: Row(
              children: [
                for (var i = 0; i < values.length; i++)
                  Expanded(
                    child: GestureDetector(
                      onTap: () => onChanged(values[i]),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: current == values[i] ? Colors.white : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            color: current == values[i] ? Colors.black : kGray,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: kGray, fontSize: 13.5)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.black,
            activeTrackColor: Colors.white,
            inactiveThumbColor: const Color(0xFF8E8E93),
            inactiveTrackColor: const Color(0xFF2C2C2E),
          ),
        ],
      ),
    );
  }
}