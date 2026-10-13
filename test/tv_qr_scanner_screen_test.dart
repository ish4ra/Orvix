import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:orvix/screens/tv_qr_scanner_screen.dart';
import 'package:orvix/services/camera_permission_service.dart';

class _FakePermissions extends CameraPermissionGateway {
  _FakePermissions(this.current, {CameraAccess? afterRequest})
      : afterRequest = afterRequest ?? current;

  CameraAccess current;
  CameraAccess afterRequest;
  int requests = 0;
  int settingsOpens = 0;

  @override
  Future<CameraAccess> status() async => current;

  @override
  Future<CameraAccess> request() async {
    requests++;
    current = afterRequest;
    return current;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpens++;
    return true;
  }
}

class _FakeController extends MobileScannerController {
  _FakeController({this.error}) : super(autoStart: false);

  MobileScannerException? error;
  int starts = 0;

  @override
  Future<void> start({CameraFacing? cameraDirection}) async {
    starts++;
    final failure = error;
    if (failure != null) throw failure;
    value = value.copyWith(isInitialized: true, isRunning: true);
  }

  @override
  Future<void> stop() async {
    value = value.copyWith(isRunning: false);
  }

  @override
  Future<void> dispose() async {}
}

/// Hosts the scanner behind a button, like the Account screen does, and
/// records what it returns.
class _Host extends StatefulWidget {
  const _Host(this.permissions, this.controller);

