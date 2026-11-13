import 'package:shared_preferences/shared_preferences.dart';

import 'release_version.dart';

/// Where the last dismissed automatic update prompt is remembered.
abstract class UpdatePromptStore {
  Future<({String version, DateTime at})?> read();
  Future<void> write(String version, DateTime at);
  Future<void> clear();
}

class SharedPreferencesUpdatePromptStore implements UpdatePromptStore {
  const SharedPreferencesUpdatePromptStore();

  static const _versionKey = 'orvix.update_prompt.dismissed_version';
  static const _atKey = 'orvix.update_prompt.dismissed_at_ms';

  @override
  Future<({String version, DateTime at})?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final version = prefs.getString(_versionKey);
    final at = prefs.getInt(_atKey);
    if (version == null || version.isEmpty || at == null) return null;
    return (
      version: version,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  @override
  Future<void> write(String version, DateTime at) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_versionKey, version);
    await prefs.setInt(_atKey, at.toUtc().millisecondsSinceEpoch);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_versionKey);
    await prefs.remove(_atKey);
  }
}

class MemoryUpdatePromptStore implements UpdatePromptStore {
  ({String version, DateTime at})? value;

  @override
  Future<({String version, DateTime at})?> read() async => value;

  @override
  Future<void> write(String version, DateTime at) async =>
      value = (version: version, at: at);

  @override
  Future<void> clear() async => value = null;
}

/// Decides whether the automatic update prompt may appear.
///
/// "Later" on a prompt silences that exact version for [cooldown]. A higher
/// version prompts normally, the prompt returns once the cooldown is over,
/// and manual checks never consult this policy.
class UpdatePromptPolicy {
  UpdatePromptPolicy({
    UpdatePromptStore? store,
    DateTime Function()? clock,
    this.cooldown = defaultCooldown,
  })  : _store = store ?? const SharedPreferencesUpdatePromptStore(),
        _clock = clock ?? DateTime.now;

  static const defaultCooldown = Duration(hours: 24);

  final UpdatePromptStore _store;
  final DateTime Function() _clock;
  final Duration cooldown;

  /// Pure decision, for tests and for [shouldPrompt].
  static bool promptAllowed({
    required ReleaseVersion offered,
    required bool prerelease,
    required ({String version, DateTime at})? dismissed,
    required DateTime now,
    Duration cooldown = defaultCooldown,
  }) {
    // Automatic prompts are for stable releases only.
    if (prerelease || offered.isPrerelease) return false;
    if (dismissed == null) return true;
    final dismissedVersion = ReleaseVersion.tryParse(dismissed.version);
    if (dismissedVersion == null || !dismissedVersion.samePrecedence(offered)) {
      return true;
    }
    final elapsed = now.toUtc().difference(dismissed.at.toUtc());
    // A dismissal "from the future" means the clock moved; do not let it
    // silence the prompt for longer than one cooldown.
    if (elapsed.isNegative) return elapsed.abs() > cooldown;
    return elapsed >= cooldown;
  }

  Future<bool> shouldPrompt(String version, {required bool prerelease}) async {
    final offered = ReleaseVersion.tryParse(version);
    if (offered == null) return false;
    ({String version, DateTime at})? dismissed;
    try {
      dismissed = await _store.read();
    } catch (_) {
      dismissed = null;
    }
    return promptAllowed(
      offered: offered,
      prerelease: prerelease,
      dismissed: dismissed,
      now: _clock(),
      cooldown: cooldown,
    );
  }

  Future<void> recordDismissal(String version) async {
    try {
      await _store.write(version, _clock().toUtc());
    } catch (_) {}
  }

  /// Forgets a dismissal once [installed] reached or passed that version.
  Future<void> clearObsolete(String installed) async {
    final current = ReleaseVersion.tryParse(installed);
    if (current == null) return;
    try {
      final dismissed = await _store.read();
      if (dismissed == null) return;
      final version = ReleaseVersion.tryParse(dismissed.version);
      if (version == null || current >= version) await _store.clear();
    } catch (_) {}
  }
}
