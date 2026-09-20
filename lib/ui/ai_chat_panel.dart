/// AI assistant chat panel — a modal bottom sheet over the nav map.
///
/// Shows the conversation, streams the assistant's reply live, and lets the
/// driver type or speak ("hỏi AI…"). Grounds each question in the live drive
/// context passed in from the page ([AiContext]).
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'package:navbridge/core/ai_memory.dart';
import 'package:navbridge/core/settings.dart' show aiPlaceSuggestions;
import 'package:navbridge/services/ai_assistant.dart';
import 'package:navbridge/services/voice_commands.dart';
import 'package:navbridge/ui/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    super.key,
    this.context,
    this.liveContext,
    this.initialQuestion,
    this.onMicPressed,
    this.onMicCancel,
    this.speakAloud = false,
    this.onSpeak,
    this.onNavigate,
  });

  /// Live drive context appended to each question.
  final AiContext? context;

  /// Optional live context streamed in AFTER the panel opens (opens instantly
  /// with [context], then updates when the async drive facts resolve).
  final ValueListenable<AiContext?>? liveContext;

  /// Question to auto-send when the panel opens (e.g. from a voice command).
  final String? initialQuestion;

  /// Optional: lets the page run its own mic (shared with the nav screen).
  final Future<String> Function({void Function(String partial)? onPartial})?
  onMicPressed;

  /// Cancel/stop the page-provided mic session early.
  final Future<void> Function()? onMicCancel;

  /// Speak the assistant answer aloud while it streams (hands-free driving).
  /// [onSpeak] receives complete sentences; pass an empty string to flush.
  final bool speakAloud;
  final void Function(String sentence)? onSpeak;

  /// Plan a route to a place the AI found (panel closes itself first).
  final void Function(String name, double lat, double lng)? onNavigate;

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

/// A chat message shown in the panel.
class _Msg {
  final bool isUser;
  final String text;
  final String? provider;
  final List<AiPlace> places;
  final AiPlace? navigateTarget;
  const _Msg(
    this.isUser,
    this.text, {
    this.provider,
    this.places = const [],
    this.navigateTarget,
  });
}

/// A one-tap suggested question shown under the chat. Each prompt exercises
/// one of the assistant's tools: place search (xăng / nhà hàng / cà phê /
/// named place), drive context (ETA / camera / thời tiết), scenic stops and
/// web search (giá xăng hôm nay).
class _Suggestion {
  final String label;
  final String prompt;
  final IconData icon;
  final Color color;
  const _Suggestion(this.label, this.prompt, this.icon, this.color);
}

const _suggestions = <_Suggestion>[
  _Suggestion(
    'Trạm xăng',
    'Tìm trạm xăng gần nhất và chỉ đường tới đó',
    Icons.local_gas_station,
    Color(0xFFF4B400),
  ),
  _Suggestion(
    'Nhà hàng',
    'Nhà hàng nào ngon (đánh giá cao) gần đây?',
    Icons.restaurant,
    Color(0xFFEA4335),
  ),
  _Suggestion(
    'Cà phê',
    'Tìm quán cà phê gần đây',
    Icons.local_cafe,
    Color(0xFFB5651D),
  ),
  _Suggestion(
    'Còn bao lâu',
    'Còn bao lâu thì tới nơi?',
    Icons.schedule,
    kAppBlue,
  ),
  _Suggestion(
    'Camera',
    'Phía trước có camera tốc độ không?',
    Icons.videocam,
    Color(0xFF1A73E8),
  ),
  _Suggestion(
    'Thời tiết',
    'Thời tiết hiện tại và sắp tới thế nào?',
    Icons.wb_sunny,
    Color(0xFFF09300),
  ),
  _Suggestion(
    'Điểm dừng',
    'Gợi ý 3-5 điểm dừng đẹp (ngắm cảnh, đèo, cà phê) gần tuyến đường của tôi',
    Icons.landscape,
    Color(0xFF1E8E3E),
  ),
  _Suggestion(
    'Giá xăng',
    'Giá xăng hôm nay bao nhiêu?',
    Icons.trending_up,
    Color(0xFF9334E6),
  ),
];

