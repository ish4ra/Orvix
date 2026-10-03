import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android mobile Library follows Nuvio-style three-column grid', () {
    final library = File('lib/screens/media_library_screen.dart').readAsStringSync();
    expect(library, contains('final mobile = PlatformProfile.isAndroidMobile'));
    expect(library, contains('final count = mobile'));
    expect(library, contains('? 3'));
    expect(library, contains('crossAxisSpacing: mobile ? 12 : 18'));
    expect(library, contains('childAspectRatio: mobile ? .56 : .50'));
    expect(library, contains('compact: mobile'));
    expect(library, contains("label: Text('Movies')"));
    expect(library, contains("label: Text('TV')"));
  });
}
