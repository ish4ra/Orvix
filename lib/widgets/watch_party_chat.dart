import 'package:flutter/material.dart';

import '../services/watch_party/watch_party_chat_policy.dart';
import '../services/watch_party/watch_party_models.dart';
import '../services/watch_party/watch_party_session.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';

/// A room's chat: messages in the room's order, newest at the bottom, and
/// the box to write one. Used in the lobby and in the player's chat panel.
class WatchPartyChat extends StatefulWidget {
  const WatchPartyChat({super.key, required this.session, this.tv = false});

  final WatchPartySession session;

  /// Remote-friendly controls for Android TV.
  final bool tv;

  @override
  State<WatchPartyChat> createState() => _WatchPartyChatState();
}

class _WatchPartyChatState extends State<WatchPartyChat> {
  final _controller = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'WatchPartyChatInput');
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _markRead();
  }

  @override
  void didUpdateWidget(covariant WatchPartyChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
    }
  }

  void _onSession() {
    if (!mounted) return;
    setState(() {});
    _markRead();
  }

  /// Whatever is on screen here has been seen.
  void _markRead() {
    if (widget.session.unreadCount == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.session.markChatRead();
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _controller.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _controller.text;
    if (WatchPartyChatPolicy.clean(text).isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final failure = await widget.session.sendChat(text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = failure;
      // A message that was not sent stays in the box.
      if (failure == null) _controller.clear();
    });
    if (!widget.tv) _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.session.messages;
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(
                    'No messages yet. Say hello.',
                    style: widget.tv
                        ? TvText.body
                        : const TextStyle(color: Color(0xFF9CA99E)),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('watch-party-chat-list'),
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
                    return _Bubble(
                      message: message,
                      mine: message.from == widget.session.selfId,
                      tv: widget.tv,
                    );
                  },
                ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              error,
              key: const ValueKey('watch-party-chat-error'),
              style: const TextStyle(color: Color(0xFFFF9C8F), fontSize: 13),
            ),
          ),
        const SizedBox(height: 8),
        if (widget.tv)
          Row(
            children: [
              Expanded(
                child: TvTextField(
                  key: const ValueKey('watch-party-chat-input'),
                  controller: _controller,
                  enabled: !_sending,
                  hint: 'Message the room',
                  icon: Icons.chat_bubble_outline_rounded,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 10),
              TvButton(
                key: const ValueKey('watch-party-chat-send'),
                icon: Icons.send_rounded,
                label: 'Send',
                busy: _sending,
                onPressed: _send,
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('watch-party-chat-input'),
                  controller: _controller,
                  focusNode: _inputFocus,
                  enabled: !_sending,
                  maxLength: WatchPartyChatPolicy.maxLength,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Message the room',
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('watch-party-chat-send'),
                tooltip: 'Send',
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.tv});

  final WatchPartyMessage message;
  final bool mine;
  final bool tv;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF263B18) : const Color(0xFF131A14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mine ? const Color(0xFF426B2E) : const Color(0xFF1E2B20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              Text(
                message.name,
                style: TextStyle(
                  color: const Color(0xFFCBFF75),
                  fontSize: tv ? 12.5 : 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            Text(
              message.body,
              style: TextStyle(
                color: const Color(0xFFF2F6EE),
                fontSize: tv ? 15 : 14.5,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