class _AiChatPanelState extends State<AiChatPanel> {
  final List<_Msg> _messages = [];
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  bool _listening = false;
  String _streaming = '';
  String _speechBuf = ''; // streamed sentences not yet spoken

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuestion?.trim();
    if (q != null && q.isNotEmpty) {
      _ctrl.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(q));
    }
  }

  @override
  void dispose() {
    if (_listening) {
      widget.onMicCancel?.call();
    }
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send(String raw) async {
    final q = raw.trim();
    if (q.isEmpty || _busy) return;
    // Session memory = previous turns only (the current question is added
    // below and sent separately as [userText]).
    final history = _messages
        .where((m) => !m.text.startsWith('⚠️'))
        .map((m) => (isUser: m.isUser, text: m.text))
        .toList();
    _ctrl.clear();
    widget.onSpeak?.call(''); // flush any previous spoken answer
    setState(() {
      _messages.add(_Msg(true, q));
      _busy = true;
      _streaming = '';
      _speechBuf = '';
    });
    _scrollToBottom();

    // Local memory commands ("nhớ …", "quên …", "nhớ gì?") — answered
    // instantly from [AiMemory], no API call (keeps memory usage light).
    final memReply = await handleMemoryIntent(q);
    if (memReply != null) {
      if (!mounted) return;
      setState(() {
        _messages.add(_Msg(false, memReply));
        _busy = false;
        _streaming = '';
      });
      if (widget.speakAloud) widget.onSpeak?.call(memReply);
      _scrollToBottom();
      return;
    }

    try {
      final reply = await AiAssistant.instance.ask(
        q,
        context: widget.liveContext?.value ?? widget.context,
        history: history,
        onToken: (t) {
          if (!mounted) return;
          setState(() => _streaming += t);
          _maybeSpeak(t);
          _scrollToBottom();
        },
      );
      if (!mounted) return;
      _flushSpeech();
      setState(() {
        _messages.add(
          _Msg(
            false,
            reply.text.isNotEmpty ? reply.text : _streaming,
            provider: reply.provider,
            places: reply.places,
            navigateTarget: reply.navigateTarget,
          ),
        );
        _busy = false;
        _streaming = '';
      });
    } catch (e) {
      if (!mounted) return;
      _flushSpeech();
      setState(() {
        _messages.add(_Msg(false, '⚠️ $e'));
        _busy = false;
        _streaming = '';
      });
    }
    _scrollToBottom();
  }

  /// Speak complete sentences aloud as they stream (hands-free driving).
  void _maybeSpeak(String token) {
    if (!widget.speakAloud || widget.onSpeak == null) return;
    _speechBuf += token;
    var lastEnd = -1;
    for (var i = 0; i < _speechBuf.length; i++) {
      final ch = _speechBuf[i];
      if (ch == '.' || ch == '!' || ch == '?' || ch == '\n' || ch == '。') {
        lastEnd = i + 1;
      }
    }
    if (lastEnd > 0) {
      final sentence = _speechBuf.substring(0, lastEnd).trim();
      _speechBuf = _speechBuf.substring(lastEnd);
      if (sentence.isNotEmpty) widget.onSpeak!(sentence);
    }
  }

  void _flushSpeech() {
    if (!widget.speakAloud || widget.onSpeak == null) return;
    final rest = _speechBuf.trim();
    _speechBuf = '';
    if (rest.isNotEmpty) widget.onSpeak!(rest);
  }

  String _providerLabel(String p) => switch (p) {
    'deepseek' => 'DeepSeek',
    'gemini' => 'Gemini',
    _ => 'Ngoại tuyến',
  };

  /// Location-aware suggested questions: derived from the live drive context
  /// (road / speed / hard sections / passes / gas / camera / weather) so the
  /// one-tap prompts fit where the driver actually is. Empty when the feature
  /// is off in Settings or there's no context.
  List<_Suggestion> _placeSuggestions() {
    if (!aiPlaceSuggestions) return const [];
    final c = widget.context;
    if (c == null) return const [];
    final out = <_Suggestion>[];
    if (c.road != null) {
      out.add(_Suggestion(
        'Con đường',
        'Mô tả con đường đang đi và có gì đặc biệt',
        Icons.route,
        Color(0xFFF09300),
      ));
    }
    if (c.speedKmh != null) {
      out.add(_Suggestion(
        'Tốc độ',
        'Tốc độ hiện tại có phù hợp với giới hạn không?',
        Icons.speed,
        kAppBlue,
      ));
    }
    if (c.hardSections != null) {
      out.add(_Suggestion(
        'Đoạn khó',
        'Đoạn đường phía trước có khó đi không?',
        Icons.warning_amber,
        Color(0xFFEA4335),
      ));
    }
    if (c.passesAhead != null) {
      out.add(_Suggestion(
        'Đèo',
        'Còn bao nhiêu đèo phía trước?',
        Icons.terrain,
        Color(0xFF1E8E3E),
      ));
    }
    if (c.gasNextKm != null) {
      out.add(_Suggestion(
        'Trạm xăng',
        'Trạm xăng gần nhất còn bao xa?',
        Icons.local_gas_station,
        Color(0xFFF4B400),
      ));
    }
    if (c.cameraAhead != null) {
      out.add(_Suggestion(
        'Camera',
        'Camera phía trước có xa không?',
        Icons.videocam,
        Color(0xFF1A73E8),
      ));
    }
    if (c.weather != null || c.radar != null) {
      out.add(_Suggestion(
        'Thời tiết',
        'Đường sắp tới có mưa gây khó không?',
        Icons.wb_sunny,
        Color(0xFFF09300),
      ));
    }
    return out;
  }

  /// Live drive context shown as chips (what the AI already knows).
  List<Widget> _contextChips() {
    final c = widget.context;
    if (c == null) return const [];
    return [
      if (c.weather != null) _chip('🌦 ${c.weather}'),
      if (c.radar != null) _chip('🌧 ${c.radar}'),
      if (c.cameraAhead != null) _chip('📷 ${c.cameraAhead}'),
      if (c.road != null) _chip('🛣 ${c.road}'),
      if (c.speedKmh != null) _chip('⚡ ${c.speedKmh}'),
      if (c.destination != null) _chip('📍 ${c.destination}'),
      if (c.eta != null) _chip('🕒 ${c.eta}'),
    ];
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F0FE),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: kAppBlue)),
    );
  }

  Future<void> _mic() async {
    if (_listening) {
      await widget.onMicCancel?.call();
      if (mounted) setState(() => _listening = false);
      return;
    }

    if (widget.onMicPressed != null) {
      setState(() => _listening = true);
      try {
        final q = await widget.onMicPressed!(
          onPartial: (p) {
            if (mounted) {
              setState(() => _ctrl.text = p);
            }
          },
        );
        if (mounted) {
          setState(() => _listening = false);
          if (q.trim().isNotEmpty) {
            _ctrl.text = q.trim();
            await _send(q.trim());
          }
        }
      } catch (e) {
        debugPrint('AI CHAT: mic error $e');
        if (mounted) setState(() => _listening = false);
      }
      return;
    }

    // Fallback: a minimal one-shot recognizer (no page wiring).
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return;
    setState(() => _listening = true);
    try {
      final cmd = VoiceCommands();
      final ok = await cmd.init();
      if (!ok) {
        if (mounted) setState(() => _listening = false);
        return;
      }
      await cmd.listen(
        (t) {
          if (mounted) {
            setState(() => _listening = false);
            if (t.trim().isNotEmpty) {
              _ctrl.text = t.trim();
              _send(t.trim());
            }
          }
        },
        onPartial: (p) {
          if (mounted) setState(() => _ctrl.text = p);
        },
        budget: const Duration(seconds: 15),
      );
    } catch (_) {}
    if (mounted) setState(() => _listening = false);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final h = media.size.height;
    final kb = media.viewInsets.bottom;
    // When the virtual keyboard opens, shrink the sheet to the space above it
    // so the input row (mic / text / send) is never hidden behind the keys.
    final sheetH = kb > 0 ? (h - kb).clamp(0.0, h) : h * 0.7;
    return SafeArea(
      child: SizedBox(
        height: sheetH,
        child: Column(
          children: [
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, color: kAppBlue, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Trợ lý AI',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Live context chips (weather / camera / road / speed / ETA) so
            // the driver sees what the AI already knows.
            if (_contextChips().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _contextChips(),
                ),
              ),
            // Messages.
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length + (_busy ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i >= _messages.length) {
                    return _bubble(
                      isUser: false,
                      text: _streaming.isEmpty ? '…' : _streaming,
                    );
                  }
                  final m = _messages[i];
                  return _bubble(
                    isUser: m.isUser,
                    text: m.text,
                    provider: m.provider,
                    places: m.places,
                    navigateTarget: m.navigateTarget,
                  );
                },
              ),
            ),
            // One-tap quick suggestions — each exercises one of the AI's
            // tools: place search (xăng / nhà hàng / cà phê), drive context
            // (ETA / camera / thời tiết), scenic stops + web search (giá xăng).
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final s in _placeSuggestions()) _suggestionChip(s),
                      for (final s in _suggestions) _suggestionChip(s),
                    ],
                  ),
                ),
              ),
            ),
            // Input row.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: _listening
                          ? const Color(0xFFFFEBEE)
                          : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        _listening ? Icons.mic : Icons.mic_none,
                        color: _listening ? Colors.redAccent : kAppBlue,
                        size: 24,
                      ),
                      tooltip:
                          _listening ? 'Đang nghe… Nhấn để dừng' : 'Nói câu hỏi',
                      onPressed: _busy ? null : _mic,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                      decoration: InputDecoration(
                        hintText: _listening
                            ? 'Đang nghe… Hãy nói câu hỏi của bạn'
                            : 'Hỏi: xăng gần nhất? ETA? Thời tiết?',
                        hintStyle: TextStyle(
                          color: _listening
                              ? Colors.redAccent.shade700
                              : Colors.grey[600],
                          fontStyle:
                              _listening ? FontStyle.italic : FontStyle.normal,
                        ),
                        isDense: true,
                        filled: true,
                        fillColor: _listening
                            ? const Color(0xFFFFF8F8)
                            : Colors.grey[100],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: _listening
                              ? const BorderSide(
                                  color: Colors.redAccent,
                                  width: 1.5,
                                )
                              : BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: _listening
                              ? const BorderSide(
                                  color: Colors.redAccent,
                                  width: 1.5,
                                )
                              : BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: _listening
                              ? const BorderSide(
                                  color: Colors.redAccent,
                                  width: 1.5,
                                )
                              : BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    icon: const Icon(Icons.send, color: kAppBlue),
                    onPressed: _busy ? null : () => _send(_ctrl.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionChip(_Suggestion s) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: Icon(s.icon, size: 16, color: s.color),
        label: Text(s.label, style: const TextStyle(fontSize: 12)),
        backgroundColor: const Color(0xFFE8F0FE),
        side: BorderSide(color: kAppBlue.withValues(alpha: 0.3)),
        onPressed: _busy ? null : () => _send(s.prompt),
      ),
    );
  }

  Widget _bubble({
    required bool isUser,
    required String text,
    String? provider,
    List<AiPlace> places = const [],
    AiPlace? navigateTarget,
  }) {
    final color = isUser ? kAppBlue : const Color(0xFFF1F3F4);
    final fg = isUser ? Colors.white : Colors.black87;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: TextStyle(fontSize: 14, color: fg)),
            if (!isUser && provider != null) ...[
              const SizedBox(height: 2),
              Text(
                _providerLabel(provider),
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              ),
            ],
            if (!isUser && places.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in places)
                    ActionChip(
                      avatar: const Icon(Icons.navigation, size: 14),
                      label: Text(
                        p.name,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        Navigator.of(context).maybePop();
                        widget.onNavigate?.call(p.name, p.lat, p.lng);
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
