import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../tv/tv_theme.dart';
import '../tv/tv_widgets.dart';
import 'orvix_update_gate.dart';

/// What a manual update check found, in words for the Settings screen.
class UpdateCheckSummary {
  const UpdateCheckSummary({
    required this.headline,
    required this.details,
    required this.canInstall,
    this.prerelease = false,
    this.opensReleasePage = false,
    this.failed = false,
  });

  final String headline;
  final List<String> details;

  /// An update was found; the action installs it (or, on iOS, opens it).
  final bool canInstall;

  /// The offered update is a public beta/prerelease.
  final bool prerelease;

  /// iOS: the action opens the GitHub release page instead of installing.
  final bool opensReleasePage;

  /// The check did not reach a conclusion (network, rate limit, ...).
  final bool failed;

  /// The label of the install action.
  String get actionLabel => opensReleasePage
      ? 'Open release page'
      : prerelease
          ? 'Install beta'
          : 'Install update';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// Turns [report] into Settings text. Only public GitHub releases are
/// checked, so nothing here depends on an Orvix account.
UpdateCheckSummary describeUpdateCheck(UpdateCheckReport report, {DateTime? now}) {
  final update = report.update;
  final details = <String>[];
  final installed = report.installedVersion;
  if (installed != null) details.add('Installed: $installed');
  final http = report.httpStatus == null ? '' : ' (HTTP ${report.httpStatus})';

  UpdateCheckSummary failure(String headline, String detail) =>
      UpdateCheckSummary(
        headline: headline,
        details: [...details, detail],
        canInstall: false,
        failed: true,
      );

  switch (report.status) {
    case UpdateCheckStatus.available when update != null:
      final ios = report.target == UpdateTarget.ios;
      details.add(update.prerelease
          ? 'Public beta (prerelease) from GitHub. Betas are offered only '
              'when you check here.'
          : 'Stable release from GitHub.');
      final newer = report.newestWithoutAsset;
      if (newer != null) {
        details.add('Orvix $newer is newer but has no installer for this '
            'device yet.');
      }
      if (update.viaReleaseFeed) {
        details.add("GitHub's update limit was reached, so this was found "
            'through the public release feed. Its checksum is not known; '
            'the file size is still verified.');
      }
      if (ios) {
        details.add('iOS does not let apps install their own updates. Open '
            'the release page, download the IPA for your device and install '
            'it with your sideloading tool.');
      } else if (report.target == UpdateTarget.macos) {
        details.add('The download is shown in Finder; move the new Orvix to '
            'Applications to finish.');
      }
      return UpdateCheckSummary(
        headline: update.prerelease
            ? 'Orvix ${update.version} (beta) is available'
            : 'Orvix ${update.version} is available',
        details: details,
        canInstall: true,
        prerelease: update.prerelease,
        opensReleasePage: ios,
      );
    case UpdateCheckStatus.available:
    case UpdateCheckStatus.upToDate:
      return UpdateCheckSummary(
        headline: 'Orvix is up to date',
        details: [
          ...details,
          'No newer public release or beta is available for this device.',
        ],
        canInstall: false,
      );
    case UpdateCheckStatus.noCompatibleAsset:
      final newer = report.newestWithoutAsset;
      return UpdateCheckSummary(
        headline: newer == null
            ? 'No installer for this device yet'
            : 'Orvix $newer has no installer for this device yet',
        details: [
          ...details,
          'A newer release exists, but it does not include a file for this '
              'device. Check again later.',
        ],
        canInstall: false,
      );
    case UpdateCheckStatus.rateLimited:
      final reset = report.rateLimitResetAt?.toLocal();
      final current = (now ?? DateTime.now());
      final when = reset == null || reset.isBefore(current)
          ? 'in a few minutes'
          : 'after ${_two(reset.hour)}:${_two(reset.minute)}';
      return failure(
        "GitHub's update limit was reached",
        'GitHub allows a limited number of update checks per hour from one '
            'network. Try again $when.',
      );
    case UpdateCheckStatus.timeout:
      return failure('Could not check for updates',
          'GitHub did not answer in time. Check the connection and try again.');
    case UpdateCheckStatus.network:
      return failure('Could not check for updates',
          'GitHub could not be reached. Check the connection and try again.');
    case UpdateCheckStatus.serverError:
      return failure('Could not check for updates',
          'GitHub had a server problem$http. Try again later.');
    case UpdateCheckStatus.refused:
      return failure('Could not check for updates',
          'GitHub refused the update request$http. Try again later.');
    case UpdateCheckStatus.httpError:
      return failure('Could not check for updates',
          'GitHub answered unexpectedly$http. Try again later.');
    case UpdateCheckStatus.invalidResponse:
      return failure('Could not check for updates',
          'GitHub sent an answer Orvix could not read. Try again later.');
    case UpdateCheckStatus.incomplete:
      return failure('Could not finish the update check',
          'GitHub listed more releases than Orvix checks at once, so a newer '
              'one may have been missed. Try again later.');
    case UpdateCheckStatus.unsupportedPlatform:
      return failure('Updates are not available here',
          'This platform has no Orvix update path.');
    case UpdateCheckStatus.installedVersionUnknown:
      return failure('Could not check for updates',
          'The installed Orvix version could not be read.');
  }
}

/// Stands in for the gate's notifier when no gate is above (tests).
final ValueNotifier<bool> _notInstalling = ValueNotifier<bool>(false);

/// Shared state for both looks of the Settings update section.
mixin _UpdateCheckLogic<T extends StatefulWidget> on State<T> {
  bool checking = false;
  UpdateCheckSummary? summary;

  OrvixUpdateGateState? get gate => OrvixUpdateGate.maybeOf(context);

  Future<void> check() async {
    final gate = this.gate;
    if (gate == null || checking) return;
    setState(() => checking = true);
    try {
      final report = await gate.checkNow();
      if (!mounted) return;
      setState(() => summary = describeUpdateCheck(report));
    } catch (_) {
      if (!mounted) return;
      setState(() => summary = const UpdateCheckSummary(
            headline: 'Could not check for updates',
            details: ['Something went wrong. Try again in a moment.'],
            canInstall: false,
          ));
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  void install() {
    final gate = this.gate;
    if (gate != null) unawaited(gate.installAvailableUpdate());
  }

  void showNotes() {
    final gate = this.gate;
    if (gate != null) unawaited(gate.showReleaseNotes());
  }
}

/// The "App updates" card in Settings on phones, tablets and desktop.
class UpdateCheckCard extends StatefulWidget {
  const UpdateCheckCard({super.key});

  @override
  State<UpdateCheckCard> createState() => _UpdateCheckCardState();
}

class _UpdateCheckCardState extends State<UpdateCheckCard>
    with _UpdateCheckLogic {
  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final installing = gate?.installing;
    return Container(
      key: const ValueKey('settings-app-updates'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0D120E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF263827)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.system_update_alt_rounded),
              SizedBox(width: 10),
              Text(
                'App updates',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: AppUpdateService.installedVersion(),
            builder: (context, snapshot) => Text(
              summary?.headline ??
                  (snapshot.hasData
                      ? 'Installed: ${snapshot.data}'
                      : 'Check GitHub for a newer Orvix version.'),
              style: TextStyle(
                color: summary == null ? muted : null,
                fontWeight:
                    summary == null ? FontWeight.w500 : FontWeight.w800,
                height: 1.45,
              ),
            ),
          ),
          if (summary != null)
            for (final line in summary.details)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(line, style: TextStyle(color: muted, height: 1.4)),
              ),
          const SizedBox(height: 14),
          ValueListenableBuilder<bool>(
            valueListenable: installing ?? _notInstalling,
            builder: (context, busy, _) => Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const ValueKey('settings-check-updates'),
                  onPressed: checking || busy || gate == null ? null : check,
                  icon: checking
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(checking ? 'Checking…' : 'Check for updates'),
                ),
                if (summary != null && summary.canInstall) ...[
                  OutlinedButton.icon(
                    key: const ValueKey('settings-install-update'),
                    onPressed: busy ? null : install,
                    icon: Icon(summary.opensReleasePage
                        ? Icons.open_in_new_rounded
                        : Icons.download_rounded),
                    label: Text(busy ? 'Updating…' : summary.actionLabel),
                  ),
                  TextButton.icon(
                    key: const ValueKey('settings-update-notes'),
                    onPressed: showNotes,
                    icon: const Icon(Icons.notes_rounded),
                    label: const Text("What's new"),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "App updates" section on Android TV, built from remote controls so
/// every action is reachable with the DPAD.
class TvUpdateCheckSection extends StatefulWidget {
  const TvUpdateCheckSection({super.key});

  @override
  State<TvUpdateCheckSection> createState() => _TvUpdateCheckSectionState();
}

class _TvUpdateCheckSectionState extends State<TvUpdateCheckSection>
    with _UpdateCheckLogic {
  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    final installing = gate?.installing ?? _notInstalling;
    return ValueListenableBuilder<bool>(
      valueListenable: installing,
      builder: (context, busy, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<String>(
            future: AppUpdateService.installedVersion(),
            builder: (context, snapshot) => TvSettingsTile(
              key: const ValueKey('tv-settings-check-updates'),
              icon: Icons.system_update_alt_rounded,
              title: checking ? 'Checking for updates…' : 'Check for updates',
              subtitle: summary?.headline ??
                  'Look for a newer Orvix version for this TV.',
              value: snapshot.hasData ? snapshot.data : null,
              enabled: !checking && !busy && gate != null,
              onPressed: check,
            ),
          ),
          if (summary != null)
            for (final line in summary.details)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(line, style: TvText.caption),
              ),
          if (summary != null && summary.canInstall) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                // Filling the row keeps Down from "Check for updates" on the
                // install action, the one the user most likely wants.
                Expanded(
                  child: TvButton(
                    key: const ValueKey('tv-settings-install-update'),
                    kind: TvButtonKind.primary,
                    icon: Icons.download_rounded,
                    label: busy ? 'Updating…' : summary.actionLabel,
                    busy: busy,
                    expanded: true,
                    onPressed: install,
                  ),
                ),
                const SizedBox(width: 12),
                TvButton(
                  key: const ValueKey('tv-settings-update-notes'),
                  icon: Icons.notes_rounded,
                  label: "What's new",
                  enabled: !busy,
                  onPressed: showNotes,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Download progress is shown at the top of the screen.',
              style: TvText.caption,
            ),
          ],
        ],
      ),
    );
  }
}
