import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/platform_profile.dart';
import '../services/watch_party/watch_party_chat_policy.dart';
import '../services/watch_party/watch_party_models.dart';
import '../services/watch_party/watch_party_service.dart';
import '../services/watch_party/watch_party_session.dart';
import '../services/watch_party/watch_party_text.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import '../widgets/watch_party_chat.dart';

const _lime = Color(0xFFB9FF45);
const _card = Color(0xFF0D120E);
const _cardBorder = Color(0xFF263827);
const _muted = Color(0xFF9CA99E);

/// Create or join a private watch room, and the room's lobby: invite code,
/// who is here and whether they are ready, host controls and chat.
///
/// Each person plays the title from their own source. The room only shares
/// what is being watched, the play position and chat.
class WatchPartyScreen extends StatefulWidget {
  const WatchPartyScreen({super.key, this.onOpenMedia});

  /// Opens a title's details so the person can pick their own source.
  final Future<void> Function(MediaItem item)? onOpenMedia;

  @override
  State<WatchPartyScreen> createState() => _WatchPartyScreenState();
}

class _WatchPartyScreenState extends State<WatchPartyScreen> {
  final _service = WatchPartyService.instance;
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _regionKey = GlobalKey<TvFocusRegionState>();

  WatchPartySession? _session;
  bool _busy = false;
  String? _error;
  String? _endNotice;

  bool get _tv => PlatformProfile.isAndroidTv;

  @override
  void initState() {
    super.initState();
    _service.session.addListener(_onSessionChanged);
    _bind(_service.current);
    unawaited(_loadName());
    _focusFirst();
  }

  Future<void> _loadName() async {
    final name = await _service.savedName();
    if (mounted && _nameController.text.isEmpty) _nameController.text = name;
  }

