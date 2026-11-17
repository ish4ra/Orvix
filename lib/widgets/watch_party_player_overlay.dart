import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/platform_profile.dart';
import '../services/watch_party/watch_party_feature.dart';
import '../services/watch_party/watch_party_service.dart';
import '../services/watch_party/watch_party_session.dart';
import '../services/watch_party/watch_party_text.dart';
import 'watch_party_chat.dart';

/// Watch Party inside a player: a small status pill, short notices (why a
/// seek was undone, a new chat message) and, on touch and desktop, a chat
/// panel.
///
/// With Watch Party off or no room joined it builds nothing. It never takes
/// keyboard or remote focus, so the player's own keys and DPAD handling are
/// untouched; on Android TV it is display only.
class WatchPartyPlayerOverlay extends StatelessWidget {
  const WatchPartyPlayerOverlay({super.key, required this.controlsVisible});

  /// Whether the player's own controls are showing.
  final bool controlsVisible;

  @override
  Widget build(BuildContext context) {
    if (!WatchPartyFeature.enabled) return const SizedBox.shrink();
    return ValueListenableBuilder<WatchPartySession?>(
      valueListenable: WatchPartyService.instance.session,
      builder: (context, session, _) {
        if (session == null || session.isEnded) return const SizedBox.shrink();
        return _Overlay(session: session, controlsVisible: controlsVisible);
      },
    );
  }
}

class _Overlay extends StatefulWidget {
  const _Overlay({required this.session, required this.controlsVisible});

  final WatchPartySession session;
  final bool controlsVisible;

  @override
  State<_Overlay> createState() => _OverlayState();
}

class _OverlayState extends State<_Overlay> {
  static const _flashFor = Duration(seconds: 5);

  Timer? _flashTimer;
  String? _flash;
  int _seenNotice = 0;
  int _seenMessageSeq = 0;
  bool _panelOpen = false;

  @override
  void initState() {
    super.initState();
    _seenNotice = widget.session.noticeSerial;
    final messages = widget.session.messages;
    _seenMessageSeq = messages.isEmpty ? 0 : messages.last.seq;
    widget.session.addListener(_onSession);
  }

  @override
  void didUpdateWidget(covariant _Overlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _flashTimer?.cancel();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final session = widget.session;
    String? flash;
    if (session.noticeSerial != _seenNotice) {
      _seenNotice = session.noticeSerial;
      flash = session.notice;
    }
    final messages = session.messages;
    if (messages.isNotEmpty && messages.last.seq > _seenMessageSeq) {
      _seenMessageSeq = messages.last.seq;
      final latest = messages.last;
      // The panel already shows it; one's own message needs no echo.
      if (!_panelOpen && latest.from != session.selfId) {
        flash ??= '${latest.name}: ${latest.body}';
      }
    }
    if (flash != null) {
      _flash = flash;
      _flashTimer?.cancel();
      _flashTimer = Timer(_flashFor, () {
        if (mounted) setState(() => _flash = null);
      });
    }
    setState(() {});
  }

  Future<void> _openPanel() async {
    if (_panelOpen) return;
    setState(() {
      _panelOpen = true;
      _flash = null;
    });
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black38,
      builder: (dialogContext) => _ChatPanel(session: widget.session),
    );
    if (mounted) setState(() => _panelOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final tv = PlatformProfile.isAndroidTv;
    final attention = WatchPartyText.needsAttention(session);
    final flash = _flash;
    final visible = widget.controlsVisible || attention || flash != null;
    final padding = MediaQuery.paddingOf(context);
    final warning = session.sourceWarning;

    final pill = _Pill(
      label: WatchPartyText.sync(session),
      people: session.roster.participants.length,
      unread: session.unreadCount,
      attention: attention,
      onTap: tv ? null : _openPanel,
    );

    return Positioned(
      top: padding.top + (tv ? 86 : 70),
      left: padding.left + (tv ? 42 : 14),
      right: padding.right + (tv ? 42 : 14),
      child: IgnorePointer(
        ignoring: tv || !visible,
        child: ExcludeFocus(
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                pill,
                if (flash != null) ...[
                  const SizedBox(height: 6),
                  _Line(text: flash),
                ],
                if (warning != null && widget.controlsVisible) ...[
                  const SizedBox(height: 6),
                  _Line(text: warning, warning: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.people,
    required this.unread,
    required this.attention,
    this.onTap,
  });

  final String label;
  final int people;
  final int unread;
  final bool attention;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFB9FF45);
    final accent = attention ? const Color(0xFFFFC56B) : lime;
    return Material(
      key: const ValueKey('watch-party-pill'),
      color: const Color(0xD90B0F0C),
      shape: StadiumBorder(
        side: BorderSide(color: accent.withValues(alpha: .55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.groups_rounded, size: 17, color: accent),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF2F6EE),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$people',
                style: const TextStyle(
                  color: Color(0xFFA6B1A7),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: lime,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    unread > 99 ? '99+' : '$unread',
                    style: const TextStyle(
                      color: Color(0xFF081006),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.chat_bubble_outline_rounded,
                    size: 15, color: Color(0xFFA6B1A7)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xD90B0F0C),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: warning ? const Color(0xFFFFC56B) : const Color(0xFFF2F6EE),
          fontSize: 13,
          height: 1.3,
        ),
      ),
    );
  }
}

/// Chat over the video: a panel on the right edge.
class _ChatPanel extends StatelessWidget {
  const _ChatPanel({required this.session});

  final WatchPartySession session;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: const Color(0xF20B0F0C),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 12, 12 + keyboard),
            child: SizedBox(
              width: math.min(380, size.width * .92),
              height: double.infinity,
              child: ListenableBuilder(
                listenable: session,
                builder: (context, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Watch Party',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    Text(
                      '${WatchPartyText.sync(session)} · '
                      '${session.roster.participants.length} in the room',
                      style: const TextStyle(color: Color(0xFFA6B1A7)),
                    ),
                    const SizedBox(height: 10),
                    Expanded(child: WatchPartyChat(session: session)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
