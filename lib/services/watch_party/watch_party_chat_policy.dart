/// Client-side chat rules. The backend enforces the same limits; checking
/// here gives an immediate, friendly answer and saves a request.
class WatchPartyChatPolicy {
  WatchPartyChatPolicy({int Function()? nowMs})
      : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const maxLength = 500;
  static const maxNameLength = 24;

  /// Same window as the backend: eight messages in ten seconds.
  static const burst = 8;
  static const windowMs = 10000;

  final int Function() _nowMs;
  final List<int> _sentAt = [];

  // Control characters, plus the direction overrides and isolates that can
  // disguise text. Zero-width joiners stay: Sinhala needs them.
  static final _control = RegExp(r'[\u0000-\u001F\u007F-\u009F]');
  static final _directional = RegExp(r'[\u202A-\u202E\u2066-\u2069\uFEFF]');
  static final _spaces = RegExp(r'\s+');

  /// One clean line of text.
  static String clean(String input) => input
      .replaceAll(_directional, '')
      .replaceAll(_control, ' ')
      .replaceAll(_spaces, ' ')
      .trim();

  /// The display name to send, or null when [input] is not usable.
  static String? cleanName(String input) {
    final name = clean(input);
    if (name.isEmpty) return null;
    final runes = name.runes.toList();
    return runes.length <= maxNameLength
        ? name
        : String.fromCharCodes(runes.take(maxNameLength)).trim();
  }

  /// Why [input] cannot be sent right now, or null when it can.
  String? rejection(String input) {
    final body = clean(input);
    if (body.isEmpty) return 'Type a message first.';
    if (body.runes.length > maxLength) {
      return 'Messages can be up to $maxLength characters.';
    }
    final now = _nowMs();
    _sentAt.removeWhere((at) => now - at >= windowMs);
    if (_sentAt.length >= burst) {
      return 'You are sending messages too fast. Wait a few seconds.';
    }
    return null;
  }

  /// Call when a message was accepted for sending.
  void recordSent() => _sentAt.add(_nowMs());
}
