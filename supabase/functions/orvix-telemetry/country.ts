// When the telemetry function looks up the network country, and which value
// it keeps.

/// A new session refreshes the network country (it can change between
/// sessions). A missing country is retried on any message except
/// heartbeats, so an unresolvable network does not trigger a third-party
/// lookup every 60 seconds.
export function shouldRefreshCountry(
  type: string,
  existingCountry: string | null | undefined,
): boolean {
  return type === "session_start" || (!existingCountry && type !== "heartbeat");
}

/// A failed lookup keeps the country already stored for the installation.
export function chooseCountry(
  resolved: string | null | undefined,
  existing: string | null | undefined,
): string | null {
  return resolved ?? existing ?? null;
}
