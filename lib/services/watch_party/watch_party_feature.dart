import 'package:flutter/foundation.dart';

/// Watch Party is off unless a build opts in with
/// `--dart-define=ORVIX_WATCH_PARTY=true`.
///
/// It stays off in release builds until the backend in
/// `supabase/migrations/20261112120000_create_watch_party.sql` is deployed
/// and the feature has been tested on real devices. With the flag off no
/// Watch Party entry point is shown, no player is observed and no request is
/// made. See docs/WATCH_PARTY.md.
class WatchPartyFeature {
  WatchPartyFeature._();

  static const bool compiledIn = bool.fromEnvironment('ORVIX_WATCH_PARTY');

  /// Lets tests turn the feature on. Always null in the app.
  @visibleForTesting
  static bool? debugOverride;

  static bool get enabled => debugOverride ?? compiledIn;
}
