/// Removes secrets and personal data from text before it is sent as
/// analytics or error diagnostics.
///
/// Error messages can carry request URLs (with provider tokens or add-on
/// configs in the path or query), headers, token maps, email addresses and
/// local user names. Every string that leaves the device through
/// [OrvixTelemetryService] passes through here. The orvix-telemetry Edge
/// Function applies the same rules again (redact.ts); both are checked
/// against supabase/functions/orvix-telemetry/redaction_cases.json.
library;

const redactedValue = '[redacted]';

// Only the scheme and host of a URL are kept. file: URLs (stack frames) keep
// their path; the home directory rule below still applies to them.
final RegExp _url = RegExp(
  r'''\b([a-z][a-z0-9+.-]*)://([^\s/?#"'<>@]*@)?([^\s/?#"'<>]*)([^\s"'<>]*)''',
  caseSensitive: false,
);
final RegExp _magnet = RegExp(r'''magnet:\?[^\s"'<>]+''', caseSensitive: false);
final RegExp _jwt =
    RegExp(r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*');
final RegExp _secretField = RegExp(
  r'''\b([\w.-]*(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|cookie|session|credential|signature|realdebrid|alldebrid|premiumize|debridlink|torbox|offcloud|putio|easydebrid|pikpak)[\w.-]*)(["']?\s*[:=]\s*["']?)(?!\[redacted)((?:(?:bearer|basic)\s+)?[^\s"'&,;|}\]]+)''',
  caseSensitive: false,
);
final RegExp _authScheme =
    RegExp(r'\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);
final RegExp _email =
    RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
final RegExp _uuid = RegExp(
  r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
  caseSensitive: false,
);
final RegExp _longToken = RegExp(
    r'\b(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}\b');
final RegExp _windowsHome =
    RegExp(r'([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\r\n]+', caseSensitive: false);
final RegExp _unixHome = RegExp(r'(/(?:Users|home)/)[^/\s]+');

/// [text] without URL paths and queries, credentials, tokens, email
/// addresses, ids or user names. Ordinary error text and stack frames stay.
String redactTelemetryText(String text) {
  var out = text.replaceAllMapped(_url, (m) {
    final scheme = m[1]!;
    if (scheme.toLowerCase() == 'file') return m[0]!;
    final userInfo = m[2] == null ? '' : '$redactedValue@';
    final rest = m[4]!.isEmpty ? '' : '/$redactedValue';
    return '$scheme://$userInfo${m[3]}$rest';
  });
  out = out.replaceAll(_magnet, 'magnet:$redactedValue');
  out = out.replaceAll(_jwt, '[redacted-jwt]');
  out = out.replaceAllMapped(_secretField, (m) => '${m[1]}${m[2]}$redactedValue');
  out = out.replaceAllMapped(_authScheme, (m) => '${m[1]} $redactedValue');
  out = out.replaceAll(_email, '[redacted-email]');
  out = out.replaceAll(_uuid, redactedValue);
  out = out.replaceAll(_longToken, redactedValue);
  out = out.replaceAllMapped(_windowsHome, (m) => '${m[1]}[user]');
  out = out.replaceAllMapped(_unixHome, (m) => '${m[1]}[user]');
  return out;
}

final RegExp _secretKey = RegExp(
  r'token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|cookie|credential|signature',
  caseSensitive: false,
);

/// Event properties with string values redacted and values under
/// secret-looking keys replaced entirely.
Map<String, Object?> redactTelemetryProperties(Map<String, Object?> properties) {
  return {
    for (final entry in properties.entries)
      entry.key: _secretKey.hasMatch(entry.key)
          ? redactedValue
          : (entry.value is String
              ? redactTelemetryText(entry.value as String)
              : entry.value),
  };
}
