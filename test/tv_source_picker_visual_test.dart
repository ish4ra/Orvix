// Android TV source picker with real fonts at 720p, 1080p and 4K logical
// sizes, 61 sources and long titles: nothing may overflow, every control
// stays reachable, and ORVIX_CAPTURE_DIR receives screenshots.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/tv_source_browser_screen.dart';
import 'package:orvix/services/source_provider_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/tv_visual.dart';

class _Sources extends SourceProviderService {
  @override
  Future<void> prefetch(MediaItem item, {EpisodeItem? episode}) async {}
}

const _show = MediaItem(
  id: 'tt0903747',
  kind: MediaKind.series,
  title: 'Breaking Bad',
  year: '2008',
);
const _episode = EpisodeItem(
  id: 'tt0903747:1:1',
  season: 1,
  episode: 1,
  title: 'Pilot',
);

String _stats(String type, String quality, int seeds, String size) =>
    '🎞 $type  •  📺 $quality  •  👥 $seeds seeders  •  💾 $size';

List<SourceResult> _results() {
  const releases = [
    ('BluRay', '1080P', 72, 4.09, 'Breaking Bad S01 Complete - 1080p ENG-ITA Multisub x264 BluRay • Ep 01 - Pilot - Questione di Chimica'),
    ('BluRay', null, 38, 1.74, 'Во все тяжкие / Breaking Bad / Сезон: 1 / Серии 1-7 (7) [2008 BDRip-AVC] MVO (LostFilm) + Original'),
    ('BluRay', '1080P', 391, 2.56, 'Breaking.Bad.S01E01.Pilot.1080p.BluRay.x265.10bit.AAC.5.1-GROUP'),
    ('WEB-DL', '2160P', 120, 9.8, 'Breaking.Bad.S01E01.2160p.NF.WEB-DL.DDP5.1.AV1-FLUX'),
    ('WEB-DL', '720P', 54, 0.9, 'Breaking.Bad.S01E01.720p.WEB-DL.AAC2.0.H.264'),
  ];
  return [
    for (var i = 0; i < 61; i++)
      () {
        final r = releases[i % releases.length];
        final size = (r.$4 * 1024 * 1024 * 1024).round();
        return SourceResult(
          provider: 'Torrentio',
          title: '${_stats(r.$1, r.$2 ?? '—', r.$3, '${r.$4} GB')}\n${r.$5}'
              '${i >= releases.length ? ' [$i]' : ''}',
          resource: 'magnet:?xt=urn:btih:${i.toRadixString(16).padLeft(40, 'a')}',
          isMagnet: true,
          sortMode: SourceSortMode.quality,
          quality: r.$2,
          releaseQuality: r.$1,
          seeders: r.$3 - (i ~/ 5),
          sizeBytes: size,
          fileNameHint: r.$5,
        );
      }(),
  ];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in tvCanvases.entries) {
    for (final free in [true, false]) {
      testWidgets(
          'source picker ${entry.key} ${free ? 'Free P2P' : 'Default'}: '
          'real fonts, no overflow', (tester) async {
        if (!await loadTvFonts()) {
          markTestSkipped('Flutter SDK fonts not found');
          return;
        }
        setTvCanvas(tester, entry.value);
        await tester.pumpWidget(MaterialApp(
          theme: tvVisualTheme(),
          darkTheme: tvVisualTheme(),
          themeMode: ThemeMode.dark,
          home: tvCaptureFrame(TvSourceBrowserScreen(
            sources: _Sources(),
            item: _show,
            episode: _episode,
            resultsFuture: Future.value(_results()),
            preferFreeP2p: free,
          )),
        ));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(tester.takeException(), isNull);
        expect(find.text('Choose source'), findsOneWidget);
        expect(find.text('61 sources'), findsOneWidget);
        // The stats line is shown as structured facts, not repeated.
        expect(find.textContaining('👥'), findsNothing);
        await captureTv(
            tester, 'source-picker-${entry.key}-${free ? 'free' : 'default'}');

        if (entry.key == '1080p' && free) {
          // Up from the first source reaches the provider tabs, then the
          // mode controls; Back stays reachable.
          for (var press = 0; press < 2; press++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
          }
          await captureTv(tester, 'source-picker-1080p-focus-controls');
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('large text (1.3x) at 1080p stays readable without overflow',
      (tester) async {
    if (!await loadTvFonts()) {
      markTestSkipped('Flutter SDK fonts not found');
      return;
    }
    setTvCanvas(tester, tvCanvases['1080p']!);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
      theme: tvVisualTheme(),
      home: tvCaptureFrame(TvSourceBrowserScreen(
        sources: _Sources(),
        item: _show,
        episode: _episode,
        resultsFuture: Future.value(_results()),
      )),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    await captureTv(tester, 'source-picker-1080p-text-1.3');
  });

  testWidgets('every control works from the remote', (tester) async {
    if (!await loadTvFonts()) {
      markTestSkipped('Flutter SDK fonts not found');
      return;
    }
    setTvCanvas(tester, tvCanvases['1080p']!);
    await tester.pumpWidget(MaterialApp(
      theme: tvVisualTheme(),
      home: TvSourceBrowserScreen(
        sources: _Sources(),
        item: _show,
        episode: _episode,
        resultsFuture: Future.value(_results()),
      ),
    ));
    Future<void> key(LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    String? focusedLabel() {
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus == null) return null;
      String? label;
      focus.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is Semantics && widget.properties.label != null) {
          label = widget.properties.label;
          return false;
        }
        return true;
      });
      return label;
    }

    expect(find.text('Re-check live'), findsOneWidget);
    // Up twice: provider tabs, then the mode segments.
    await key(LogicalKeyboardKey.arrowUp);
    await key(LogicalKeyboardKey.arrowUp);
    final modes = ['Free P2P', 'Smooth', 'Default'];
    expect(modes, contains(focusedLabel()));
    // Right until Default, then OK selects it.
    while (focusedLabel() != 'Default') {
      await key(LogicalKeyboardKey.arrowRight);
    }
    await key(LogicalKeyboardKey.select);
    expect(find.text('Re-check live'), findsNothing,
        reason: 'Re-check live belongs to Free P2P mode');
    expect(focusedLabel(), 'Default', reason: 'Focus stays on the control');

    // Right to Compatible only; OK filters the list and the count says so.
    while (focusedLabel() != 'Compatible only') {
      await key(LogicalKeyboardKey.arrowRight);
    }
    await key(LogicalKeyboardKey.select);
    expect(find.textContaining('of 61 sources'), findsOneWidget);
    await key(LogicalKeyboardKey.select);
    expect(find.text('61 sources'), findsOneWidget);

    // Up from the controls reaches Back and Refresh.
    await key(LogicalKeyboardKey.arrowUp);
    expect(['Back', 'Refresh'], contains(focusedLabel()));
    expect(tester.takeException(), isNull);
  });

  test('release names drop the duplicated stats line', () {
    expect(
      tvSourceReleaseName('${_stats('BluRay', '1080P', 5, '1 GB')}\nName.1080p'),
      'Name.1080p',
    );
    expect(tvSourceReleaseName('Plain.Title'), 'Plain.Title');
    expect(tvSourceReleaseName('Line one\nLine two'), 'Line one • Line two');
  });

  test('quality labels', () {
    SourceResult q(String? quality, [String? release]) => SourceResult(
          provider: 'p',
          title: 't',
          resource: 'r',
          isMagnet: true,
          sortMode: SourceSortMode.quality,
          quality: quality,
          releaseQuality: release,
        );
    expect(tvSourceQualityLabel(q('2160P')), '4K');
    expect(tvSourceQualityLabel(q('4K')), '4K');
    expect(tvSourceQualityLabel(q('1080P')), '1080p');
    expect(tvSourceQualityLabel(q('720p')), '720p');
    expect(tvSourceQualityLabel(q(null, 'BluRay')), 'BLURAY');
    expect(tvSourceQualityLabel(q(null)), '—');
  });
}
