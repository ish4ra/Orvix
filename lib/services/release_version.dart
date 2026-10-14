/// A release version with Semantic Versioning 2.0.0 precedence.
///
/// Accepts GitHub tags and app version names such as `v0.7.10`,
/// `0.7.10-beta.3`, `0.7.10-beta.1000` and `0.7.10-beta.3+4226`.
///
/// * Every numeric part is compared as a number of any length, so
///   `beta.9 < beta.10 < beta.99 < beta.100 < beta.1000`.
/// * A prerelease sorts below its release: `0.7.10-beta.1000 < 0.7.10`.
/// * Prerelease identifiers are compared one by one: numeric identifiers
///   numerically, others in ASCII order, numeric below alphanumeric, and a
///   shorter list below a longer one when all shared identifiers are equal.
/// * Build metadata (`+4226`) is kept but never affects precedence.
///
/// One deliberate leniency: numeric identifiers with leading zeros (old tags
/// such as `v0.7.4-alpha.01`) are accepted and compared by value.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._(
    this.major,
    this.minor,
    this.patch,
    this.prerelease,
    this.build,
  );

  final BigInt major;
  final BigInt minor;
  final BigInt patch;

  /// Dot-separated prerelease identifiers, empty for a release.
  final List<String> prerelease;

  /// Build metadata after `+`, or null. Not part of precedence.
  final String? build;

  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );
  static final RegExp _numeric = RegExp(r'^\d+$');

  /// Parses [raw], or returns null when it is not a version.
  static ReleaseVersion? tryParse(String? raw) {
    final match = _pattern.firstMatch(raw?.trim() ?? '');
    if (match == null) return null;
    return ReleaseVersion._(
      BigInt.parse(match.group(1)!),
      BigInt.parse(match.group(2)!),
      BigInt.parse(match.group(3)!),
      List.unmodifiable(match.group(4)?.split('.') ?? const <String>[]),
      match.group(5),
    );
  }

  bool get isPrerelease => prerelease.isNotEmpty;

  @override
  int compareTo(ReleaseVersion other) {
    var result = major.compareTo(other.major);
    if (result != 0) return result;
    result = minor.compareTo(other.minor);
    if (result != 0) return result;
    result = patch.compareTo(other.patch);
    if (result != 0) return result;

    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      // A release has higher precedence than any of its prereleases.
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    final shared = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var i = 0; i < shared; i++) {
      result = _compareIdentifier(prerelease[i], other.prerelease[i]);
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  static int _compareIdentifier(String a, String b) {
    final aNumeric = _numeric.hasMatch(a);
    final bNumeric = _numeric.hasMatch(b);
    if (aNumeric && bNumeric) return BigInt.parse(a).compareTo(BigInt.parse(b));
    if (aNumeric) return -1;
    if (bNumeric) return 1;
    // ASCII order, as SemVer requires (not locale-aware ordering).
    return a.compareTo(b);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;
  bool operator <(ReleaseVersion other) => compareTo(other) < 0;
  bool operator >=(ReleaseVersion other) => compareTo(other) >= 0;
  bool operator <=(ReleaseVersion other) => compareTo(other) <= 0;

  /// Same precedence; build metadata is ignored.
  bool samePrecedence(ReleaseVersion other) => compareTo(other) == 0;

  /// True when [candidate] has higher precedence than [current]. False when
  /// either string is not a version.
  static bool isNewer(String candidate, String current) {
    final a = tryParse(candidate);
    final b = tryParse(current);
    if (a == null || b == null) return false;
    return a > b;
  }

  /// The version without a leading `v` and without build metadata.
  @override
  String toString() => [
        '$major.$minor.$patch',
        if (prerelease.isNotEmpty) prerelease.join('.'),
      ].join('-');
}
