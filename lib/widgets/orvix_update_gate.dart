import 'dart:async';

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

class _OrvixUpdateGateState extends State<OrvixUpdateGate> {
  final AppUpdateService _updates = AppUpdateService();

  AppUpdateInfo? _update;
  bool _dismissed = false;
  bool _installing = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_checkSoon());
  }

  Future<void> _checkSoon() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    final update = await _updates.checkForUpdate();
    if (!mounted || update == null) return;
    setState(() => _update = update);
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final update = _update;
    if (update == null || _installing) return;
    setState(() {
      _installing = true;
      _progress = 0;
    });

    try {
      final file = await _updates.download(
        update,
        onProgress: (value) {
          if (!mounted) return;
          setState(() => _progress = value);
        },
      );
      if (!mounted) return;

      final result = await _updates.install(update, file);
      if (!mounted) return;
      if (result == AppUpdateInstallResult.permissionRequired) {
        setState(() => _installing = false);
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
        setState(() => _installing = false);
        _showMessage('Could not open the installer for this platform.');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _installing = false);
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
                                _installing
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
                                _installing
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
                          value: _progress > 0 ? _progress : null,
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
