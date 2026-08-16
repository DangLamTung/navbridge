/// AI assistant chat panel — a modal bottom sheet over the nav map.
///
/// Shows the conversation, streams the assistant's reply live, and lets the
/// driver type or speak ("hỏi AI…"). Grounds each question in the live drive
/// context passed in from the page ([AiContext]).
library;

import 'package:flutter/material.dart';

import 'package:navbridge/core/ai_memory.dart';
import 'package:navbridge/services/ai_assistant.dart';
import 'package:navbridge/services/voice_commands.dart';
import 'package:navbridge/ui/widgets.dart';

class AiChatPanel extends StatefulWidget {
  const AiChatPanel({
    super.key,
    this.context,
    this.initialQuestion,
    this.onMicPressed,
  });

  /// Live drive context appended to each question.
  final AiContext? context;

  /// Question to auto-send when the panel opens (e.g. from a voice command).
  final String? initialQuestion;

  /// Optional: lets the page run its own mic (shared with the nav screen).
  final Future<String> Function()? onMicPressed;

  @override
  State<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends State<AiChatPanel> {
  final List<({bool isUser, String text})> _messages = [];
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  String _streaming = '';

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
    final history = _messages.where((m) => !m.text.startsWith('⚠️')).toList();
    _ctrl.clear();
    setState(() {
      _messages.add((isUser: true, text: q));
      _busy = true;
      _streaming = '';
    });
    _scrollToBottom();

    // Local memory commands ("nhớ …", "quên …", "nhớ gì?") — answered
    // instantly from [AiMemory], no API call (keeps memory usage light).
    final memReply = await handleMemoryIntent(q);
    if (memReply != null) {
      if (!mounted) return;
      setState(() {
        _messages.add((isUser: false, text: memReply));
        _busy = false;
        _streaming = '';
      });
      _scrollToBottom();
      return;
    }

    try {
      await AiAssistant.instance.ask(
        q,
        context: widget.context,
        history: history,
        onToken: (t) {
          if (!mounted) return;
          setState(() => _streaming += t);
          _scrollToBottom();
        },
      );
      if (!mounted) return;
      setState(() {
        _messages.add((isUser: false, text: _streaming));
        _busy = false;
        _streaming = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add((isUser: false, text: '⚠️ $e'));
        _busy = false;
        _streaming = '';
      });
    }
    _scrollToBottom();
  }

  Future<void> _mic() async {
    if (widget.onMicPressed != null) {
      final q = await widget.onMicPressed!();
      if (q.isNotEmpty) await _send(q);
      return;
    }
    // Fallback: a minimal one-shot recognizer (no page wiring).
    final cmd = VoiceCommands();
    await cmd.init();
    await cmd.listen((t) => _send(t));
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return SafeArea(
      child: SizedBox(
        height: h * 0.7,
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
                  return _bubble(isUser: m.isUser, text: m.text);
                },
              ),
            ),
            // Input row.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.mic, color: kAppBlue),
                    onPressed: _busy ? null : _mic,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                      decoration: InputDecoration(
                        hintText: 'Hỏi: xăng gần nhất? ETA? Thời tiết?',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.grey[100],
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
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

  Widget _bubble({required bool isUser, required String text}) {
    final color = isUser ? kAppBlue : const Color(0xFFF1F3F4);
    final fg = isUser ? Colors.white : Colors.black87;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
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
        child: Text(text, style: TextStyle(fontSize: 14, color: fg)),
      ),
    );
  }
}
