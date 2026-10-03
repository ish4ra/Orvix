import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/services/player_resize_preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('player resize mode defaults to Fit', () async {
    expect(
      await PlayerResizePreferencesService.load(),
      PlayerResizeMode.fit,
    );
  });

  test('player resize mode persists the user choice', () async {
    await PlayerResizePreferencesService.save(PlayerResizeMode.zoom);
    expect(
      await PlayerResizePreferencesService.load(),
      PlayerResizeMode.zoom,
    );

    await PlayerResizePreferencesService.save(PlayerResizeMode.fill);
    expect(
      await PlayerResizePreferencesService.load(),
      PlayerResizeMode.fill,
    );
  });

  test('Nuvio-style resize cycle is Fit, Fill, Zoom', () {
    expect(PlayerResizeMode.fit.next, PlayerResizeMode.fill);
    expect(PlayerResizeMode.fill.next, PlayerResizeMode.zoom);
    expect(PlayerResizeMode.zoom.next, PlayerResizeMode.fit);
  });
  test('resize modes map to the expected rendered fit', () {
    expect(PlayerResizeMode.fit.boxFit, BoxFit.contain);
    expect(PlayerResizeMode.fill.boxFit, BoxFit.fill);
    expect(PlayerResizeMode.zoom.boxFit, BoxFit.cover);
  });

}
