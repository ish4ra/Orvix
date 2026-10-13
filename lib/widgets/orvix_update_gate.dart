import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_update_service.dart';
import '../services/platform_profile.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';

class OrvixUpdateGate extends StatefulWidget {
  const OrvixUpdateGate({
    required this.child,
    this.service,
    this.checkOnStart = true,
    super.key,
  });

  final Widget child;

  /// For tests; defaults to a real [AppUpdateService].
  final AppUpdateService? service;
  final bool checkOnStart;

  /// The gate above [context], used by Settings for a manual update check.
  static OrvixUpdateGateState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<OrvixUpdateGateState>();

  @override
  State<OrvixUpdateGate> createState() => OrvixUpdateGateState();
}

class OrvixUpdateGateState extends State<OrvixUpdateGate> {
  late final AppUpdateService _updates = widget.service ?? AppUpdateService();
  final FocusNode _tvUpdateNode = FocusNode(debugLabel: 'tv-update-install');
  final FocusScopeNode _tvBannerScope = FocusScopeNode(
    debugLabel: 'tv-update-banner',
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  Future<UpdateCheckReport>? _manualCheck;

  /// The update currently offered (shown in the banner), for Settings.
  final ValueNotifier<AppUpdateInfo?> availableUpdate =
      ValueNotifier<AppUpdateInfo?>(null);

  /// True while an update downloads or its installer opens.
  final ValueNotifier<bool> installing = ValueNotifier<bool>(false);
  StreamSubscription<AuthState>? _authChanges;

  AppUpdateInfo? _update;
  bool _dismissed = false;
  bool _installing = false;
  bool _applying = false;
  double _progress = 0;
  File? _downloadedFile;
  bool _checking = false;
  bool _cancelDownloadRequested = false;

  @override
  void initState() {
    super.initState();
    // Recheck private entitlements after login. On logout, immediately drop
    // any sensitive manifest previously held by this widget.
    try {
      _authChanges = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
        if (!mounted) return;
        if (state.event == AuthChangeEvent.signedOut ||
            state.event == AuthChangeEvent.userDeleted) {
          setState(() {
            _update = null;
            _downloadedFile = null;
            _dismissed = false;
          });
          unawaited(_checkForUpdate());
        } else if (state.event == AuthChangeEvent.signedIn) {
          unawaited(_checkForUpdate());
        }
      });
    } catch (_) {
      // Public app updates must still work without Supabase initialized.
    }
    unawaited(_reportPreviousWindowsUpdate());
    if (widget.checkOnStart) unawaited(_checkSoon());
  }

  /// A user-requested check of both update channels. The result also
  /// updates the banner, so an update found here can be installed from it.
  Future<UpdateCheckReport> checkNow() {
    final running = _manualCheck;
    if (running != null) return running;
    final check = _runManualCheck();
    _manualCheck = check;
    return check.whenComplete(() => _manualCheck = null);
  }

  Future<UpdateCheckReport> _runManualCheck() async {
    final report = await _updates.checkForUpdateReport();
    if (!mounted) return report;
    final update = report.update;
    if (update != null && !_installing) {
      setState(() {
        if (_update?.tag != update.tag) _downloadedFile = null;
        _update = update;
        _dismissed = false;
      });
    }
    return report;
  }

  /// Starts downloading and installing the offered update.
  Future<void> installAvailableUpdate() async {
    if (_update == null) return;
    if (_dismissed) setState(() => _dismissed = false);
    await _install();
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
        // A dismissal only applies to the version the user dismissed. A
        // newer release discovered on the next cold app start is shown.
        _dismissed = false;
        _downloadedFile = null;
      });
    } finally {
      _checking = false;
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    availableUpdate.value = _dismissed ? null : _update;
    installing.value = _installing;
    _syncTvTarget();
  }

  /// Registers the banner's Update action as the control above the TV shell
  /// while the banner is shown, so the remote can reach it.
  void _syncTvTarget() {
    if (!PlatformProfile.isAndroidTv) return;
    final visible = _update != null && !_dismissed;
    if (visible) {
      TvTopTarget.node.value = _tvUpdateNode;
    } else if (TvTopTarget.node.value == _tvUpdateNode) {
      if (_tvBannerScope.hasFocus) TvTopTarget.leave();
      TvTopTarget.node.value = null;
    }
  }

  @override
  void dispose() {
    if (TvTopTarget.node.value == _tvUpdateNode) TvTopTarget.node.value = null;
    _authChanges?.cancel();
    if (widget.service == null) _updates.dispose();
    _tvUpdateNode.dispose();
    _tvBannerScope.dispose();
    availableUpdate.dispose();
    installing.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final update = _update;
    if (update == null || _installing) return;
    setState(() {
      _installing = true;
      _applying = false;
      _progress = 0;
      _cancelDownloadRequested = false;
    });

    try {
      var file = _downloadedFile;
      if (file == null || !await file.exists()) {
        file = await _updates.download(
          update,
          isCancelled: () => _cancelDownloadRequested,
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
                autofocus: true,
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
      if (_cancelDownloadRequested) {
        setState(() {
          _installing = false;
          _applying = false;
          _progress = 0;
          _cancelDownloadRequested = false;
        });
        return;
      }
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
    if (PlatformProfile.isAndroidTv) return _showTvNotes(update);
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
            autofocus: true,
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

  /// Release notes for the remote: Update has focus as soon as it opens,
  /// Left/Right move between the two buttons and Back closes it.
  Future<void> _showTvNotes(AppUpdateInfo update) async {
    final notes = update.notes.trim().isEmpty
        ? 'No release notes were published for this build.'
        : update.notes.trim();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: TvColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TvMetrics.radius),
          side: const BorderSide(color: TvColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 420),
          child: FocusTraversalGroup(
            policy: TvTraversalPolicy(),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(update.title, style: TvText.section),
                  const SizedBox(height: 12),
                  Flexible(
                    child: Text(
                      notes,
                      maxLines: 10,
                      overflow: TextOverflow.ellipsis,
                      style: TvText.body,
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      TvButton(
                        key: const ValueKey('tv-update-notes-install'),
                        kind: TvButtonKind.primary,
                        icon: Icons.system_update_alt_rounded,
                        label: 'Update',
                        autofocus: true,
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          unawaited(_install());
                        },
                      ),
                      const SizedBox(width: 12),
                      TvButton(
                        key: const ValueKey('tv-update-notes-close'),
                        label: 'Close',
                        onPressed: () => Navigator.pop(dialogContext),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleTvBannerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) TvTopTarget.leave();
      return KeyEventResult.handled;
    }
    // Nothing is above the banner; Left/Right stay inside it.
    if (key == LogicalKeyboardKey.arrowUp) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  /// The Android TV banner: remote buttons with a clear focus state. Up at
  /// the top of the TV shell moves here; Down or Back returns to the shell.
  Widget _buildTvBanner(AppUpdateInfo update) {
    final status = _applying
        ? 'Opening the Orvix ${update.version} installer…'
        : _installing
            ? 'Downloading Orvix ${update.version} · ${(_progress * 100).round()}%'
            : 'Orvix ${update.version} is available';
    final hint = _installing
        ? 'You can keep using Orvix while the update downloads.'
        : 'Press Up on the remote to reach these buttons.';
    return Material(
      key: const ValueKey('tv-update-banner'),
      color: TvColors.surface,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: TvColors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            TvMetrics.navCollapsedWidth + 12,
            10,
            TvMetrics.pageHorizontal,
            10,
          ),
          child: FocusScope(
            node: _tvBannerScope,
            child: FocusTraversalGroup(
              policy: TvTraversalPolicy(),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _handleTvBannerKey,
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: TvColors.primary.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.system_update_alt_rounded,
                        color: TvColors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TvText.label.copyWith(color: TvColors.text),
                          ),
                          const SizedBox(height: 3),
                          if (_installing && !_applying)
                            Padding(
                              padding: const EdgeInsets.only(top: 3, right: 40),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: LinearProgressIndicator(
                                  value: _progress > 0 ? _progress : null,
                                  minHeight: 4,
                                  backgroundColor: TvColors.border,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                          TvColors.primary),
                                ),
                              ),
                            )
                          else
                            Text(hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TvText.caption),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    TvButton(
                      key: const ValueKey('tv-update-install'),
                      focusNode: _tvUpdateNode,
                      kind: TvButtonKind.primary,
                      icon: Icons.system_update_alt_rounded,
                      label: 'Update',
                      busy: _installing,
                      onPressed: _install,
                    ),
                    const SizedBox(width: 10),
                    TvButton(
                      key: const ValueKey('tv-update-notes'),
                      icon: Icons.notes_rounded,
                      label: 'What\'s new',
                      enabled: !_installing,
                      onPressed: _showNotes,
                    ),
                    const SizedBox(width: 10),
                    TvButton(
                      key: const ValueKey('tv-update-later'),
                      kind: TvButtonKind.quiet,
                      label: _installing && !_applying ? 'Cancel' : 'Later',
                      enabled: !_applying,
                      onPressed: () {
                        if (_installing) {
                          setState(() => _cancelDownloadRequested = true);
                        } else {
                          setState(() => _dismissed = true);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    final visible = update != null && !_dismissed;

    if (PlatformProfile.isAndroidTv) {
      return Column(
        children: [
          if (visible) _buildTvBanner(update),
          Expanded(child: widget.child),
        ],
      );
    }

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
                              if (_applying || _installing)
                                Text(
                                  _applying
                                      ? 'Orvix will close; finish setup in the Windows installer'
                                      : '${(_progress * 100).round()}% downloaded',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFAEB7B0),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              else
                                FutureBuilder<String>(
                                  future: AppUpdateService.installedVersion(),
                                  builder: (context, snapshot) {
                                    final version = snapshot.data?.trim();
                                    return Text(
                                      version == null || version.isEmpty
                                          ? 'View what changed'
                                          : 'Installed: $version • View what changed',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFAEB7B0),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    );
                                  },
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
                      tooltip: _installing && !_applying ? 'Cancel download' : 'Later',
                      onPressed: _applying
                          ? null
                          : _installing
                              ? () => setState(() => _cancelDownloadRequested = true)
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
