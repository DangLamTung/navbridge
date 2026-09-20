/// "Trợ lý AI" settings page — encrypted DeepSeek / Gemini API keys used by
/// the always-on voice assistant.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:navbridge/core/ai_config.dart';
import 'package:navbridge/core/ai_key_store.dart';
import 'package:navbridge/core/settings.dart'
    show
        aiCustomPrompt,
        aiPlaceSuggestions,
        aiProvider,
        aiDeepSeekBaseUrl,
        aiDeepSeekModel,
        aiWebSearch;
import 'package:navbridge/pages/settings/settings_save.dart';
import 'package:navbridge/pages/settings/settings_widgets.dart';
import 'package:navbridge/ui/widgets.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  bool _aiKeysLoaded = false;
  bool _aiHasKey = false;
  final _deepSeekCtrl = TextEditingController();
  final _geminiCtrl = TextEditingController();
  String _aiSaveStatus = '';
  String _aiCustomPrompt = '';
  bool _aiPlaceSuggestions = true;
  final _promptCtrl = TextEditingController();
  String _aiProvider = 'auto';
  String _aiBaseUrl = '';
  String _aiModel = '';
  bool _aiWebSearch = true;
  final _baseUrlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _aiCustomPrompt = aiCustomPrompt;
    _aiPlaceSuggestions = aiPlaceSuggestions;
    _aiProvider = aiProvider;
    _aiBaseUrl = aiDeepSeekBaseUrl;
    _aiModel = aiDeepSeekModel;
    _aiWebSearch = aiWebSearch;
    _promptCtrl.text = aiCustomPrompt;
    _baseUrlCtrl.text = aiDeepSeekBaseUrl.isEmpty
        ? AiConfig.deepSeekEndpoint
        : aiDeepSeekBaseUrl;
    _modelCtrl.text = aiDeepSeekModel.isEmpty
        ? AiConfig.deepSeekModel
        : aiDeepSeekModel;
    _loadAiKeys();
  }

  @override
  void dispose() {
    _deepSeekCtrl.dispose();
    _geminiCtrl.dispose();
    _promptCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAiKeys() async {
    final (d, g) = await AiKeyStore.instance.read();
    if (!mounted) return;
    setState(() {
      _deepSeekCtrl.text = d ?? '';
      _geminiCtrl.text = g ?? '';
      _aiKeysLoaded = true;
      _aiHasKey = (d?.isNotEmpty ?? false) || (g?.isNotEmpty ?? false);
    });
  }

  /// Save the AI keys ENCRYPTED (secure storage), or clear them when blank.
  Future<void> _saveAiKeys() async {
    final d = _deepSeekCtrl.text.trim();
    final g = _geminiCtrl.text.trim();
    await AiKeyStore.instance.saveDeepSeek(d);
    await AiKeyStore.instance.saveGemini(g);
    if (!mounted) return;
    setState(() {
      _aiHasKey = d.isNotEmpty || g.isNotEmpty;
      _aiSaveStatus = 'Đã lưu khoá (mã hoá trên máy).';
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _aiSaveStatus = '');
    });
  }

  /// Show an "add / edit AI key" mini-form.
  Future<void> _editAiKey(String provider, TextEditingController ctrl) async {
    final newVal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Khoá $provider'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Dán khoá API ở đây'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () {
              ctrl.text = ctrl.text.trim();
              Navigator.of(ctx).pop(ctrl.text);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (newVal != null && mounted) {
      await _saveAiKeys();
    }
  }

  /// Edit the custom system-prompt instructions appended to the base prompt.
  Future<void> _editCustomPrompt() async {
    final newVal = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lời nhắc tuỳ chỉnh'),
        content: TextField(
          controller: _promptCtrl,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Ví dụ: trả lời ngắn gọn, xưng "tôi"; luôn nhắc tài xế '
                'giữ khoảng cách; gợi ý quán cà phê địa phương…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () {
              _promptCtrl.text = _promptCtrl.text.trim();
              Navigator.of(ctx).pop(_promptCtrl.text);
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (newVal == null || !mounted) return;
    setState(() {
      _aiCustomPrompt = newVal;
      _promptCtrl.text = newVal;
      aiCustomPrompt = newVal;
    });
    await saveAllSettings();
  }

  /// Toggle location-aware suggested questions in the AI chat panel.
  Future<void> _togglePlaceSuggestions(bool v) async {
    setState(() {
      _aiPlaceSuggestions = v;
      aiPlaceSuggestions = v;
    });
    await saveAllSettings();
  }

  /// Pick the AI provider preference ('auto' | 'deepseek' | 'gemini').
  void _setAiProvider(String v) {
    if (aiProvider == v) return;
    setState(() {
      _aiProvider = v;
      aiProvider = v;
    });
    unawaited(saveAllSettings());
  }

  /// Toggle real-time web-search grounding.
  Future<void> _toggleWebSearch(bool v) async {
    setState(() {
      _aiWebSearch = v;
      aiWebSearch = v;
    });
    await saveAllSettings();
  }

  /// Edit the custom DeepSeek base URL + model (self-hosted / proxy endpoint).
  Future<void> _editEndpoint() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Endpoint tùy chỉnh'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _baseUrlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.deepseek.com',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'deepseek-chat',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Để trống Base URL để dùng mặc định. URL phải là OpenAI-compatible '
              '(thêm /chat/completions tự động).',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    var base = _baseUrlCtrl.text.trim();
    // Strip the trailing /chat/completions so we store a clean base URL, and
    // trim a trailing slash to build the endpoint consistently.
    base = base.replaceAll(RegExp(r'[/]*chat/completions$'), '').replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final model = _modelCtrl.text.trim();

    // If the user left the base URL at the default endpoint, store empty (=
    // use the built-in default) so a future default change still applies.
    if (base == '' ||
        base == 'https://api.deepseek.com' ||
        base == 'https://api.deepseek.com/chat/completions') {
      base = '';
    }
    setState(() {
      _aiBaseUrl = base;
      _aiModel = model;
      aiDeepSeekBaseUrl = base;
      aiDeepSeekModel = model;
    });
    await saveAllSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Trợ lý AI',
      children: [
        SettingsCard(
          color: const Color(0xFFF3E8FD),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome, size: 18, color: Color(0xFF7B1FA2)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Hỏi AI về lộ trình, xăng, ETA, camera… '
                      '(DeepSeek hoặc Gemini)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _aiHasKey
                    ? 'Đã lưu khoá AI (mã hoá trên máy).'
                    : (AiConfig.deepSeekApiKey.isNotEmpty ||
                          AiConfig.geminiApiKey.isNotEmpty)
                    ? 'Có khoá AI từ bản build (--dart-define).'
                    : 'Chưa có khoá AI — thêm khoá DeepSeek / Gemini để dùng '
                          'trợ lý. Khoá được mã hoá trong bộ nhớ an toàn của máy.',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _aiKeysLoaded
                          ? () => _editAiKey('DeepSeek', _deepSeekCtrl)
                          : null,
                      icon: const Icon(Icons.key, size: 18),
                      label: Text(
                        _deepSeekCtrl.text.isNotEmpty
                            ? 'DeepSeek ✓'
                            : 'Khoá DeepSeek',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _aiKeysLoaded
                          ? () => _editAiKey('Gemini', _geminiCtrl)
                          : null,
                      icon: const Icon(Icons.key, size: 18),
                      label: Text(
                        _geminiCtrl.text.isNotEmpty
                            ? 'Gemini ✓'
                            : 'Khoá Gemini',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
              if (_aiSaveStatus.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _aiSaveStatus,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF188038),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                'Khoá được mã hoá bằng bộ nhớ an toàn của hệ điều hành '
                '(Android Keystore / iOS Keychain), không nằm trong file APK. '
                'Trợ lý gọi trực tiếp tới DeepSeek / Gemini.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const SettingsSection('Lời nhắc & Gợi ý'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_note, color: kAppBlue, size: 22),
                title: const Text(
                  'Lời nhắc tuỳ chỉnh',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _aiCustomPrompt.isEmpty
                      ? 'Thêm hướng dẫn riêng để trợ lý trả lời theo ý bạn '
                            '(giọng điệu, nguyên tắc, sở thích…).'
                      : _aiCustomPrompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: _editCustomPrompt,
              ),
              const Divider(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _aiPlaceSuggestions,
                onChanged: _togglePlaceSuggestions,
                activeThumbColor: kAppBlue,
                secondary: const Icon(
                  Icons.question_answer,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Gợi ý câu hỏi theo vị trí',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _aiPlaceSuggestions
                      ? 'Trong khung chat, hiện thêm các câu hỏi gợi ý dựa trên '
                            'ngữ cảnh hiện tại (đường, camera, xăng, thời tiết…).'
                      : 'Chỉ hiện các câu hỏi gợi ý cố định trong khung chat.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const SettingsSection('Kết nối & Truy vấn'),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nhà cung cấp AI',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SettingsChoice(
                      label: 'Tự động',
                      subtitle: 'DeepSeek → Gemini',
                      icon: Icons.smart_toy_outlined,
                      selected: _aiProvider == 'auto',
                      onTap: () => _setAiProvider('auto'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
                      label: 'DeepSeek',
                      subtitle: 'Chỉ DeepSeek',
                      icon: Icons.api,
                      selected: _aiProvider == 'deepseek',
                      onTap: () => _setAiProvider('deepseek'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SettingsChoice(
                      label: 'Gemini',
                      subtitle: 'Chỉ Gemini',
                      icon: Icons.auto_awesome,
                      selected: _aiProvider == 'gemini',
                      onTap: () => _setAiProvider('gemini'),
                    ),
                  ),
                ],
              ),
              const Divider(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _aiWebSearch,
                onChanged: _toggleWebSearch,
                activeThumbColor: kAppBlue,
                secondary: const Icon(
                  Icons.travel_explore,
                  color: kAppBlue,
                  size: 22,
                ),
                title: const Text(
                  'Tra cứu web (thời gian thực)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _aiWebSearch
                      ? 'Trợ lý tra cứu dữ kiện mới trên web (giá xăng, tin tức, '
                            'đánh giá) để trả lời sát thực tế.'
                      : 'Tắt tra cứu web — trợ lý chỉ dùng ngữ cảnh + bộ nhớ có '
                            'sẵn.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
              ),
              const Divider(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link, color: kAppBlue, size: 22),
                title: const Text(
                  'Endpoint tùy chỉnh (DeepSeek)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  _aiBaseUrl.isEmpty
                      ? 'Mặc định: ${_aiBaseUrlLabel(_aiBaseUrl)}'
                      : '${_aiBaseUrlLabel(_aiBaseUrl)} · ${_aiModel.isEmpty ? 'deepseek-chat' : _aiModel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[700]),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: _editEndpoint,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _aiBaseUrlLabel(String base) {
    if (base.isEmpty) return 'https://api.deepseek.com';
    return base;
  }
}
