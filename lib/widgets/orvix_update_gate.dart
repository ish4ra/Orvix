import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';

class OrvixUpdateGate extends StatefulWidget {
  const OrvixUpdateGate({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  State<OrvixUpdateGate> createState() => _OrvixUpdateGateState();
}

class _OrvixUpdateGateState extends State<OrvixUpdateGate>
    with WidgetsBindingObserver {
  final AppUpdateService _updates = AppUpdateService();

  AppUpdateInfo? _update;
  bool _dismissed = false;
  bool _installing = false;
  bool _applying = false;
  double _progress = 0;
  File? _downloadedFile;
  Timer? _periodicCheck;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reportPreviousWindowsUpdate());
    unawaited(_checkSoon());
    _periodicCheck = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(_checkForUpdate()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForUpdate());
    }
  }

  Future<void> _reportPreviousWindowsUpdate() async {
    final status = await _updates.consumeLastWindowsUpdateStatus();
    if (!mounted || status == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    _showMessage(
      status.success
          ? 'Orvix ${status.version} installed successfully.'
          : 'Update to ${status.version} did not complete (${status.detail}).',
    );
  }

  Future<void> _checkSoon() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    if (!mounted || _checking || _installing) return;
    _checking = true;
    try {
      final update = await _updates.checkForUpdate();
      if (!mounted || update == null) return;

      final changed = _update?.tag != update.tag;
      if (!changed && _update != null) return;

      setState(() {
        _update = update;
        // A dismissal only applies to the version the user dismissed. If a
        // newer release appears while Orvix stays open, show it automatically.
        _dismissed = false;
        _downloadedFile = null;
      });
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicCheck?.cancel();
    _updates.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final update = _update;
    if (update == null || _installing) return;
    setState(() {
      _installing = true;
      _applying = false;
      _progress = 0;
    });

    try {
      var file = _downloadedFile;
      if (file == null || !await file.exists()) {
        file = await _updates.download(
          update,
          onProgress: (value) {
            if (!mounted) return;
            setState(() => _progress = value);
          },
        );
        _downloadedFile = file;
      } else if (mounted) {
        setState(() => _progress = 1);
      }
      if (!mounted) return;
      if (Platform.isWindows) {
        setState(() => _applying = true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final result = await _updates.install(update, file);
      if (!mounted) return;
      if (result == AppUpdateInstallResult.permissionRequired) {
        setState(() {
          _installing = false;
          _applying = false;
        });
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Allow Orvix updates'),
            content: const Text(
              'Android opened the “Install unknown apps” permission page. '
              'Allow Orvix to install apps, return here, then press Update again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      } else if (result == AppUpdateInstallResult.unsupported) {
        setState(() {
          _installing = false;
          _applying = false;
        });
        _showMessage('Could not open the installer for this platform.');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _applying = false;
      });
      _showMessage('Update failed: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _showNotes() async {
    final update = _update;
    if (update == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(update.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            child: SelectableText(
              update.notes.trim().isEmpty
                  ? 'No release notes were published for this build.'
                  : update.notes.trim(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              unawaited(_install());
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    final visible = update != null && !_dismissed;

    return Column(
      children: [
        if (visible)
          Material(
            color: const Color(0xFF151813),
            elevation: 8,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.cloud_download_rounded,
                      color: Color(0xFFB9FF45),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: _showNotes,
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _applying
                                    ? 'Opening Orvix ${update.version} installer…'
                                    : _installing
                                        ? 'Downloading Orvix ${update.version}…'
                                        : 'Orvix ${update.version} is available',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _applying
                                    ? 'Orvix will close; finish setup in the Windows installer'
                                    : _installing
                                        ? '${(_progress * 100).round()}% downloaded'
                                        : 'Installed: ${AppUpdateService.currentVersion} • View what changed',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFAEB7B0),
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_installing)
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(
                          value: _applying
                              ? null
                              : (_progress > 0 ? _progress : null),
                          minHeight: 5,
                          backgroundColor: const Color(0xFF293029),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFFB9FF45),
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _install,
                        icon: const Icon(Icons.system_update_alt_rounded),
                        label: const Text('Update'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFB9FF45),
                          foregroundColor: Colors.black,
                        ),
                      ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Later',
                      onPressed: _installing
                          ? null
                          : () => setState(() => _dismissed = true),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
