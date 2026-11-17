import 'watch_party_models.dart';
import 'watch_party_session.dart';

/// Wording shared by the Watch Party screen and the player overlay.
class WatchPartyText {
  WatchPartyText._();

  static String connection(WatchPartyConnection connection) =>
      switch (connection) {
        WatchPartyConnection.connecting => 'Connecting…',
        WatchPartyConnection.live => 'Connected',
        // Still working, just a little slower to react.
        WatchPartyConnection.polling => 'Connected (slower updates)',
        WatchPartyConnection.reconnecting => 'Reconnecting…',
      };

  /// One line about this device's playback relative to the room.
  static String sync(WatchPartySession session) {
    if (session.connection == WatchPartyConnection.reconnecting) {
      return 'Reconnecting…';
    }
    return switch (session.syncStatus) {
      WatchPartySyncStatus.noPlayer => session.room.media == null
          ? (session.isHost
              ? 'Play a title to start the party'
              : 'Waiting for the host to pick a title')
          : 'Open the title and press play to join in',
      WatchPartySyncStatus.waitingForHost => session.room.media == null
          ? 'Waiting for the host to pick a title'
          : 'Waiting for the host to start',
      WatchPartySyncStatus.wrongTitle => session.room.media == null
          ? 'This video cannot be shared in a Watch Party'
          : 'The party is watching ${session.room.media!.label}',
      WatchPartySyncStatus.inSync =>
        session.isHost ? 'You control playback' : 'In sync',
      WatchPartySyncStatus.catchingUp => 'Catching up…',
      WatchPartySyncStatus.buffering => 'Buffering…',
      WatchPartySyncStatus.pausedLocally =>
        'Paused here · press play to rejoin',
      WatchPartySyncStatus.paused =>
        session.isHost ? 'Paused for everyone' : 'Paused by the host',
    };
  }

  /// Whether [sync] describes something the viewer should notice.
  static bool needsAttention(WatchPartySession session) =>
      session.connection == WatchPartyConnection.reconnecting ||
      switch (session.syncStatus) {
        WatchPartySyncStatus.inSync || WatchPartySyncStatus.noPlayer => false,
        WatchPartySyncStatus.paused => !session.isHost,
        _ => true,
      };

  static String participantStatus(
    WatchPartyParticipant participant, {
    required bool hasMedia,
  }) {
    if (!participant.online) return 'Offline';
    if (participant.buffering) return 'Buffering';
    if (participant.ready) return 'Ready';
    return hasMedia ? 'Choosing a source' : 'In the lobby';
  }

  static String? ended(WatchPartyEndReason? reason) => switch (reason) {
        WatchPartyEndReason.removed => 'The host removed you from the room.',
        WatchPartyEndReason.closed => 'The room was ended.',
        WatchPartyEndReason.expired => 'The room has ended.',
        WatchPartyEndReason.signedOut =>
          'You were signed out, so you left the room.',
        WatchPartyEndReason.left || null => null,
      };
}