  final _FakePermissions permissions;
  final _FakeController controller;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? result = 'none';
  void Function(BarcodeCapture)? detect;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final code = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => OrvixTvQrScannerScreen(
                      permissions: widget.permissions,
                      controllerFactory: () => widget.controller,
                      previewBuilder: (context, controller, onDetect) {
                        detect = onDetect;
                        return const ColoredBox(
                          key: ValueKey('fake-preview'),
                          color: Colors.black,
                        );
                      },
                    ),
                  ),
                );
                setState(() => result = code);
              },
              child: Text('open $result'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<_HostState> _open(
  WidgetTester tester,
  _FakePermissions permissions, {
  _FakeController? controller,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(_Host(permissions, controller ?? _FakeController()));
  await tester.tap(find.textContaining('open'));
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

BarcodeCapture _capture(String value) =>
    BarcodeCapture(barcodes: [Barcode(rawValue: value)]);

/// Nothing in the camera area may overlap the action panel.
void _expectNoOverlap(WidgetTester tester) {
  final actions = tester.getRect(find.byKey(const ValueKey('tv-qr-actions')));
  for (final finder in [
    find.byKey(const ValueKey('tv-qr-allow-camera')),
    find.byKey(const ValueKey('tv-qr-open-settings')),
    find.byKey(const ValueKey('tv-qr-retry-camera')),
    find.byKey(const ValueKey('tv-qr-scan-frame')),
  ]) {
    if (finder.evaluate().isEmpty) continue;
    final rect = tester.getRect(finder);
    expect(rect.overlaps(actions), isFalse, reason: '$finder overlaps');
  }
  final screen = tester.getRect(find.byType(OrvixTvQrScannerScreen));
  expect(screen.contains(actions.bottomRight - const Offset(1, 1)), isTrue,
      reason: 'The actions stay on screen');
}

void main() {
  testWidgets('permission granted: the camera starts and a QR code returns',
      (tester) async {
    final controller = _FakeController();
    final host =
        await _open(tester, _FakePermissions(CameraAccess.granted),
            controller: controller);
    expect(controller.starts, 1);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
    _expectNoOverlap(tester);

    // A QR code that is not an Orvix code is explained, not accepted.
    host.detect!(_capture('https://example.com/other'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not an Orvix TV code'), findsOneWidget);

    host.detect!(_capture(
        'https://abc.supabase.co/functions/v1/tv-login-link?code=ABC234'));
    // Frames repeat the same code; only the first one counts.
    host.detect!(_capture('ABC234'));
    await tester.pumpAndSettle();
    expect(find.text('open ABC234'), findsOneWidget);
  });

  testWidgets('first use explains, then asks only when the user taps',
      (tester) async {
    final permissions = _FakePermissions(CameraAccess.notRequested,
        afterRequest: CameraAccess.granted);
    final controller = _FakeController();
    await _open(tester, permissions, controller: controller);

    expect(find.text('Allow camera access'), findsOneWidget);
    expect(permissions.requests, 0, reason: 'No prompt without a tap');
    expect(controller.starts, 0);
    _expectNoOverlap(tester);

    await tester.tap(find.byKey(const ValueKey('tv-qr-allow-camera')));
    await tester.pumpAndSettle();
    expect(permissions.requests, 1);
    expect(controller.starts, 1);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
  });

  testWidgets('a denial can be retried; a permanent one opens settings',
      (tester) async {
    final permissions = _FakePermissions(CameraAccess.denied,
        afterRequest: CameraAccess.permanentlyDenied);
    await _open(tester, permissions);
    expect(find.text('Camera access is off'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tv-qr-allow-camera')));
    await tester.pumpAndSettle();
    expect(find.text('Camera access is blocked'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-allow-camera')), findsNothing,
        reason: 'Android will not show its prompt again');
    _expectNoOverlap(tester);

    await tester.tap(find.byKey(const ValueKey('tv-qr-open-settings')));
    await tester.pumpAndSettle();
    expect(permissions.settingsOpens, 1);

    // Back from Android settings with Camera allowed.
    permissions.current = CameraAccess.granted;
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
  });

  testWidgets('a scanner refusal is re-checked instead of a generic error',
      (tester) async {
    final permissions = _FakePermissions(CameraAccess.unknown);
    final controller = _FakeController(
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied),
    );
    await _open(tester, permissions, controller: controller);
    expect(find.text('Camera access is blocked'), findsOneWidget);
  });

  testWidgets('a camera failure offers a working retry', (tester) async {
    final controller = _FakeController(
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.genericError),
    );
    await _open(tester, _FakePermissions(CameraAccess.granted),
        controller: controller);
    expect(find.text('Could not start the camera scanner.'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsNothing,
        reason: 'The scan frame is never drawn over an error');
    _expectNoOverlap(tester);

    controller.error = null;
    await tester.tap(find.byKey(const ValueKey('tv-qr-retry-camera')));
    await tester.pumpAndSettle();
    expect(controller.starts, 2);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
  });

  testWidgets('no camera: manual entry still works', (tester) async {
    await _open(tester, _FakePermissions(CameraAccess.noCamera));
    expect(find.text('No camera available'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tv-qr-enter-code')));
    await tester.pumpAndSettle();
    final continueButton = find.byKey(const ValueKey('tv-code-continue'));
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull,
        reason: 'Continue waits for a full code');

    await tester.enterText(
        find.byKey(const ValueKey('tv-code-field')), 'abc-23');
    await tester.pump();
    expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);
    await tester.enterText(
        find.byKey(const ValueKey('tv-code-field')), 'abc-234');
    await tester.pump();
    expect(find.text('ABC-234'), findsOneWidget, reason: 'Shown in capitals');
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(find.text('open ABC234'), findsOneWidget);
  });

  testWidgets('manual entry is available without camera permission',
      (tester) async {
    final permissions = _FakePermissions(CameraAccess.notRequested);
    await _open(tester, permissions);
    await tester.tap(find.byKey(const ValueKey('tv-qr-enter-code')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-code-field')), findsOneWidget);
    expect(permissions.requests, 0);

    // Leaving the code page returns to the scanner unchanged.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Allow camera access'), findsOneWidget);
  });

  for (final state in [
    CameraAccess.granted,
    CameraAccess.notRequested,
    CameraAccess.permanentlyDenied,
  ]) {
    testWidgets('small phone with large text: no overlap ($state)',
        (tester) async {
      await _open(
        tester,
        _FakePermissions(state),
        size: const Size(320, 568),
        textScale: 1.6,
      );
      expect(tester.takeException(), isNull);
      _expectNoOverlap(tester);
    });
  }
}
