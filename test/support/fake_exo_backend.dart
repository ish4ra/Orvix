import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/android_exo_player_screen.dart';
import 'package:orvix/services/orvix_exo_player.dart';

/// Stand-in for Orvix's native Media3 player: records commands and lets a
/// test send the same events the Kotlin bridge sends.
class FakeExoBackend implements OrvixExoBackend {
  final created = <Map<String, Object?>>[];
  final commands = <({int id, String method, Map<String, Object?> args})>[];
  final disposed = <int>[];
  final _listeners = <int, void Function(Map<Object?, Object?>)>{};
  var _next = 1;

  int get lastId => _next - 1;

  @override
  Future<({int id, int textureId, bool handlesCropAndRotation})> create(
    Map<String, Object?> arguments,
  ) async {
    created.add(arguments);
    final id = _next++;
    return (id: id, textureId: 100 + id, handlesCropAndRotation: true);
  }

  @override
  Future<void> command(
    int id,
    String method, [
    Map<String, Object?>? args,
  ]) async {
    commands.add((id: id, method: method, args: args ?? const {}));
    if (method == 'dispose') disposed.add(id);
  }

  List<Map<String, Object?>> calls(String method) => [
        for (final c in commands)
          if (c.method == method) c.args,
      ];

  @override
  void listen(int id, void Function(Map<Object?, Object?> event) onEvent) {
    _listeners[id] = onEvent;
  }

  @override
  void unlisten(int id) => _listeners.remove(id);

  void emit(int id, Map<String, Object?> event) =>
      _listeners[id]?.call(<Object?, Object?>{...event, 'id': id});

  void state(
    int id, {
    int state = 3,
    bool playing = true,
    int positionMs = 0,
    int durationMs = 2640000,
    double speed = 1.0,
  }) =>
      emit(id, {
        'event': 'state',
        'state': state,
        'playing': playing,
        'playWhenReady': true,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'bufferedMs': positionMs + 20000,
        'speed': speed,
      });

  void error(int id, String code, {String message = 'Source error'}) => emit(
        id,
        {'event': 'error', 'code': code, 'message': message, 'cause': ''},
      );

  void tracks(int id, List<Map<String, Object?>> tracks) =>
      emit(id, {'event': 'tracks', 'tracks': tracks});

  void cues(int id, List<String> lines) =>
      emit(id, {'event': 'cues', 'text': lines, 'bitmaps': const []});
}

class ExoUnderTest {
  ExoUnderTest(this.result);

  final Future<AndroidExoPlayerResult?> result;

  /// Waits for the player route to close. With [pop], sends Back first.
  Future<AndroidExoPlayerResult?> close(
    WidgetTester tester, {
    bool pop = true,
  }) async {
    if (pop) await tester.binding.handlePopRoute();
    AndroidExoPlayerResult? value;
    var done = false;
    unawaited(result.then((closed) {
      value = closed;
      done = true;
    }));
    for (var i = 0; i < 60 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done, isTrue, reason: 'the player route closed');
    return value;
  }
}

const exoTestMovie = MediaItem(
  id: 'tt0903747',
  kind: MediaKind.series,
  title: 'Breaking Bad',
  year: '2008',
);

Future<ExoUnderTest> openExo(
  WidgetTester tester,
  String url, {
  bool autoFallbackToMpv = false,
  List<String>? stages,
  MediaItem? item,
  String? nextEpisodeLabel,
  Size size = const Size(1280, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: navigator,
    home: const SizedBox.shrink(),
  ));
  final result = navigator.currentState!.push<AndroidExoPlayerResult>(
    MaterialPageRoute(
      builder: (_) => AndroidExoPlayerScreen(
        url: url,
        title: 'Breaking Bad • S01E01',
        item: item,
        autoFallbackToMpv: autoFallbackToMpv,
        nextEpisodeLabel: nextEpisodeLabel,
        onStartupStage: stages == null
            ? null
            : (stage, result, _) => stages.add('$stage:$result'),
      ),
    ),
  );
  // Let the screen load its preferences and create the native player.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  return ExoUnderTest(result);
}
