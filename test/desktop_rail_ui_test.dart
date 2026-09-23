import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop shelves use functional horizontal rail controls', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final rail =
        File('lib/widgets/horizontal_scroll_rail.dart').readAsStringSync();

    expect(home, contains('HorizontalScrollRail('));
    expect(home, contains('_ContinueLandscapeCard('));
    expect(home, contains('episode?.thumbnail'));
    expect(rail, contains('PointerScrollEvent'));
    expect(rail, contains('pointerSignalResolver.register'));
    expect(rail, contains('PointerDeviceKind.mouse'));
    expect(rail, contains('Icons.chevron_right_rounded'));
    expect(rail, contains('Icons.chevron_left_rounded'));
  });

  test('Windows desktop series rail itself uses the functional horizontal rail', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    final start = details.indexOf('Widget _desktopSeriesRail(');
    final end = details.indexOf('Widget _tvDetailsLayout(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final desktopRail = details.substring(start, end);

    expect(desktopRail, contains('_DesktopEpisodeCard('));
    expect(
      RegExp(r'HorizontalScrollRail\(').allMatches(desktopRail).length,
      greaterThanOrEqualTo(2),
    );
    expect(desktopRail, isNot(contains('ListView.separated(')));
    expect(details, contains("tooltip: 'Sources'"));
    expect(details, contains("tooltip: 'Play'"));
  });

  test('cloud paths opt into the Orvix local media bridge', () {
    final details = File('lib/screens/details_screen.dart').readAsStringSync();

    expect(details, contains('LocalMediaBridgeService.instance.bridge('));
    expect(details, contains('useLocalMediaBridge: true'));
    expect(details, contains('Opening through the Orvix local media bridge'));
  });
}
