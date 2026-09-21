import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/widgets/player_loading_overlay.dart';

void main() {
  testWidgets('shows title fallback, playback status and episode context',
      (tester) async {
    const item = MediaItem(
      id: 'tt14688458',
      kind: MediaKind.series,
      title: 'Silo',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayerLoadingOverlay(
            item: item,
            title: 'Silo • S01E01 Freedom Day',
            message: 'Starting playback…',
          ),
        ),
      ),
    );

    expect(find.text('Silo'), findsOneWidget);
    expect(find.text('Starting playback…'), findsOneWidget);
    expect(find.text('Silo • S01E01 Freedom Day'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
