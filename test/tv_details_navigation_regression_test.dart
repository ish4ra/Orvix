import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TV season and episode rails keep focused items visible', () {
    final source = File('lib/screens/details_screen.dart').readAsStringSync();
    final tvRail = source.substring(
      source.indexOf('Widget _tvEpisodeRail'),
      source.indexOf('Widget _tvFactsSection'),
    );
    expect(tvRail, contains('FocusTraversalGroup'));
    expect(source, contains('Scrollable.ensureVisible(context'));
  });

  test('TV details back action uses navigator pop instead of replacement', () {
    final source = File('lib/screens/details_screen.dart').readAsStringSync();
    final layout = source.substring(
      source.indexOf('Widget _tvDetailsLayout'),
      source.indexOf('ButtonStyle _tvGlowButtonStyle'),
    );
    expect(layout, contains('Navigator.of(context).pop()'));
    expect(layout, isNot(contains('pushReplacement')));
  });
}
