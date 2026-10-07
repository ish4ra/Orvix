import 'dart:async';

/// Thrown inside a preparation that was cancelled, to unwind its remaining
/// work without opening the player.
class PlaybackPreparationCancelled implements Exception {
  const PlaybackPreparationCancelled();

  @override
  String toString() => 'Playback preparation was cancelled.';
}

/// One attempt to prepare a chosen source for playback: everything between
/// picking a source in the list and the player route being pushed (local P2P
/// resolve, debrid/cloud transfer, media bridge, ...).
///
/// The preparation is carried as a zone value, so every async step started
/// from [PlaybackPreparationController.run] can ask whether it was cancelled
/// through [current] without threading a parameter through each helper.
class PlaybackPreparation {
  PlaybackPreparation._(this.id);

  static final Object _zoneKey = Object();

  /// The preparation the calling code runs inside, if any.
  static PlaybackPreparation? get current =>
      Zone.current[_zoneKey] as PlaybackPreparation?;

  /// Throws [PlaybackPreparationCancelled] when the calling code belongs to a
  /// preparation that was cancelled. A no-op outside a preparation.
  static void throwIfCurrentCancelled() => current?.throwIfCancelled();

  final int id;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void throwIfCancelled() {
    if (isCancelled) throw const PlaybackPreparationCancelled();
  }

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Owns the at-most-one active [PlaybackPreparation] of a screen.
///
/// While a preparation runs the user is still on the title screen, so Back
/// must cancel the preparation (returning to the source list) instead of
/// leaving the title. [run] returns as soon as the preparation is cancelled,
/// even while its slow work (for example a torrent resolve) is still in
/// flight; that work later sees [PlaybackPreparation.isCancelled] and stops
/// before it can open a player.
class PlaybackPreparationController {
  int _serial = 0;
  PlaybackPreparation? _active;

  /// True between the start of a preparation and its end (player closed,
  /// failed or cancelled).
  bool get isPreparing => _active != null;

  PlaybackPreparation? get active => _active;

  /// Whether no preparation has started after [preparation].
  bool isLatest(PlaybackPreparation preparation) =>
      preparation.id == _serial;

  /// Runs [body] as a new preparation. Returns `true` when [body] completed,
  /// `false` when the preparation was cancelled. Errors from [body] are
  /// rethrown unless the preparation was cancelled, in which case they belong
  /// to abandoned work and are ignored.
  Future<bool> run(
    Future<void> Function() body, {
    void Function()? onChanged,
  }) async {
    final preparation = PlaybackPreparation._(++_serial);
    _active = preparation;
    onChanged?.call();
    try {
      final work = runZoned(
        body,
        zoneValues: <Object, Object>{
          PlaybackPreparation._zoneKey: preparation,
        },
      );
      // Future.any keeps listening to [work], so a late error from abandoned
      // work is consumed instead of surfacing as an unhandled error.
      await Future.any<void>(<Future<void>>[
        work,
        preparation._cancelled.future,
      ]);
      return !preparation.isCancelled;
    } on PlaybackPreparationCancelled {
      return false;
    } catch (_) {
      if (preparation.isCancelled) return false;
      rethrow;
    } finally {
      if (identical(_active, preparation)) {
        _active = null;
        onChanged?.call();
      }
    }
  }

  /// Cancels the active preparation. Returns whether there was one.
  bool cancelActive() {
    final preparation = _active;
    if (preparation == null) return false;
    preparation._cancel();
    return true;
  }
}

/// The non-TV source flow: show the source list, prepare and play the chosen
/// source, and come back to the same list when the player closes or when the
/// preparation is cancelled with Back. The list is shown from the results the
/// caller already resolved; nothing is fetched again between iterations.
Future<void> runSourcePlaybackLoop<T>({
  required PlaybackPreparationController controller,
  required bool Function() isActive,
  required Future<T?> Function() chooseSource,
  required Future<void> Function(T source) prepareAndPlay,
  required void Function(Object error) onError,
  void Function()? onPreparationChanged,
}) async {
  while (isActive()) {
    final selected = await chooseSource();
    if (selected == null || !isActive()) return;
    try {
      await controller.run(
        () => prepareAndPlay(selected),
        onChanged: onPreparationChanged,
      );
    } catch (error) {
      onError(error);
    }
    if (!isActive()) return;
  }
}
