import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../screens/watch_party_screen.dart';
import '../services/watch_party/watch_party_service.dart';
import '../services/watch_party/watch_party_session.dart';
import '../tv/tv_widgets.dart';

/// The way into Watch Party from Settings. Shows the room this device is in,
/// if any. Settings only builds it when the feature is on.
class WatchPartyEntry extends StatelessWidget {
  const WatchPartyEntry({super.key, this.onOpenMedia, this.tv = false});

  final Future<void> Function(MediaItem item)? onOpenMedia;
  final bool tv;

  static const _idle =
      'Watch a movie or episode in sync with friends, each from your own source.';

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WatchPartyScreen(onOpenMedia: onOpenMedia),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WatchPartySession?>(
      valueListenable: WatchPartyService.instance.session,
      builder: (context, session, _) {
        if (session == null) return _tile(context, null);
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) =>
              _tile(context, session.isEnded ? null : session),
        );
      },
    );
  }

  Widget _tile(BuildContext context, WatchPartySession? session) {
    final subtitle = session == null
        ? _idle
        : 'In room ${session.room.formattedCode} · '
            '${session.roster.participants.length} of '
            '${session.room.maxParticipants} people';
    if (tv) {
      return TvSettingsTile(
        key: const ValueKey('watch-party-entry'),
        icon: Icons.groups_outlined,
        title: 'Watch Party',
        subtitle: subtitle,
        value: session == null ? null : 'Open room',
        onPressed: () => _open(context),
      );
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0D120E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF263827)),
      ),
      child: Row(
        children: [
          const Icon(Icons.groups_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Watch Party',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style:
                      const TextStyle(color: Color(0xFF9CA99E), height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            key: const ValueKey('watch-party-entry'),
            onPressed: () => _open(context),
            child: Text(session == null ? 'Open' : 'Open room'),
          ),
        ],
      ),
    );
  }
}
