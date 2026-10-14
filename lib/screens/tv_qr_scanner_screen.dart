import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
// The method-channel implementation is the only way to force-release a camera
// session that the Dart side no longer tracks; mobile_scanner's own widget
// does the same after a hot restart.
// ignore: implementation_imports
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart';

import '../services/camera_permission_service.dart';
import '../services/tv_device_login_service.dart';

const _lime = Color(0xFFB9FF45);
const _limeLight = Color(0xFFCBFF75);
const _surface = Color(0xFF0B0F0C);
const _card = Color(0xFF0D120E);
const _border = Color(0xFF263827);
const _muted = Color(0xFFAEB7B0);

enum _ScanState {
  /// Reading the permission state.
  checking,

  /// Permission never asked: explain why, then ask.
  explain,

  /// Denied; Android can still show its prompt.
  denied,

  /// Denied permanently; only app settings can allow it.
  blocked,
  noCamera,
  starting,
  running,
  failed,
}

/// Why the camera did not start although the permission allows it.
enum CameraStartFailure {
  /// An earlier scanner session still held the camera
  /// (MOBILE_SCANNER_ALREADY_STARTED_ERROR or a disposed controller).
  stillHeld,

  /// CameraX could not bind the back camera (mobile_scanner reports this as
  /// MOBILE_SCANNER_NO_CAMERA_ERROR): another app holds it, or the phone has
  /// no usable back camera.
  bindFailed,

  /// Android's camera service did not provide a camera
  /// (MOBILE_SCANNER_CAMERA_ERROR).
  cameraService,

  /// Another camera permission prompt was still open.
  permissionPromptOpen,

  /// Anything else the scanner reported.
  unexpected,
}

/// Classifies a mobile_scanner start failure that is not a permission refusal.
CameraStartFailure classifyCameraFailure(MobileScannerException error) {
  final nativeCode = error.errorDetails?.code ?? '';
  return switch (error.errorCode) {
    MobileScannerErrorCode.controllerAlreadyInitialized ||
    MobileScannerErrorCode.controllerDisposed =>
      CameraStartFailure.stillHeld,
    MobileScannerErrorCode.unsupported => CameraStartFailure.bindFailed,
    _ when nativeCode == 'MOBILE_SCANNER_CAMERA_ERROR' =>
      CameraStartFailure.cameraService,
    _ when nativeCode == 'MOBILE_SCANNER_CAMERA_PERMISSION_REQUEST_PENDING' =>
      CameraStartFailure.permissionPromptOpen,
    _ => CameraStartFailure.unexpected,
  };
}

/// A short technical code for a start failure, safe to show and report.
String cameraFailureCode(MobileScannerException error) {
  final nativeCode = error.errorDetails?.code;
  if (nativeCode != null && nativeCode.isNotEmpty) return nativeCode;
  return error.errorCode.name;
}

/// Stops any camera session mobile_scanner's Android side still holds, even
/// one the Dart side lost track of. Without this, a session left running (for
/// example by leaving the scanner while the camera was still opening) makes
/// every later start fail with "already started", and retrying cannot help.
Future<void> forceReleaseScannerCamera() async {
  final platform = MobileScannerPlatform.instance;
  if (platform is! MethodChannelMobileScanner) return;
  try {
    await platform.stop(force: true);
  } catch (_) {
    // Nothing was running, or the plugin is detached: nothing to release.
  }
}

/// The phone's "Scan TV QR" screen. Pops with the normalized six-character
/// TV code, from a scanned QR code or typed by hand.
///
/// While the camera runs, the preview fills a framed area above a fixed
/// action panel. Every other state is a compact card, so controls never
/// overlap the preview or the text, with or without a camera.
class OrvixTvQrScannerScreen extends StatefulWidget {
  const OrvixTvQrScannerScreen({
    super.key,
    this.permissions = const CameraPermissionGateway(),
    this.controllerFactory,
    this.previewBuilder,
    this.releaseCamera = forceReleaseScannerCamera,
  });

  final CameraPermissionGateway permissions;

  /// For tests: replaces the camera controller.
  @visibleForTesting
  final MobileScannerController Function()? controllerFactory;

  /// For tests: replaces the camera preview widget.
  @visibleForTesting
  final Widget Function(
    BuildContext context,
    MobileScannerController controller,
    void Function(BarcodeCapture capture) onDetect,
  )? previewBuilder;

