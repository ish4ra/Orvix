// Real-font layout checks and screenshot capture for Android TV screens.
//
// Widget tests normally draw every glyph with the square Ahem test font, so
// they cannot show what a screen really looks like or whether a label fits.
// These helpers load Roboto and the Material icon font that ship with the
// Flutter SDK. Set ORVIX_CAPTURE_DIR to also write PNG screenshots.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android TV logical canvases: a 720p panel at 1x, a 1080p panel at 2x
/// (what most TVs report) and a 4K panel at 2x.
const tvCanvases = <String, Size>{
  '720p': Size(1280, 720),
  '1080p': Size(960, 540),
  '4k': Size(1920, 1080),
};

bool _fontsLoaded = false;

/// Loads Roboto and the Material icons from the Flutter SDK. Returns false
/// when the SDK fonts cannot be found; real-font checks are then skipped.
Future<bool> loadTvFonts() async {
  if (_fontsLoaded) return true;
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return false;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return false;
  final roboto = FontLoader('Roboto');
  for (final file in dir.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (name.startsWith('Roboto-') && name.endsWith('.ttf')) {
      final bytes = file.readAsBytesSync();
      roboto.addFont(Future.value(ByteData.sublistView(bytes)));
    }
  }
  await roboto.load();
  final icons = File('${dir.path}/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  _fontsLoaded = true;
  return true;
}

/// The app's dark theme essentials with the real font.
ThemeData tvVisualTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Roboto',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFB9FF45),
        brightness: Brightness.dark,
        primary: const Color(0xFFB9FF45),
      ),
      scaffoldBackgroundColor: const Color(0xFF050806),
    );

void setTvCanvas(WidgetTester tester, Size logical, {double ratio = 1}) {
  tester.view.physicalSize = logical * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
}

/// Wraps [child] so it can be captured.
const tvCaptureKey = ValueKey('tv-visual-capture');

Widget tvCaptureFrame(Widget child) =>
    RepaintBoundary(key: tvCaptureKey, child: child);

/// Writes a PNG of the frame when ORVIX_CAPTURE_DIR is set.
Future<void> captureTv(WidgetTester tester, String name) async {
  final dirPath = Platform.environment['ORVIX_CAPTURE_DIR'];
  if (dirPath == null || dirPath.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(tvCaptureKey));
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(dirPath)..createSync(recursive: true);
    File('${dir.path}/$name.png')
        .writeAsBytesSync(data!.buffer.asUint8List());
  });
}