  /// On TV there is no pointer: something must hold focus at all times.
  void _focusFirst() {
    if (!_tv) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _regionKey.currentState?.focusInitial();
    });
  }

  void _onSessionChanged() => _bind(_service.current);

  void _bind(WatchPartySession? next) {
    if (identical(next, _session)) return;
    _session?.removeListener(_onSessionUpdate);
    _session = next;
    next?.addListener(_onSessionUpdate);
    if (mounted) {
      setState(() {});
      _focusFirst();
    }
  }

  void _onSessionUpdate() {
    final session = _session;
    if (session != null && session.isEnded) {
      // The room ended under us: say why on the way back to the start.
      _endNotice = WatchPartyText.ended(session.ended);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.session.removeListener(_onSessionChanged);
    _session?.removeListener(_onSessionUpdate);
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _open(Future<WatchPartySession> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _endNotice = null;
    });
    try {
      await action();
    } on WatchPartyException catch (failure) {
      _error = failure.error.message;
    } catch (_) {
      _error = WatchPartyError.unknown.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() =>
      _open(() => _service.create(_nameController.text));

  Future<void> _join() =>
      _open(() => _service.join(_codeController.text, _nameController.text));

  Future<void> _copyCode(WatchPartySession session) async {
    await Clipboard.setData(ClipboardData(text: session.room.formattedCode));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invite code copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openTitle(WatchPartySession session) async {
    final media = session.room.media;
    final open = widget.onOpenMedia;
    if (media == null || open == null) return;
    await open(media.toItem());
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _card,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _showResult(String? failure) {
    if (failure == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure), duration: const Duration(seconds: 4)),
    );
  }

  Future<void> _leave(WatchPartySession session) async {
    final alone = session.roster.participants.length <= 1;
    if (!await _confirm(
      'Leave the room?',
      alone
          ? 'You are the only one here, so the room will close.'
          : session.isHost
              ? 'Someone else in the room becomes the host.'
              : 'You can come back with the same invite code.',
      'Leave',
    )) {
      return;
    }
    await _service.leave();
  }

  Future<void> _close(WatchPartySession session) async {
    if (!await _confirm(
      'End the room for everyone?',
      'Everyone is disconnected and the chat is deleted.',
      'End room',
    )) {
      return;
    }
    _showResult(await session.closeRoom());
  }

  Future<void> _manage(
    WatchPartySession session,
    WatchPartyParticipant participant,
  ) async {
    final options = <(String, String)>[
      ('host', 'Make ${participant.name} the host'),
      ('remove', 'Remove ${participant.name}'),
    ];
    final String? choice;
    if (_tv) {
      choice = await showTvOptionsDialog<String>(
        context,
        title: participant.name,
        options: options,
      );
    } else {
      choice = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: _card,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.workspace_premium_outlined),
                title: Text(options[0].$2),
                onTap: () => Navigator.pop(sheetContext, 'host'),
              ),
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: Text(options[1].$2),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }
    if (choice == 'host') {
      _showResult(await session.transferHost(participant.id));
    } else if (choice == 'remove') {
      if (!await _confirm(
        'Remove ${participant.name}?',
        'They are disconnected and cannot rejoin this room.',
        'Remove',
      )) {
        return;
      }
      _showResult(await session.removeParticipant(participant.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final active = session != null && !session.isEnded;
    final Widget body;
    if (!_service.isSignedIn && !active) {
      body = _signedOut();
    } else if (!active) {
      body = _tv ? _tvStart() : _start(context);
    } else {
      body = _tv ? _tvLobby(session) : _lobby(context, session);
    }

    if (_tv) {
      return Scaffold(
        backgroundColor: TvColors.background,
        body: SafeArea(
          child: TvFocusRegion(
            key: _regionKey,
            debugLabel: 'WatchParty',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                TvMetrics.pageHorizontal + 12,
                TvMetrics.pageTop,
                TvMetrics.pageHorizontal + 12,
                TvMetrics.pageBottom - 8,
              ),
              child: body,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch Party'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(child: body),
    );
  }

  // --- Signed out ----------------------------------------------------------

  Widget _signedOut() {
    const title = 'Sign in to use Watch Party';
    const message =
        'Rooms are private to Orvix accounts. Sign in from Account, then come back here.';
    if (_tv) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TvPageHeader(title: 'Watch Party'),
          Expanded(
            child: TvMessage(
              icon: Icons.lock_outline_rounded,
              title: title,
              message: message,
              action: TvButton(
                key: const ValueKey('watch-party-back'),
                label: 'Back',
                icon: Icons.arrow_back_rounded,
                preferred: true,
                autofocus: true,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.lock_outline_rounded, size: 44, color: _lime),
            SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  // --- Start: create or join ----------------------------------------------

  static const _explainer =
      'Everyone plays the title from their own source. Orvix shares only what is being watched, the play position and chat.';

  Widget _start(BuildContext context) {
    final notice = _endNotice;
    final error = _error;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Watch together',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                const Text(_explainer,
                    style: TextStyle(color: _muted, height: 1.45)),
                if (notice != null) ...[
                  const SizedBox(height: 16),
                  _Banner(icon: Icons.info_outline_rounded, text: notice),
                ],
                const SizedBox(height: 20),
                TextField(
                  key: const ValueKey('watch-party-name'),
                  controller: _nameController,
                  enabled: !_busy,
                  maxLength: WatchPartyChatPolicy.maxNameLength,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Your name in the room',
                    prefixIcon: Icon(Icons.badge_outlined),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                _Panel(
                  title: 'Start a room',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'You get an invite code to share. Up to 10 people.',
                        style: TextStyle(color: _muted, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        key: const ValueKey('watch-party-create'),
                        onPressed: _busy ? null : _create,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Create room'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _Panel(
                  title: 'Join a room',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const ValueKey('watch-party-code'),
                        controller: _codeController,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _join(),
                        style: const TextStyle(
                          letterSpacing: 3,
                          fontWeight: FontWeight.w800,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[A-Za-z0-9\- ]')),
                          LengthLimitingTextInputFormatter(11),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Invite code',
                          hintText: 'ABCD-EFGH',
                          prefixIcon: Icon(Icons.vpn_key_outlined),
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        key: const ValueKey('watch-party-join'),
                        onPressed: _busy ? null : _join,
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Join room'),
                      ),
                    ],
                  ),
                ),
                if (_busy) ...[
                  const SizedBox(height: 18),
                  const LinearProgressIndicator(minHeight: 3),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  _Banner(
                    key: const ValueKey('watch-party-error'),
                    icon: Icons.error_outline_rounded,
                    text: error,
                    danger: true,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tvStart() {
    final message = _error ?? _endNotice;
    return ListView(
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TvPageHeader(title: 'Watch Party', subtitle: _explainer),
                const SizedBox(height: 22),
                TvTextField(
                  key: const ValueKey('watch-party-name'),
                  controller: _nameController,
                  enabled: !_busy,
                  label: 'Your name in the room',
                  icon: Icons.badge_outlined,
                ),
                const SizedBox(height: 14),
                TvButton(
                  key: const ValueKey('watch-party-create'),
                  kind: TvButtonKind.primary,
                  icon: Icons.add_rounded,
                  label: 'Create room',
                  expanded: true,
                  preferred: true,
                  busy: _busy,
                  onPressed: _create,
                ),
                const SizedBox(height: 26),
                const TvSectionHeader('Join with an invite code'),
                const SizedBox(height: 12),
                TvTextField(
                  key: const ValueKey('watch-party-code'),
                  controller: _codeController,
                  enabled: !_busy,
                  label: 'Invite code',
                  hint: 'ABCD-EFGH',
                  icon: Icons.vpn_key_outlined,
                  onSubmitted: (_) => _join(),
                ),
                const SizedBox(height: 14),
                TvButton(
                  key: const ValueKey('watch-party-join'),
                  icon: Icons.login_rounded,
                  label: 'Join room',
                  expanded: true,
                  busy: _busy,
                  onPressed: _join,
                ),
                if (message != null) ...[
                  const SizedBox(height: 18),
                  Text(
                    message,
                    key: const ValueKey('watch-party-error'),
                    style: TvText.body.copyWith(
                      color: _error != null ? TvColors.danger : TvColors.text,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // --- Lobby ---------------------------------------------------------------

  String _titleHint(WatchPartySession session) {
    final media = session.room.media;
    if (media == null) {
      return session.isHost
          ? 'Go back, open any movie or episode and press play. It becomes the room\'s title and everyone is invited to open it.'
          : 'The host has not picked a title yet. You will see it here.';
    }
    if (session.hasPlayer) return WatchPartyText.sync(session);
    final episode = media.episodeLabel;
    return episode == null
        ? 'Open the title, pick your own source and press play. You join at the room\'s position.'
        : 'Open the title, choose $episode, pick your own source and press play. You join at the room\'s position.';
  }

  Widget _lobby(BuildContext context, WatchPartySession session) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final details = <Widget>[
      _codeCard(session),
      const SizedBox(height: 14),
      _titleCard(session),
      const SizedBox(height: 14),
      _peopleCard(session),
      const SizedBox(height: 14),
      _lobbyActions(session),
    ];
    final chat = _Panel(
      title: 'Chat',
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: SizedBox(
        height: wide ? null : 340,
        child: WatchPartyChat(session: session),
      ),
    );
    if (!wide) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        children: [...details, const SizedBox(height: 14), chat],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: ListView(children: details)),
          const SizedBox(width: 22),
          Expanded(
            flex: 4,
            child: _Panel(
              title: 'Chat',
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              expandChild: true,
              child: WatchPartyChat(session: session),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeCard(WatchPartySession session) {
    final connection = session.connection;
    final problem = connection == WatchPartyConnection.reconnecting;
    return _Panel(
      title: 'Invite code',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: SelectableText(
                    session.room.formattedCode,
                    key: const ValueKey('watch-party-room-code'),
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 5,
                      color: _lime,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: 'Copy invite code',
                onPressed: () => _copyCode(session),
                icon: const Icon(Icons.copy_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                problem ? Icons.sync_problem_rounded : Icons.circle,
                size: problem ? 16 : 9,
                color: problem ? const Color(0xFFFFC56B) : _lime,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${WatchPartyText.connection(connection)} · '
                  '${session.roster.participants.length} of '
                  '${session.room.maxParticipants} people',
                  key: const ValueKey('watch-party-connection'),
                  style: const TextStyle(color: _muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _titleCard(WatchPartySession session) {
    final media = session.room.media;
    final warning = session.sourceWarning;
    return _Panel(
      title: 'Now watching',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            media?.label ?? 'Nothing yet',
            key: const ValueKey('watch-party-title'),
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            _titleHint(session),
            key: const ValueKey('watch-party-status'),
            style: const TextStyle(color: _muted, height: 1.45),
          ),
          if (warning != null) ...[
            const SizedBox(height: 12),
            _Banner(icon: Icons.warning_amber_rounded, text: warning),
          ],
          if (media != null && widget.onOpenMedia != null) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const ValueKey('watch-party-open-title'),
              onPressed: () => _openTitle(session),
              icon: const Icon(Icons.play_circle_outline_rounded),
              label: const Text('Open title'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _peopleCard(WatchPartySession session) {
    final hasMedia = session.room.media != null;
    return _Panel(
      title: 'In the room',
      child: Column(
        children: [
          for (final participant in session.roster.participants)
            _PersonRow(
              key: ValueKey('watch-party-person-${participant.id}'),
              participant: participant,
              host: participant.id == session.roster.hostId,
              self: participant.id == session.selfId,
              status: WatchPartyText.participantStatus(participant,
                  hasMedia: hasMedia),
              onManage: session.isHost && participant.id != session.selfId
                  ? () => _manage(session, participant)
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _lobbyActions(WatchPartySession session) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('watch-party-leave'),
          onPressed: () => _leave(session),
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Leave room'),
        ),
        if (session.isHost)
          OutlinedButton.icon(
            key: const ValueKey('watch-party-end'),
            onPressed: () => _close(session),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('End room for everyone'),
          ),
      ],
    );
  }

  Widget _tvLobby(WatchPartySession session) {
    final media = session.room.media;
    final hasMedia = media != null;
    final warning = session.sourceWarning;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: ListView(
            children: [
              TvPageHeader(
                title: 'Watch Party',
                subtitle: '${WatchPartyText.connection(session.connection)} · '
                    '${session.roster.participants.length} of '
                    '${session.room.maxParticipants} people',
              ),
              const SizedBox(height: 16),
              Text('INVITE CODE', style: TvText.caption),
              const SizedBox(height: 4),
              Text(
                session.room.formattedCode,
                key: const ValueKey('watch-party-room-code'),
                style: TvText.display.copyWith(
                  color: TvColors.primary,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 18),
              Text('NOW WATCHING', style: TvText.caption),
              const SizedBox(height: 4),
              Text(
                media?.label ?? 'Nothing yet',
                key: const ValueKey('watch-party-title'),
                style: TvText.section,
              ),
              const SizedBox(height: 6),
              Text(
                _titleHint(session),
                key: const ValueKey('watch-party-status'),
                style: TvText.body,
              ),
              if (warning != null) ...[
                const SizedBox(height: 8),
                Text(warning,
                    style: TvText.body.copyWith(color: TvColors.danger)),
              ],
              const SizedBox(height: 14),
              if (hasMedia && widget.onOpenMedia != null) ...[
                TvButton(
                  key: const ValueKey('watch-party-open-title'),
                  kind: TvButtonKind.primary,
                  icon: Icons.play_circle_outline_rounded,
                  label: 'Open title',
                  expanded: true,
                  preferred: true,
                  onPressed: () => _openTitle(session),
                ),
                const SizedBox(height: 18),
              ],
              const TvSectionHeader('In the room'),
              const SizedBox(height: 10),
              for (final participant in session.roster.participants) ...[
                TvListRow(
                  key: ValueKey('watch-party-person-${participant.id}'),
                  icon: participant.id == session.roster.hostId
                      ? Icons.workspace_premium_outlined
                      : Icons.person_outline_rounded,
                  title: participant.id == session.selfId
                      ? '${participant.name} (you)'
                      : participant.name,
                  subtitle: [
                    if (participant.id == session.roster.hostId) 'Host',
                    WatchPartyText.participantStatus(participant,
                        hasMedia: hasMedia),
                  ].join(' · '),
                  trailingIcon:
                      session.isHost && participant.id != session.selfId
                          ? Icons.more_horiz_rounded
                          : null,
                  onPressed: session.isHost && participant.id != session.selfId
                      ? () => _manage(session, participant)
                      : null,
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  TvButton(
                    key: const ValueKey('watch-party-leave'),
                    icon: Icons.logout_rounded,
                    label: 'Leave room',
                    preferred: !hasMedia || widget.onOpenMedia == null,
                    onPressed: () => _leave(session),
                  ),
                  if (session.isHost)
                    TvButton(
                      key: const ValueKey('watch-party-end'),
                      icon: Icons.cancel_outlined,
                      label: 'End room for everyone',
                      onPressed: () => _close(session),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        const SizedBox(width: 28),
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TvSectionHeader('Chat'),
              const SizedBox(height: 10),
              Expanded(child: WatchPartyChat(session: session, tv: true)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.expandChild = false,
  });

  final String title;
  final Widget child;
  final EdgeInsets padding;
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: _muted,
            ),
          ),
          const SizedBox(height: 10),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.text,
    this.danger = false,
  });

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFFF9C8F) : const Color(0xFFFFC56B);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: color, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.participant,
    required this.host,
    required this.self,
    required this.status,
    this.onManage,
  });

  final WatchPartyParticipant participant;
  final bool host;
  final bool self;
  final String status;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final good = participant.online && participant.ready;
    final bad = !participant.online || participant.buffering;
    final statusColor = bad
        ? const Color(0xFFFFC56B)
        : good
            ? _lime
            : _muted;
    final initial = participant.name.isEmpty
        ? '?'
        : String.fromCharCode(participant.name.runes.first).toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xFF263B18),
            child: Text(
              initial,
              style: const TextStyle(
                color: Color(0xFFE9FFD0),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        self ? '${participant.name} (you)' : participant.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (host) ...[
                      const SizedBox(width: 8),
                      const _Tag('Host'),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(status, style: TextStyle(color: statusColor, fontSize: 13)),
              ],
            ),
          ),
          if (onManage != null)
            IconButton(
              tooltip: 'Manage ${participant.name}',
              onPressed: onManage,
              icon: const Icon(Icons.more_horiz_rounded),
            ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF263B18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _lime,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
