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
  _FakeController({this.error, this.reportInState = false})
      : super(autoStart: false);

  MobileScannerException? error;

  /// mobile_scanner 6.x does not throw from start(): it stores the failure in
  /// the controller state. When true, this fake does the same.
  bool reportInState;
  int starts = 0;

  @override
  Future<void> start({CameraFacing? cameraDirection}) async {
    starts++;
    final failure = error;
    if (failure != null) {
      if (!reportInState) throw failure;
      value =
          value.copyWith(isInitialized: true, isRunning: false, error: failure);
      return;
    }
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
  const _Host(this.permissions, this.controller, this.releases);

  final _FakePermissions permissions;
  final _FakeController controller;
  final List<int> releases;

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
                      releaseCamera: () async =>
                          widget.releases.add(widget.controller.starts),
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
  List<int>? releases,
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
      _Host(permissions, controller ?? _FakeController(), releases ?? []));
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
    final host = await _open(tester, _FakePermissions(CameraAccess.granted),
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
    expect(find.text('Grant camera access'), findsOneWidget);
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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
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

  testWidgets(
      'a start failure reported in the controller state is not shown as '
      'a running camera', (tester) async {
    // The real mobile_scanner 6.x start() returns normally on failure.
    final controller = _FakeController(
      reportInState: true,
      error: const MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(
            code: 'MOBILE_SCANNER_CAMERA_ERROR',
            message: 'An error occurred when opening the camera.'),
      ),
    );
    await _open(tester, _FakePermissions(CameraAccess.granted),
        controller: controller);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsNothing);
    expect(find.text('The camera service did not respond'), findsOneWidget);
    expect(find.text('Error: MOBILE_SCANNER_CAMERA_ERROR'), findsOneWidget);
    expect(find.textContaining('grant', findRichText: true), findsNothing,
        reason: 'A granted permission is never asked for again');
    expect(find.byKey(const ValueKey('tv-qr-failed-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-state-card')), findsOneWidget,
        reason: 'A compact card, not an empty preview frame');
    _expectNoOverlap(tester);
  });

  testWidgets('a camera still held by an old session is released on retry',
      (tester) async {
    final releases = <int>[];
    final controller = _FakeController(
      reportInState: true,
      error: const MobileScannerException(
        errorCode: MobileScannerErrorCode.controllerAlreadyInitialized,
      ),
    );
    await _open(tester, _FakePermissions(CameraAccess.granted),
        controller: controller, releases: releases);
    expect(releases, [0], reason: 'Released once before the first start');
    expect(find.text('The camera was still busy'), findsOneWidget);
    expect(find.text('Error: controllerAlreadyInitialized'), findsOneWidget);

    controller.error = null;
    await tester.tap(find.byKey(const ValueKey('tv-qr-retry-camera')));
    await tester.pumpAndSettle();
    expect(releases, [0, 1], reason: 'Released again before the retry');
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
  });

  testWidgets('repeated failures add a recovery hint; the code stays usable',
      (tester) async {
    final controller = _FakeController(
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.unsupported),
    );
    await _open(tester, _FakePermissions(CameraAccess.granted),
        controller: controller);
    expect(find.text('Android could not open the camera'), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-persistent-hint')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tv-qr-retry-camera')));
    await tester.pumpAndSettle();
    expect(controller.starts, 2, reason: 'Retry really starts again');
    expect(find.byKey(const ValueKey('tv-qr-persistent-hint')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tv-qr-enter-code')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tv-code-field')), findsOneWidget);
  });

  testWidgets('settings from a camera failure restart the camera on return',
      (tester) async {
    final permissions = _FakePermissions(CameraAccess.granted);
    final controller = _FakeController(
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.genericError),
    );
    await _open(tester, permissions, controller: controller);
    await tester.tap(find.byKey(const ValueKey('tv-qr-failed-settings')));
    await tester.pumpAndSettle();
    expect(permissions.settingsOpens, 1);

    controller.error = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(controller.starts, 2);
    expect(find.byKey(const ValueKey('tv-qr-scan-frame')), findsOneWidget);
  });

  testWidgets(
      'a refusal while Android reports permission granted is a camera '
      'failure, not a new permission prompt', (tester) async {
    final permissions = _FakePermissions(CameraAccess.granted);
    final controller = _FakeController(
      error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied),
    );
    await _open(tester, permissions, controller: controller);
    expect(find.byKey(const ValueKey('tv-qr-retry-camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('tv-qr-allow-camera')), findsNothing);
    expect(permissions.requests, 0);
  });

  test('start failures are classified by the scanner and native codes', () {
    MobileScannerException e(MobileScannerErrorCode code, [String? native]) =>
        MobileScannerException(
          errorCode: code,
          errorDetails:
              native == null ? null : MobileScannerErrorDetails(code: native),
        );
    expect(
        classifyCameraFailure(
            e(MobileScannerErrorCode.controllerAlreadyInitialized)),
        CameraStartFailure.stillHeld);
    expect(classifyCameraFailure(e(MobileScannerErrorCode.controllerDisposed)),
        CameraStartFailure.stillHeld);
    expect(
        classifyCameraFailure(e(MobileScannerErrorCode.unsupported,
            'MOBILE_SCANNER_NO_CAMERA_ERROR')),
        CameraStartFailure.bindFailed);
    expect(
        classifyCameraFailure(e(MobileScannerErrorCode.genericError,
            'MOBILE_SCANNER_CAMERA_ERROR')),
        CameraStartFailure.cameraService);
    expect(
        classifyCameraFailure(e(MobileScannerErrorCode.genericError,
            'MOBILE_SCANNER_CAMERA_PERMISSION_REQUEST_PENDING')),
        CameraStartFailure.permissionPromptOpen);
    expect(classifyCameraFailure(e(MobileScannerErrorCode.genericError)),
        CameraStartFailure.unexpected);
    expect(cameraFailureCode(e(MobileScannerErrorCode.genericError)),
        'genericError');
    expect(
        cameraFailureCode(e(MobileScannerErrorCode.genericError,
            'MOBILE_SCANNER_CAMERA_ERROR')),
        'MOBILE_SCANNER_CAMERA_ERROR');
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
