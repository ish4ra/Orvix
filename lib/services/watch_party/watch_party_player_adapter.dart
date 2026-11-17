import 'package:media_kit/media_kit.dart';

import '../orvix_exo_player.dart';

/// What a player is doing right now, as the sync logic needs it.
class WatchPartyPlayerReading {
  const WatchPartyPlayerReading({
    required this.playing,
    required this.buffering,
    required this.positionMs,
    required this.durationMs,
    required this.rate,
  });

  /// The player's intent: true when it is set to play, even while it is
  /// stalled waiting for data. A pause by the user makes this false.
  final bool playing;

  /// Stalled waiting for data.
  final bool buffering;
  final int positionMs;

  /// Zero until the player knows it.
  final int durationMs;
  final double rate;
}

/// The one place Watch Party touches a player engine.
///
/// The sync logic never hooks a player's own controls. It reads the player
/// a few times a second through [read] and, when the room requires it,
/// issues the same four commands the on-screen controls use. Solo playback
/// never creates an adapter, so it is unaffected.
abstract class WatchPartyPlayerAdapter {
  /// Shown in diagnostics only.
  String get engineName;

  /// Whether small speed changes can be used to close a small gap. When
  /// false, gaps are closed by seeking only.
  bool get supportsRate;

  /// Null while the player cannot be read (not created yet, or disposed).
  WatchPartyPlayerReading? read();

  Future<void> play();
  Future<void> pause();
  Future<void> seek(int positionMs);
  Future<void> setRate(double rate);
}

/// media_kit / libmpv: Windows, macOS, iOS and the Android MPV player.
class MediaKitWatchPartyAdapter extends WatchPartyPlayerAdapter {
  MediaKitWatchPartyAdapter(this.player);

  final Player player;

  @override
  String get engineName => 'mpv';

  @override
  bool get supportsRate => true;

  @override
  WatchPartyPlayerReading? read() {
    final state = player.state;
    return WatchPartyPlayerReading(
      playing: state.playing,
      buffering: state.buffering,
      positionMs: state.position.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
      rate: state.rate,
    );
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(int positionMs) =>
      player.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> setRate(double rate) => player.setRate(rate);
}

/// Media3 ExoPlayer: the Android TV default and the optional Android Mobile
/// player. The screen recreates its controller when it retries a stream, so
/// the adapter asks for the current one on every use.
class ExoWatchPartyAdapter extends WatchPartyPlayerAdapter {
  ExoWatchPartyAdapter(this._controller);

  final OrvixExoController? Function() _controller;

  @override
  String get engineName => 'exoPlayer';

  @override
  bool get supportsRate => true;

  OrvixExoController? get _live {
    final controller = _controller();
    if (controller == null || controller.isDisposed || !controller.isCreated) {
      return null;
    }
    return controller;
  }

  @override
  WatchPartyPlayerReading? read() {
    final controller = _live;
    if (controller == null) return null;
    final value = controller.value;
    if (value.hasError) return null;
    return WatchPartyPlayerReading(
      playing: value.playWhenReady,
      buffering: value.buffering,
      positionMs: value.position.inMilliseconds,
      durationMs: value.duration.inMilliseconds,
      rate: value.speed,
    );
  }

  @override
  Future<void> play() async => _live?.play();

  @override
  Future<void> pause() async => _live?.pause();

  @override
  Future<void> seek(int positionMs) async =>
      _live?.seekTo(Duration(milliseconds: positionMs));

  @override
  Future<void> setRate(double rate) async => _live?.setSpeed(rate);
}
