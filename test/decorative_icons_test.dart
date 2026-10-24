import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Orvix does not use generic sparkle/star decoration as iconography.
/// Functional stars (ratings, preferred release groups) are not decoration.
void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('no sparkle-style decorative icons in the app', () {
    for (final file in sources) {
      final text = file.readAsStringSync();
      for (final icon in [
        'Icons.auto_awesome',
        'Icons.movie_filter',
        'Icons.auto_fix',
        'Icons.flare',
      ]) {
        expect(text, isNot(contains(icon)),
            reason: '${file.path} uses decorative $icon');
      }
    }
  });

  test('player engine choices use icons for what they do', () {
    final settings =
        File('lib/screens/settings_screen.dart').readAsStringSync();
    expect(settings,
        contains("(PlayerEnginePreference.auto, 'Auto', Icons.alt_route_rounded)"));
    expect(settings, contains('icon: Icons.alt_route_rounded,'));
    expect(settings, contains('Icons.smart_display_rounded'));
  });

  test('rating stars stay', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final details = File('lib/screens/details_screen.dart').readAsStringSync();
    expect(home, contains("'★ \${item.rating!.toStringAsFixed(1)}'"));
    expect(details, contains("_MetaPill('★ \${item.rating!.toStringAsFixed(1)}')"));
  });
}
