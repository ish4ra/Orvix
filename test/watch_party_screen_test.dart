// The Watch Party screen: creating and joining a room, the lobby, host
// controls, chat, recovery messages, and Android TV remote navigation.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvix/models/media_item.dart';
import 'package:orvix/screens/watch_party_screen.dart';
import 'package:orvix/services/platform_profile.dart';
import 'package:orvix/services/watch_party/watch_party_feature.dart';
import 'package:orvix/services/watch_party/watch_party_models.dart';
import 'package:orvix/services/watch_party/watch_party_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/watch_party_fakes.dart';

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  Future<void> Function(MediaItem item)? onOpenMedia,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(useMaterial3: true),
    home: WatchPartyScreen(onOpenMedia: onOpenMedia),
  ));
  await _settle(tester);
}

/// Leaves the room and lets its timers finish, as the app does on exit.
Future<void> _finish(WidgetTester tester) async {
  await WatchPartyService.instance.leave();
  await tester.pump(const Duration(seconds: 2));
}

/// Taps a control, scrolling it into view first as a person would.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Types into a TV text field the way the remote does: OK starts typing.
Future<void> _tvType(WidgetTester tester, String key, String text) async {
  expect(_focusIn(tester, _key(key)), isTrue, reason: '$key has focus');
  await _press(tester, LogicalKeyboardKey.select);
  await tester.enterText(_key(key), text);
  await _settle(tester);
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

/// Whether the primary focus is [finder]'s widget or inside it.
bool _focusIn(WidgetTester tester, Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null || finder.evaluate().isEmpty) return false;
  final target = tester.element(finder);
  if (context == target) return true;
  var found = false;
  context.visitAncestorElements((ancestor) {
    if (ancestor == target) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  late FakeTime time;
  late FakeRoomBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WatchPartyFeature.debugOverride = true;
    await WatchPartyService.instance.leave();
    time = FakeTime();
    backend = FakeRoomBackend(time);
    WatchPartyService.instance.backend = backend;
  });

  tearDown(() {
    WatchPartyFeature.debugOverride = null;
    PlatformProfile.debugAndroidTvOverride = null;
  });

  group('creating and joining', () {
    testWidgets('without an account the screen asks to sign in',
        (tester) async {
      backend.signedIn = false;
      await _open(tester);
      expect(find.text('Sign in to use Watch Party'), findsOneWidget);
      expect(_key('watch-party-create'), findsNothing);
      expect(_key('watch-party-join'), findsNothing);
      expect(backend.calls, isEmpty);
    });

    testWidgets('creating a room opens the lobby with the invite code',
        (tester) async {
      backend.otherInRoom = false;
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await _tap(tester, _key('watch-party-create'));
      await _settle(tester);

      expect(backend.calls, contains('create'));
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(find.text('Me (you)'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Nothing yet'), findsOneWidget);
      expect(_key('watch-party-end'), findsOneWidget,
          reason: 'the host can end the room');
      expect(find.textContaining('1 of 10 people'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('the name is required and nothing is sent without it',
        (tester) async {
      await _open(tester);
      await _tap(tester, _key('watch-party-create'));
      await _settle(tester);
      expect(find.text(WatchPartyError.invalidName.message), findsOneWidget);
      expect(backend.calls, isEmpty);

      await tester.enterText(_key('watch-party-code'), 'ABCDEFGH');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
      expect(backend.calls, isEmpty);
    });

    testWidgets('a wrong or incomplete code explains itself', (tester) async {
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await tester.enterText(_key('watch-party-code'), 'ABCD');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
      expect(find.text(WatchPartyError.notFound.message), findsOneWidget);
      expect(backend.calls, isEmpty, reason: 'eight characters are needed');

      await tester.enterText(_key('watch-party-code'), 'ZZZZ-ZZZZ');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
      expect(backend.calls, ['join']);
      expect(find.text(WatchPartyError.notFound.message), findsOneWidget);
      expect(_key('watch-party-room-code'), findsNothing);
    });

    testWidgets('joining accepts the code as people type it', (tester) async {
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await tester.enterText(_key('watch-party-code'), 'abcd-efgh');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);

      expect(_key('watch-party-room-code'), findsOneWidget);
      expect(find.text('Friend'), findsOneWidget);
      expect(find.text('Me (you)'), findsOneWidget);
      expect(_key('watch-party-end'), findsNothing,
          reason: 'only the host can end the room');
      expect(find.byTooltip('Manage Friend'), findsNothing,
          reason: 'only the host manages people');
      await _finish(tester);
    });

    testWidgets('a full room, a removal and a rate limit are explained',
        (tester) async {
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await tester.enterText(_key('watch-party-code'), 'ABCDEFGH');
      for (final error in [
        WatchPartyError.roomFull,
        WatchPartyError.removed,
        WatchPartyError.rateLimited,
        WatchPartyError.network,
        WatchPartyError.unavailable,
      ]) {
        backend.failNext = error;
        await _tap(tester, _key('watch-party-join'));
        await _settle(tester);
        expect(find.text(error.message), findsOneWidget, reason: error.name);
        expect(_key('watch-party-room-code'), findsNothing);
      }
      // The form still works afterwards.
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
      expect(_key('watch-party-room-code'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('with the feature off nothing reaches the backend',
        (tester) async {
      WatchPartyFeature.debugOverride = false;
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await _tap(tester, _key('watch-party-create'));
      await _settle(tester);
      expect(find.text(WatchPartyError.unavailable.message), findsOneWidget);
      expect(backend.calls, isEmpty);
      expect(WatchPartyService.instance.session.value, isNull);
    });

    testWidgets('the last name used is offered again', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'orvix_watch_party_name_v1': 'Nimal'});
      await _open(tester);
      expect(find.text('Nimal'), findsOneWidget);
    });
  });

  group('lobby', () {
    Future<void> join(WidgetTester tester,
        {Future<void> Function(MediaItem)? onOpenMedia,
        Size size = const Size(1280, 800)}) async {
      await _open(tester, onOpenMedia: onOpenMedia, size: size);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await tester.enterText(_key('watch-party-code'), 'ABCDEFGH');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
    }

    testWidgets('shows the room title once the host picks one and opens it',
        (tester) async {
      MediaItem? opened;
      await join(tester, onOpenMedia: (item) async => opened = item);
      expect(find.text('Nothing yet'), findsOneWidget);
      expect(_key('watch-party-open-title'), findsNothing);
      expect(find.textContaining('has not picked a title'), findsOneWidget);

      backend.media = secondEpisode;
      backend.remoteState(playing: true, positionMs: 60000);
      await _settle(tester);
      expect(find.text('Breaking Bad · S01E02'), findsOneWidget);
      expect(find.textContaining('choose S01E02'), findsOneWidget);

      await _tap(tester, _key('watch-party-open-title'));
      await _settle(tester);
      expect(opened!.id, 'tt0903747');
      expect(opened!.kind, MediaKind.series);
      await _finish(tester);
    });

    testWidgets('shows who is ready, buffering or offline', (tester) async {
      backend.extras.addAll(const [
        WatchPartyParticipant(id: 'p-3', name: 'Kasun', buffering: true),
        WatchPartyParticipant(id: 'p-4', name: 'Ama', online: false),
        WatchPartyParticipant(id: 'p-5', name: 'Ravi'),
      ]);
      backend.media = inception;
      await join(tester);

      expect(find.text('Ready'), findsOneWidget, reason: 'the host');
      expect(find.text('Buffering'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Choosing a source'), findsNWidgets(2),
          reason: 'this device and Ravi have no player open');
      expect(find.textContaining('5 of 10 people'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('connection trouble is shown and clears', (tester) async {
      await join(tester);
      backend.channel.setConnected(true);
      await _settle(tester);
      expect(find.textContaining('Connected ·'), findsOneWidget);

      backend.offline = true;
      await tester.pump(const Duration(seconds: 16));
      await _settle(tester);
      expect(find.textContaining('Reconnecting…'), findsOneWidget);

      backend.offline = false;
      await tester.pump(const Duration(seconds: 40));
      await _settle(tester);
      expect(find.textContaining('Connected ·'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('leaving asks first and returns to the start', (tester) async {
      await join(tester);
      await _tap(tester, _key('watch-party-leave'));
      await _settle(tester);
      expect(find.text('Leave the room?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(_key('watch-party-room-code'), findsOneWidget);

      await _tap(tester, _key('watch-party-leave'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Leave'));
      await _settle(tester);
      expect(backend.calls, contains('leave'));
      expect(_key('watch-party-room-code'), findsNothing);
      expect(_key('watch-party-create'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a room ended by the host says so', (tester) async {
      await join(tester);
      backend.channel.emit(const WatchPartyClosedEvent('host'));
      await _settle(tester);
      expect(find.text('The room was ended.'), findsOneWidget);
      expect(_key('watch-party-create'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('being removed says so', (tester) async {
      await join(tester);
      backend.failNext = WatchPartyError.removed;
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(find.text('The host removed you from the room.'), findsOneWidget);
      expect(_key('watch-party-room-code'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('fits a phone screen with a full room', (tester) async {
      backend.extras.addAll([
        for (var i = 3; i <= 10; i++)
          WatchPartyParticipant(
            id: 'p-$i',
            name: 'A rather long display name $i'.substring(0, 24),
          ),
      ]);
      backend.media = const WatchPartyMedia(
        kind: MediaKind.series,
        id: 'tt0903747',
        season: 12,
        episode: 104,
        title:
            'A Series With An Unreasonably Long Title That Goes On And On Forever',
      );
      await join(tester, size: const Size(360, 640));
      expect(find.textContaining('10 of 10 people'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, -900));
      await _settle(tester);
      expect(_key('watch-party-chat-input'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('host controls', () {
    Future<void> create(WidgetTester tester) async {
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await _tap(tester, _key('watch-party-create'));
      await _settle(tester);
    }

    testWidgets('the host can remove someone, after confirming',
        (tester) async {
      await create(tester);
      await tester.tap(find.byTooltip('Manage Friend'));
      await _settle(tester);
      await tester.tap(find.text('Remove Friend'));
      await _settle(tester);
      expect(find.text('Remove Friend?'), findsOneWidget);
      expect(backend.calls, isNot(contains('remove')));

      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _settle(tester);
      expect(backend.calls, contains('remove'));
      expect(find.text('Friend'), findsNothing);
      expect(WatchPartyService.instance.session.value!.room.topic,
          isNot('watch_party:key-1'),
          reason: 'the room moved to a new topic');
      await _finish(tester);
    });

    testWidgets('the host can hand the room to someone else', (tester) async {
      await create(tester);
      await tester.tap(find.byTooltip('Manage Friend'));
      await _settle(tester);
      await tester.tap(find.text('Make Friend the host'));
      await _settle(tester);

      expect(backend.calls, contains('transfer'));
      expect(_key('watch-party-end'), findsNothing,
          reason: 'no longer the host');
      expect(find.byTooltip('Manage Friend'), findsNothing);
      await _finish(tester);
    });

    testWidgets('ending the room asks first', (tester) async {
      await create(tester);
      await _tap(tester, _key('watch-party-end'));
      await _settle(tester);
      expect(find.text('End the room for everyone?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'End room'));
      await _settle(tester);
      expect(backend.calls, contains('close'));
      expect(_key('watch-party-create'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a refused host action is reported', (tester) async {
      await create(tester);
      backend.failing['transfer'] = WatchPartyError.invalidParticipant;
      await tester.tap(find.byTooltip('Manage Friend'));
      await _settle(tester);
      await tester.tap(find.text('Make Friend the host'));
      await _settle(tester);
      expect(find.text(WatchPartyError.invalidParticipant.message),
          findsOneWidget);
      expect(_key('watch-party-end'), findsOneWidget, reason: 'still the host');
      await _finish(tester);
    });
  });

  group('chat', () {
    Future<void> join(WidgetTester tester) async {
      await _open(tester);
      await tester.enterText(_key('watch-party-name'), 'Sam');
      await tester.enterText(_key('watch-party-code'), 'ABCDEFGH');
      await _tap(tester, _key('watch-party-join'));
      await _settle(tester);
    }

    testWidgets('messages are sent, shown in order and the box is cleared',
        (tester) async {
      await join(tester);
      expect(find.text('No messages yet. Say hello.'), findsOneWidget);

      await tester.enterText(_key('watch-party-chat-input'), '  hello  ');
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);
      expect(backend.chat.single.body, 'hello');
      expect(find.text('hello'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(_key('watch-party-chat-input'))
            .controller!
            .text,
        isEmpty,
      );

      backend.remoteChat('hi Sam');
      await _settle(tester);
      expect(find.text('hi Sam'), findsOneWidget);
      expect(find.text('Friend'), findsNWidgets(2),
          reason: 'in the roster and above their message');

      // Newest at the bottom.
      expect(tester.getTopLeft(find.text('hi Sam')).dy,
          greaterThan(tester.getTopLeft(find.text('hello')).dy));
      await _finish(tester);
    });

    testWidgets('an empty message is not sent', (tester) async {
      await join(tester);
      await tester.enterText(_key('watch-party-chat-input'), '   ');
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);
      expect(backend.calls, isNot(contains('sendMessage')));
      await _finish(tester);
    });

    testWidgets('a message that fails stays in the box with the reason',
        (tester) async {
      await join(tester);
      backend.failing['sendMessage'] = WatchPartyError.rateLimited;
      await tester.enterText(_key('watch-party-chat-input'), 'too fast');
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);

      expect(_key('watch-party-chat-error'), findsOneWidget);
      expect(find.text(WatchPartyError.rateLimited.message), findsOneWidget);
      expect(
        tester
            .widget<TextField>(_key('watch-party-chat-input'))
            .controller!
            .text,
        'too fast',
      );
      expect(backend.chat, isEmpty);

      backend.failing.clear();
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);
      expect(backend.chat.single.body, 'too fast');
      expect(_key('watch-party-chat-error'), findsNothing);
      await _finish(tester);
    });

    testWidgets('a message lost on the way is sent once, not twice',
        (tester) async {
      await join(tester);
      backend.failNext = WatchPartyError.network;
      await tester.enterText(_key('watch-party-chat-input'), 'once');
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);
      expect(backend.chat.length, 1);
      expect(backend.calls.where((c) => c == 'sendMessage').length, 2,
          reason: 'retried with the same message id');
      expect(find.text('once'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('typing faster than the room allows is stopped locally',
        (tester) async {
      await join(tester);
      for (var i = 1; i <= 8; i++) {
        await tester.enterText(_key('watch-party-chat-input'), 'message $i');
        await _tap(tester, _key('watch-party-chat-send'));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.enterText(_key('watch-party-chat-input'), 'message 9');
      await _tap(tester, _key('watch-party-chat-send'));
      await _settle(tester);
      expect(backend.chat.length, 8);
      expect(find.textContaining('too fast'), findsOneWidget);
      await _finish(tester);
    });
  });

  group('Android TV', () {
    setUp(() => PlatformProfile.debugAndroidTvOverride = true);

    Future<void> openTv(WidgetTester tester,
        {Future<void> Function(MediaItem)? onOpenMedia}) async {
      await _open(tester, size: const Size(960, 540), onOpenMedia: onOpenMedia);
    }

    /// Fills in the form and joins, using only the remote.
    Future<void> joinTv(WidgetTester tester) async {
      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _tvType(tester, 'watch-party-name', 'Sam');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      await _tvType(tester, 'watch-party-code', 'abcd efgh');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-join')), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
    }

    testWidgets('the start screen is fully reachable with the remote',
        (tester) async {
      await openTv(tester);
      expect(_focusIn(tester, _key('watch-party-create')), isTrue,
          reason: 'focus starts on Create room');

      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-code')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-join')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-join')), isTrue,
          reason: 'focus stops at the last control');

      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusIn(tester, _key('watch-party-name')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusIn(tester, _key('watch-party-name')), isTrue);
    });

    testWidgets('OK on Create room creates the room and focus stays alive',
        (tester) async {
      backend.otherInRoom = false;
      await openTv(tester);
      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _tvType(tester, 'watch-party-name', 'Sam');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-create')), isTrue);
      await _press(tester, LogicalKeyboardKey.select);

      expect(backend.calls, contains('create'));
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(_focusIn(tester, _key('watch-party-leave')), isTrue,
          reason: 'with no title yet, focus lands on Leave room');
      await _finish(tester);
    });

    testWidgets('errors are shown on the TV start screen', (tester) async {
      await openTv(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text(WatchPartyError.invalidName.message), findsOneWidget);
      expect(_focusIn(tester, _key('watch-party-create')), isTrue,
          reason: 'focus is not lost by an error');
    });

    testWidgets('the lobby is navigable: title, people, actions and chat',
        (tester) async {
      MediaItem? opened;
      backend.selfIsHost = true;
      backend.media = inception;
      backend.extras.add(const WatchPartyParticipant(id: 'p-3', name: 'Kasun'));
      await openTv(tester, onOpenMedia: (item) async => opened = item);
      await joinTv(tester);

      expect(_focusIn(tester, _key('watch-party-open-title')), isTrue,
          reason: 'focus lands on the main action');
      await _press(tester, LogicalKeyboardKey.select);
      expect(opened!.id, 'tt1375666');

      // Down through the people to the room actions.
      // Every person can be focused, so a long room scrolls with the remote.
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-person-p-self')), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Remove Me'), findsNothing,
          reason: 'the host cannot act on themselves');
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-person-p-other')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-person-p-3')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(tester, _key('watch-party-leave')), isTrue);

      // Right from anywhere in the room column reaches the chat box, and
      // Left comes back to the same control.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusIn(tester, _key('watch-party-person-p-3')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusIn(tester, _key('watch-party-chat-input')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusIn(tester, _key('watch-party-chat-send')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusIn(tester, _key('watch-party-chat-input')), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusIn(tester, _key('watch-party-person-p-3')), isTrue);

      // A message can be written and sent with the remote alone.
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _tvType(tester, 'watch-party-chat-input', 'from the sofa');
      // While typing, Left moves the caret instead of leaving the box.
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusIn(tester, _key('watch-party-chat-input')), isTrue);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester);
      expect(backend.chat.single.body, 'from the sofa');
      expect(find.text('from the sofa'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('OK on a person opens the host menu and Back closes it',
        (tester) async {
      backend.selfIsHost = true;
      await openTv(tester);
      await joinTv(tester);

      // No title yet: focus is on Leave room, one step below the person.
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusIn(tester, _key('watch-party-person-p-other')), isTrue);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.text('Make Friend the host'), findsOneWidget);
      expect(find.text('Remove Friend'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.text('Remove Friend'), findsNothing);
      expect(backend.calls, isNot(contains('remove')));
      expect(_key('watch-party-room-code'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a full room fits the TV screen', (tester) async {
      backend.media = inception;
      backend.extras.addAll([
        for (var i = 3; i <= 10; i++)
          WatchPartyParticipant(id: 'p-$i', name: 'Participant number $i'),
      ]);
      for (var i = 0; i < 30; i++) {
        backend.remoteChat(
          'A fairly long chat message number $i that should wrap inside '
          'the chat column without overflowing',
          announce: false,
        );
      }
      await openTv(tester);
      await joinTv(tester);
      expect(find.textContaining('10 of 10 people'), findsOneWidget);
      expect(_key('watch-party-chat-list'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('signed out, focus rests on Back', (tester) async {
      backend.signedIn = false;
      await openTv(tester);
      expect(find.text('Sign in to use Watch Party'), findsOneWidget);
      expect(_focusIn(tester, _key('watch-party-back')), isTrue);
    });
  });
}
