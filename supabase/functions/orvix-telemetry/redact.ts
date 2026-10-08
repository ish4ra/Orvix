// Removes secrets and personal data from analytics and error text before it
// is stored. The app applies the same rules before sending
// (lib/services/telemetry_redaction.dart); this copy also covers older app
// versions. Both are checked against redaction_cases.json.

export const REDACTED = "[redacted]";

// Only the scheme and host of a URL are kept. file: URLs (stack frames) keep
// their path; the home directory rule below still applies to them.
const URL_RE =
  /\b([a-z][a-z0-9+.-]*):\/\/([^\s\/?#"'<>@]*@)?([^\s\/?#"'<>]*)([^\s"'<>]*)/gi;
const MAGNET_RE = /magnet:\?[^\s"'<>]+/gi;
const JWT_RE = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*/g;
const SECRET_FIELD_RE =
  /\b([\w.-]*(?:token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|cookie|session|credential|signature|realdebrid|alldebrid|premiumize|debridlink|torbox|offcloud|putio|easydebrid|pikpak)[\w.-]*)(["']?\s*[:=]\s*["']?)(?!\[redacted)((?:(?:bearer|basic)\s+)?[^\s"'&,;|}\]]+)/gi;
const AUTH_SCHEME_RE = /\b(bearer|basic)\s+[A-Za-z0-9._~+\/=-]{8,}/gi;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const UUID_RE =
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const LONG_TOKEN_RE =
  /\b(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}\b/g;
const WINDOWS_HOME_RE = /([A-Za-z]:[\\\/]+Users[\\\/]+)[^\\\/\r\n]+/gi;
const UNIX_HOME_RE = /(\/(?:Users|home)\/)[^\/\s]+/g;

/** text without URL paths and queries, credentials, tokens, email addresses, ids or user names. */
export function redactText(text: string): string {
  return text
    .replace(URL_RE, (all, scheme: string, userInfo: string | undefined, host: string, rest: string) => {
      if (scheme.toLowerCase() === "file") return all;
      return `${scheme}://${userInfo ? `${REDACTED}@` : ""}${host}${rest ? `/${REDACTED}` : ""}`;
    })
    .replace(MAGNET_RE, `magnet:${REDACTED}`)
    .replace(JWT_RE, "[redacted-jwt]")
    .replace(SECRET_FIELD_RE, (_all, key: string, separator: string) => `${key}${separator}${REDACTED}`)
    .replace(AUTH_SCHEME_RE, (_all, scheme: string) => `${scheme} ${REDACTED}`)
    .replace(EMAIL_RE, "[redacted-email]")
    .replace(UUID_RE, REDACTED)
    .replace(LONG_TOKEN_RE, REDACTED)
    .replace(WINDOWS_HOME_RE, (_all, prefix: string) => `${prefix}[user]`)
    .replace(UNIX_HOME_RE, (_all, prefix: string) => `${prefix}[user]`);
}

const SECRET_KEY_RE =
  /token|secret|password|passwd|pwd|api[_-]?key|apikey|auth|cookie|credential|signature/i;

/** Event properties with string values redacted and secret-looking keys blanked. */
export function redactProperties(properties: Record<string, unknown>): Record<string, unknown> {
  const output: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(properties)) {
    output[key] = SECRET_KEY_RE.test(key)
      ? REDACTED
      : typeof value === "string"
      ? redactText(value)
      : value;
  }
  return output;
}