  /// Releases a stale native camera session before a (re)start.
  final Future<void> Function() releaseCamera;

  @override
  State<OrvixTvQrScannerScreen> createState() => _OrvixTvQrScannerScreenState();
}

class _OrvixTvQrScannerScreenState extends State<OrvixTvQrScannerScreen>
    with WidgetsBindingObserver {
  late MobileScannerController _scannerController = _newController();
  int _scannerGeneration = 0;
  final _scanGate = TvQrScanGate();
  _ScanState _state = _ScanState.checking;
  MobileScannerException? _failure;
  int _failedStarts = 0;
  bool _manualEntryOpen = false;
  bool _cameraStarting = false;
  bool _permissionBusy = false;
  bool _showInvalidHint = false;

  /// Release any stale native session before the next start: on the first
  /// start of this screen and after every failure.
  bool _releaseBeforeStart = true;

  /// Set when the user went to Android settings, so the return re-checks the
  /// permission and restarts the camera.
  bool _settingsOpened = false;

  MobileScannerController _newController() =>
      widget.controllerFactory?.call() ??
      MobileScannerController(autoStart: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
  }

  void _setState(_ScanState state) {
    if (mounted && _state != state) setState(() => _state = state);
  }

  /// Reads the permission state and starts the camera when it is allowed.
  Future<void> _prepare() async {
    if (_permissionBusy || !mounted) return;
    _permissionBusy = true;
    try {
      final access = await widget.permissions.status();
      if (!mounted) return;
      await _apply(access);
    } finally {
      _permissionBusy = false;
    }
  }

  Future<void> _apply(CameraAccess access) async {
    switch (access) {
      case CameraAccess.granted:
      case CameraAccess.unknown:
        // Unknown: mobile_scanner asks for the permission itself.
        await _startCamera();
      case CameraAccess.notRequested:
        _setState(_ScanState.explain);
      case CameraAccess.denied:
        _setState(_ScanState.denied);
      case CameraAccess.permanentlyDenied:
        _setState(_ScanState.blocked);
      case CameraAccess.noCamera:
        _setState(_ScanState.noCamera);
    }
  }

  /// "Grant camera access": shows Android's prompt, only when the user asks.
  Future<void> _requestAccess() async {
    if (_permissionBusy) return;
    _permissionBusy = true;
    _setState(_ScanState.checking);
    try {
      final access = await widget.permissions.request();
      if (!mounted) return;
      await _apply(access);
    } finally {
      _permissionBusy = false;
    }
  }

  Future<void> _openSettings() async {
    final opened = await widget.permissions.openSettings();
    _settingsOpened = opened;
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text(
          'Could not open Android settings. Open Settings › Apps › Orvix › '
          'Permissions and allow Camera.',
        ),
      ));
    }
    // The state is read again when Orvix returns to the foreground.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_state == _ScanState.running || _state == _ScanState.starting) {
          unawaited(_startCamera());
        } else if (_state == _ScanState.blocked ||
            _state == _ScanState.denied ||
            _state == _ScanState.explain) {
          // Back from Android settings (or a prompt): check again.
          unawaited(_prepare());
        } else if (_state == _ScanState.failed && _settingsOpened) {
          // Back from app settings after a camera failure: start fresh.
          _settingsOpened = false;
          unawaited(_retryCamera());
        }
        break;
      case AppLifecycleState.inactive:
        unawaited(_stopCamera());
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _startCamera() async {
    if (!mounted || _cameraStarting) return;
    if (_scannerController.value.isRunning) {
      _setState(_ScanState.running);
      return;
    }
    _cameraStarting = true;
    _setState(_ScanState.starting);
    try {
      if (_releaseBeforeStart) {
        _releaseBeforeStart = false;
        await widget.releaseCamera();
        if (!mounted) return;
      }
      await _scannerController.start();
      if (!mounted) return;
      // mobile_scanner 6 does not throw when the camera fails to start: it
      // stores the failure in the controller state. Read it here instead of
      // reporting a camera that never started as running.
      final error = _scannerController.value.error;
      if (error != null) {
        await _handleCameraError(error);
        return;
      }
      if (!_scannerController.value.isRunning) {
        await _handleCameraError(const MobileScannerException(
          errorCode: MobileScannerErrorCode.genericError,
          errorDetails: MobileScannerErrorDetails(
            message: 'The camera did not report that it started.',
          ),
        ));
        return;
      }
      _failure = null;
      _failedStarts = 0;
      _setState(_ScanState.running);
    } on MobileScannerException catch (error) {
      if (!mounted) return;
      await _handleCameraError(error);
    } catch (error) {
      if (!mounted) return;
      await _handleCameraError(MobileScannerException(
        errorCode: MobileScannerErrorCode.genericError,
        errorDetails: MobileScannerErrorDetails(message: '$error'),
      ));
    } finally {
      _cameraStarting = false;
    }
  }

  Future<void> _handleCameraError(MobileScannerException error) async {
    if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
      // mobile_scanner asked and was refused (or Android refused silently).
      final access = await widget.permissions.status();
      if (!mounted) return;
      if (access == CameraAccess.permanentlyDenied ||
          access == CameraAccess.unknown) {
        _setState(_ScanState.blocked);
      } else if (access == CameraAccess.noCamera) {
        _setState(_ScanState.noCamera);
      } else if (access == CameraAccess.notRequested) {
        _setState(_ScanState.explain);
      } else if (access == CameraAccess.denied) {
        _setState(_ScanState.denied);
      } else {
        // Android says the permission is granted, yet the scanner was
        // refused: a camera problem, not a permission to ask for again.
        _recordFailure(error);
      }
      return;
    }
    _recordFailure(error);
  }

  void _recordFailure(MobileScannerException error) {
    _failure = error;
    _failedStarts++;
    _releaseBeforeStart = true;
    if (_state == _ScanState.failed) {
      setState(() {});
    } else {
      _setState(_ScanState.failed);
    }
  }

  Future<void> _stopCamera() async {
    if (!_scannerController.value.isRunning) return;
    try {
      await _scannerController.stop();
    } on MobileScannerException {
      // The scanner can already be stopping during an Android lifecycle change.
    }
  }

  /// Tears the failed controller down, releases the native camera session,
  /// re-reads the permission (it may have changed) and starts again.
  Future<void> _retryCamera() async {
    if (_cameraStarting || _permissionBusy) return;
    final previous = _scannerController;
    try {
      if (previous.value.isRunning) await previous.stop();
    } on MobileScannerException {
      // Replacing the controller below is the recovery path.
    }
    try {
      await previous.dispose();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _scannerController = _newController();
      _scannerGeneration++;
      _scanGate.reset();
      _showInvalidHint = false;
      _releaseBeforeStart = true;
      _state = _ScanState.checking;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  /// Pops the scanner once, with the normalized code. Camera frames often
  /// report the same QR code several times; only the first one counts.
  void _finish(String code) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    unawaited(_stopCamera());
    Navigator.of(context).pop(code);
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_scanGate.accepted || _manualEntryOpen) return;
    var sawValue = false;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      sawValue = true;
      final code = _scanGate.accept(value);
      if (code != null) {
        _finish(code);
        return;
      }
    }
    if (sawValue && !_showInvalidHint && mounted) {
      setState(() => _showInvalidHint = true);
    }
  }

  Future<void> _enterTvCode() async {
    if (_manualEntryOpen || _scanGate.accepted) return;
    _manualEntryOpen = true;
    // The camera is not needed while typing.
    await _stopCamera();
    if (!mounted) return;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TvCodeEntryScreen()),
    );
    _manualEntryOpen = false;
    if (!mounted) return;
    if (code == null) {
      if (_state == _ScanState.running || _state == _ScanState.starting) {
        unawaited(_startCamera());
      }
      return;
    }
    final accepted = _scanGate.accept(code);
    if (accepted != null) _finish(accepted);
  }

  // The optional child keeps this builder valid for mobile_scanner 6.x
  // (Modern iOS/Android) and 7.x (Legacy iOS), whose errorBuilder dropped it.
  Widget _cameraError(
    BuildContext context,
    MobileScannerException error, [
    Widget? child,
  ]) {
    // A failure after the camera started (for example another app took the
    // camera) is shown by the state card instead of over the preview.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _state == _ScanState.running) {
        unawaited(_handleCameraError(error));
      }
    });
    return const ColoredBox(color: _surface);
  }

  Widget _preview(BuildContext context) {
    final builder = widget.previewBuilder;
    if (builder != null) {
      return builder(context, _scannerController, _handleCapture);
    }
    return MobileScanner(
      key: ValueKey('orvix-tv-qr-scanner-$_scannerGeneration'),
      controller: _scannerController,
      errorBuilder: _cameraError,
      onDetect: _handleCapture,
    );
  }

  /// The framed camera preview, only while the camera starts or runs.
  Widget _cameraArea(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = (constraints.biggest.shortestSide * .66)
            .clamp(150.0, 280.0)
            .toDouble();
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ColoredBox(
            color: _surface,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _preview(context),
                if (_state == _ScanState.running)
                  Center(
                    child: IgnorePointer(
                      child: Container(
                        key: const ValueKey('tv-qr-scan-frame'),
                        width: side,
                        height: side,
                        decoration: BoxDecoration(
                          border: Border.all(color: _lime, width: 3),
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                    ),
                  )
                else
                  Center(child: _statePanel(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _failureTitle(CameraStartFailure failure) => switch (failure) {
        CameraStartFailure.stillHeld => 'The camera was still busy',
        CameraStartFailure.bindFailed => 'Android could not open the camera',
        CameraStartFailure.cameraService =>
          'The camera service did not respond',
        CameraStartFailure.permissionPromptOpen =>
          'A camera prompt is still open',
        CameraStartFailure.unexpected => 'Could not start the camera scanner.',
      };

  static String _failureMessage(CameraStartFailure failure) =>
      switch (failure) {
        CameraStartFailure.stillHeld =>
          'An earlier scanner session was still holding the camera. Retry '
              'releases it and starts again.',
        CameraStartFailure.bindFailed =>
          'Another app may be using the camera, or this phone has no usable '
              'back camera. Close camera or video-call apps, then retry.',
        CameraStartFailure.cameraService =>
          "Android's camera service did not hand the camera to Orvix. Close "
              'other camera apps, then retry.',
        CameraStartFailure.permissionPromptOpen =>
          'Answer or close the open permission prompt, then retry.',
        CameraStartFailure.unexpected =>
          'The scanner reported an unexpected error. Retry starts it again '
              'from scratch.',
      };

  Widget _statePanel(BuildContext context) {
    final failure = _failure;
    final failureKind = failure == null
        ? CameraStartFailure.unexpected
        : classifyCameraFailure(failure);
    final (IconData icon, String title, String message, Widget? action) =
        switch (_state) {
      _ScanState.checking || _ScanState.starting || _ScanState.running => (
          Icons.photo_camera_outlined,
          'Starting the camera…',
          'This takes a moment.',
          null,
        ),
      _ScanState.explain => (
          Icons.photo_camera_outlined,
          'Allow camera access',
          'Orvix uses the camera only to read the QR code shown on your TV. '
              'Nothing is recorded or uploaded.',
          _PrimaryAction(
            key: const ValueKey('tv-qr-allow-camera'),
            icon: Icons.photo_camera_outlined,
            label: 'Grant camera access',
            onPressed: _requestAccess,
          ),
        ),
      _ScanState.denied => (
          Icons.no_photography_outlined,
          'Camera access is off',
          'Allow camera access to scan the TV code, or enter the code '
              'instead.',
          _PrimaryAction(
            key: const ValueKey('tv-qr-allow-camera'),
            icon: Icons.photo_camera_outlined,
            label: 'Grant camera access',
            onPressed: _requestAccess,
          ),
        ),
      _ScanState.blocked => (
          Icons.no_photography_outlined,
          'Camera access is blocked',
          'Android will not ask again. Open app settings, then Permissions › '
              'Camera › Allow, and come back. Orvix checks again on return.',
          _PrimaryAction(
            key: const ValueKey('tv-qr-open-settings'),
            icon: Icons.settings_outlined,
            label: 'Open app settings',
            onPressed: _openSettings,
          ),
        ),
      _ScanState.noCamera => (
          Icons.no_photography_outlined,
          'No camera available',
          'This device has no camera Orvix can use. Enter the code shown on '
              'your TV instead.',
          null,
        ),
      _ScanState.failed => (
          Icons.error_outline_rounded,
          _failureTitle(failureKind),
          _failureMessage(failureKind),
          _PrimaryAction(
            key: const ValueKey('tv-qr-retry-camera'),
            icon: Icons.refresh_rounded,
            label: 'Retry camera',
            onPressed: _retryCamera,
          ),
        ),
    };
    final busy = _state == _ScanState.checking || _state == _ScanState.starting;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        key: ValueKey('tv-qr-state-${_state.name}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: busy ? 'Starting the camera' : null,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _lime.withValues(alpha: .1),
                shape: BoxShape.circle,
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: _lime,
                      ),
                    )
                  : Icon(icon, color: _limeLight, size: 28),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted, height: 1.45),
            ),
          ),
          if (_state == _ScanState.failed && failure != null) ...[
            const SizedBox(height: 10),
            SelectableText(
              'Error: ${cameraFailureCode(failure)}',
              key: const ValueKey('tv-qr-failure-code'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: .45),
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
            if (_failedStarts >= 2) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: const Text(
                  'Still failing? Close Orvix from recent apps and reopen it, '
                  'or restart the phone. The TV code below always works.',
                  key: ValueKey('tv-qr-persistent-hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _limeLight, height: 1.4),
                ),
              ),
            ],
          ],
          if (action != null) ...[
            const SizedBox(height: 20),
            action,
          ],
          if (_state == _ScanState.failed) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('tv-qr-failed-settings'),
              onPressed: _openSettings,
              style: TextButton.styleFrom(foregroundColor: _limeLight),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Open app settings'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cameraVisible =
        _state == _ScanState.running || _state == _ScanState.starting;
    final instruction = switch (_state) {
      _ScanState.running when _showInvalidHint =>
        'That QR code is not an Orvix TV code. Point the camera at the QR code shown by Orvix on your TV.',
      _ScanState.running ||
      _ScanState.starting =>
        'Point the camera at the QR code shown by Orvix on your TV.',
      _ => 'You can also type the six-character code shown under the QR '
          'code on your TV.',
    };
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scan Orvix TV QR'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: cameraVisible
                    ? _cameraArea(context)
                    // No camera to show: a compact card sized to its content
                    // instead of an empty preview frame.
                    : Center(
                        child: Container(
                          key: const ValueKey('tv-qr-state-card'),
                          decoration: BoxDecoration(
                            color: _surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: _border),
                          ),
                          child: _statePanel(context),
                        ),
                      ),
              ),
            ),
            Container(
              key: const ValueKey('tv-qr-actions'),
              margin: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    instruction,
                    key: const ValueKey('tv-qr-instruction'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _showInvalidHint && _state == _ScanState.running
                          ? _limeLight
                          : Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    key: const ValueKey('tv-qr-enter-code'),
                    onPressed: _enterTvCode,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      foregroundColor: _limeLight,
                      side: const BorderSide(color: Color(0xFF426B2E)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.dialpad_rounded),
                    label: const Text('Enter TV code'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _lime,
        foregroundColor: Colors.black,
        minimumSize: const Size(200, 50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

/// Typing the six-character code shown on the TV. Needs no camera.
/// Pops with the normalized code.
class TvCodeEntryScreen extends StatefulWidget {
  const TvCodeEntryScreen({super.key});

  @override
  State<TvCodeEntryScreen> createState() => _TvCodeEntryScreenState();
}

class _TvCodeEntryScreenState extends State<TvCodeEntryScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = TvDeviceLoginService.normalizeCode(_controller.text);
    if (code == null) {
      setState(() => _error = 'Enter the 6-character code shown on the TV.');
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final ready = TvDeviceLoginService.normalizeCode(_controller.text) != null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Enter TV code'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'On the TV, open Account. Type the code shown under the QR '
                'code.',
                style: TextStyle(color: _muted, height: 1.45, fontSize: 15),
              ),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('tv-code-field'),
                controller: _controller,
                autofocus: true,
                textAlign: TextAlign.center,
                maxLength: 7,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9 -]')),
                  TextInputFormatter.withFunction((oldValue, newValue) =>
                      newValue.copyWith(text: newValue.text.toUpperCase())),
                ],
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 6,
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  hintText: 'ABC-123',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: .25),
                    letterSpacing: 6,
                  ),
                  errorText: _error,
                  counterText: '',
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 18),
              FilledButton(
                key: const ValueKey('tv-code-continue'),
                onPressed: ready ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _lime,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Continue',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'You confirm the TV on the next step. TV codes expire after '
                '10 minutes; if it does not work, refresh the code on the TV.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
