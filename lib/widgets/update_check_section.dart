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
    this.privateBuild = false,
  });

  final String headline;
  final List<String> details;
  final bool canInstall;

  /// The offered update is an owner-only private test build.
  final bool privateBuild;
}

/// Turns [report] into Settings text.
///
/// Private-channel details appear only when the server confirmed the account
/// as an Orvix admin. Ordinary and signed-out users see the public result
/// only, so nothing tells them a private channel exists.
UpdateCheckSummary describeUpdateCheck(UpdateCheckReport report) {
  final update = report.update;
  final private = report.private;
  final details = <String>[];
  final installed = report.installedVersion;
  if (installed != null) details.add('Installed: $installed');

  String headline;
  if (update != null) {
    headline = 'Orvix ${update.version} is available';
    details.add(report.isPrivateUpdate
        ? 'Private test build for this device, from the owner channel.'
        : 'Public release from GitHub.');
  } else if (report.publicStatus == PublicUpdateStatus.unreachable) {
    headline = 'Could not check for updates';
    details.add('GitHub could not be reached. Check the connection and try '
        'again.');
  } else {
    headline = 'Orvix is up to date';
  }

  switch (private.status) {
    case PrivateUpdateStatus.sessionExpired:
      details.add('Your Orvix account session expired. Sign in again in '
          'Account, then check again.');
    case PrivateUpdateStatus.serverUnconfigured:
      details.add('Private channel: the server has no GitHub access '
          'configured.');
    case PrivateUpdateStatus.githubUnavailable:
      final code = private.githubStatus;
      details.add('Private channel: GitHub refused the draft lookup'
          '${code == null ? '' : ' (HTTP $code)'}.');
    case PrivateUpdateStatus.noNewerBuild:
      final visible = private.draftsVisible;
      if (private.legacyServer) {
        details.add('Private channel: no newer test build reported. The '
            'server runs an older orvix-internal-update without '
            'diagnostics; redeploy it to see why.');
      } else if (visible == 0) {
        details.add('Private channel: the server sees no draft releases. '
            'Check that its GitHub token can read draft releases.');
      } else if (private.skippedDrafts > 0) {
        details.add('Private channel: no newer build for this device '
            '(${private.skippedDrafts} draft${private.skippedDrafts == 1 ? '' : 's'} '
            'without an installer for it).');
      } else {
        details.add('Private channel: no newer test build.');
      }
    case PrivateUpdateStatus.available:
      if (!report.isPrivateUpdate) {
        details.add('Private channel: the public release is newer than the '
            'latest test build.');
      }
    case PrivateUpdateStatus.unavailable:
      // Signed in only: a signed-out check never reaches the endpoint. The
      // wording names no private channel, because the account may not be an
      // admin (the server never got to say).
      final reason = switch (private.failure) {
        'timeout' => 'did not answer in time',
        'not_deployed' => 'has no update function deployed',
        'network' => 'could not be reached',
        'bad_response' => 'gave an unreadable answer',
        final String code when code.startsWith('http_') =>
          'failed (HTTP ${code.substring(5)})',
        _ => null,
      };
      if (reason != null) details.add('Account update check: the server $reason.');
    case PrivateUpdateStatus.signedOut:
    case PrivateUpdateStatus.notEntitled:
    case PrivateUpdateStatus.unsupportedPlatform:
      break;
  }

  return UpdateCheckSummary(
    headline: headline,
    details: details,
    canInstall: update != null,
    privateBuild: report.isPrivateUpdate,
  );
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
                if (summary?.canInstall == true)
                  OutlinedButton.icon(
                    key: const ValueKey('settings-install-update'),
                    onPressed: busy ? null : install,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(busy ? 'Updating…' : 'Install update'),
                  ),
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
          if (summary?.canInstall == true) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TvButton(
                key: const ValueKey('tv-settings-install-update'),
                kind: TvButtonKind.primary,
                icon: Icons.download_rounded,
                label: busy ? 'Updating…' : 'Install update',
                busy: busy,
                onPressed: install,
              ),
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
