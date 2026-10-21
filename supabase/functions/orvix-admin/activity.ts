// Measured app usage for the Control Center, computed from the rows the
// orvix-telemetry function stores.
//
// Identity: an "installation" is the random ID an Orvix install keeps in its
// settings. Reinstalling or clearing app data creates a new one, and a person
// with a phone and a TV has two. It is not a person and not a hardware
// device. Accounts are counted only for signed-in installations.
//
// Time: every timestamp is set by the server (now() / new Date() in the
// Edge Function), never by the client, so device clock skew cannot move an
// event. Daily buckets are UTC days.

import { isFormFactorMismatch, normalizePlatform } from "./platforms.ts";
import { compareVersions, versionKey } from "./versions.ts";
import type { ReleaseChannel } from "./releases.ts";

type AnyRow = Record<string, any>;

export const HEARTBEAT_INTERVAL_SECONDS = 60;
/// A foreground session is online while its newest heartbeat is younger than
/// three heartbeat intervals (one missed beat plus network delay).
export const ONLINE_WINDOW_SECONDS = 3 * HEARTBEAT_INTERVAL_SECONDS;
/// Without any telemetry for this long, zero counts are reported as stale.
export const TELEMETRY_STALE_SECONDS = 6 * 3600;
/// Allowed server clock difference before a timestamp counts as "future".
export const CLOCK_SKEW_TOLERANCE_SECONDS = 120;
/// Durations are capped so a session left open for days does not dominate.
export const MAX_SESSION_SECONDS = 24 * 3600;

export type MetricState =
  | "ok" //          value measured from fresh telemetry
  | "stale" //       measured, but no telemetry arrived for a long time
  | "no_data" //     the telemetry tables are empty
  | "unavailable"; // the query failed

export type Metric = {
  value: number | null;
  state: MetricState;
  /// Human-readable reason for a non-ok state.
  note: string | null;
};

export type TelemetryFreshness = {
  latest_telemetry_at: string | null;
  age_seconds: number | null;
  state: "fresh" | "quiet" | "stale" | "none" | "unknown";
};

function time(value: unknown): number | null {
  if (typeof value !== "string" || !value) return null;
  const ms = new Date(value).getTime();
  return Number.isFinite(ms) ? ms : null;
}

export function telemetryFreshness(
  latestTelemetryAt: string | null | undefined,
  now: number,
  queryFailed = false,
): TelemetryFreshness {
  if (queryFailed) return { latest_telemetry_at: null, age_seconds: null, state: "unknown" };
  const latest = time(latestTelemetryAt ?? null);
  if (latest === null) return { latest_telemetry_at: null, age_seconds: null, state: "none" };
  const age = Math.max(0, Math.round((now - latest) / 1000));
  return {
    latest_telemetry_at: new Date(latest).toISOString(),
    age_seconds: age,
    state: age <= 10 * 60 ? "fresh" : age <= TELEMETRY_STALE_SECONDS ? "quiet" : "stale",
  };
}

/// Wraps a count with the state that tells "0 observed" apart from
/// "could not be retrieved" and "no telemetry is arriving".
///
/// `cumulative` totals (all-time counts) stay correct when telemetry stops,
/// so they are never marked stale.
export function metric(
  value: number | null | undefined,
  freshness: TelemetryFreshness,
  cumulative = false,
): Metric {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return { value: null, state: "unavailable", note: "Unable to retrieve this metric" };
  }
  if (freshness.state === "none") {
    return { value, state: "no_data", note: "No telemetry has been received yet" };
  }
  if (freshness.state === "stale" && !cumulative) {
    return {
      value,
      state: "stale",
      note: "No telemetry received for over 6 hours; the count may be incomplete",
    };
  }
  return { value, state: "ok", note: null };
}

export function isOnlineSession(session: AnyRow, now: number): boolean {
  if (session.is_foreground !== true || session.ended_at) return false;
  const heartbeat = time(session.last_heartbeat_at);
  if (heartbeat === null) return false;
  return heartbeat >= now - ONLINE_WINDOW_SECONDS * 1000 &&
    heartbeat <= now + CLOCK_SKEW_TOLERANCE_SECONDS * 1000;
}

export function sessionDurationSeconds(session: AnyRow): number | null {
  const start = time(session.started_at);
  const end = time(session.ended_at) ?? time(session.last_heartbeat_at) ?? start;
  if (start === null || end === null) return null;
  return Math.max(0, Math.min((end - start) / 1000, MAX_SESSION_SECONDS));
}

export type Breakdown = { name: string; count: number };

function sortedBreakdown(counts: Map<string, number>): Breakdown[] {
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
}

function bump(counts: Map<string, number>, key: string) {
  counts.set(key, (counts.get(key) ?? 0) + 1);
}

/// Installations keyed once each; the newest row wins if a page boundary
/// returned the same installation twice.
export function uniqueInstallations(rows: AnyRow[]): AnyRow[] {
  const byId = new Map<string, AnyRow>();
  for (const row of rows) {
    const id = typeof row.installation_id === "string" ? row.installation_id : "";
    if (!id) continue;
    const existing = byId.get(id);
    if (!existing || (time(row.last_seen_at) ?? 0) > (time(existing.last_seen_at) ?? 0)) {
      byId.set(id, row);
    }
  }
  return [...byId.values()];
}

/// Two-letter code that names a country; "XX" is the CDN's "unknown".
export function isKnownCountry(code: unknown): code is string {
  return typeof code === "string" && /^[A-Z]{2}$/.test(code) && code !== "XX";
}

/// Sessions keyed once by session_id; rows without one are kept as they are.
export function uniqueSessions(rows: AnyRow[]): AnyRow[] {
  const seen = new Set<string>();
  return rows.filter((row) => {
    const id = typeof row.session_id === "string" ? row.session_id : "";
    if (!id) return true;
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

export function countryBreakdown(installations: AnyRow[]): Breakdown[] {
  const counts = new Map<string, number>();
  for (const row of installations) {
    bump(counts, isKnownCountry(row.country_code) ? row.country_code : "Unknown");
  }
  return sortedBreakdown(counts);
}

export function platformBreakdown(installations: AnyRow[]): Breakdown[] {
  const counts = new Map<string, number>();
  for (const row of installations) bump(counts, normalizePlatform(row.platform));
  return sortedBreakdown(counts);
}

export type VersionRow = {
  version: string;
  installations: number;
  channel: ReleaseChannel | "not_published" | "unknown";
  devices_by_platform: Record<string, number>;
};

/// Latest reported version per installation, newest version first.
export function versionBreakdown(
  installations: AnyRow[],
  channels: Map<string, ReleaseChannel> | null,
): VersionRow[] {
  const byVersion = new Map<string, VersionRow>();
  for (const row of installations) {
    const version = versionKey(row.app_version) ?? "Unknown";
    let entry = byVersion.get(version);
    if (!entry) {
      entry = {
        version,
        installations: 0,
        channel: channels === null
          ? "unknown"
          : channels.get(version) ?? "not_published",
        devices_by_platform: {},
      };
      byVersion.set(version, entry);
    }
    entry.installations++;
    const platform = normalizePlatform(row.platform);
    entry.devices_by_platform[platform] = (entry.devices_by_platform[platform] ?? 0) + 1;
  }
  return [...byVersion.values()].sort((a, b) => compareVersions(b.version, a.version));
}

export type VerifiedVersion = {
  version: string;
  unique_devices: number;
  devices_by_platform: Record<string, number>;
  last_seen_at: string | null;
};

/// Distinct installations that ever opened a session on each version.
export function buildVerifiedVersionStats(rows: AnyRow[]): VerifiedVersion[] {
  const byVersion = new Map<string, {
    installations: Set<string>;
    platforms: Map<string, Set<string>>;
    lastSeen: number | null;
  }>();

  for (const row of rows) {
    const version = versionKey(row.app_version);
    const installationId = typeof row.installation_id === "string" ? row.installation_id : "";
    if (!version || !installationId) continue;

    let entry = byVersion.get(version);
    if (!entry) {
      entry = { installations: new Set(), platforms: new Map(), lastSeen: null };
      byVersion.set(version, entry);
    }
    entry.installations.add(installationId);
    const platform = normalizePlatform(row.platform);
    if (!entry.platforms.has(platform)) entry.platforms.set(platform, new Set());
    entry.platforms.get(platform)!.add(installationId);
    const seen = time(row.last_heartbeat_at) ?? time(row.started_at);
    if (seen !== null && (entry.lastSeen === null || seen > entry.lastSeen)) entry.lastSeen = seen;
  }

  return [...byVersion.entries()]
    .map(([version, entry]) => ({
      version,
      unique_devices: entry.installations.size,
      devices_by_platform: Object.fromEntries(
        [...entry.platforms.entries()].map(([platform, ids]) => [platform, ids.size]),
      ),
      last_seen_at: entry.lastSeen === null ? null : new Date(entry.lastSeen).toISOString(),
    }))
    .sort((a, b) => compareVersions(b.version, a.version));
}

export type DailyPoint = { day: string; active_installations: number; sessions_started: number };

function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/// Distinct installations active on each UTC day (a session counts on every
/// day between its start and its last heartbeat) and sessions started.
export function dailyActivity(sessions: AnyRow[], now: number, days: number): DailyPoint[] {
  const today = Date.UTC(
    new Date(now).getUTCFullYear(),
    new Date(now).getUTCMonth(),
    new Date(now).getUTCDate(),
  );
  const first = today - (days - 1) * 86400000;
  const active = new Map<string, Set<string>>();
  const started = new Map<string, number>();
  for (let day = first; day <= today; day += 86400000) {
    active.set(utcDay(day), new Set());
    started.set(utcDay(day), 0);
  }

  for (const session of sessions) {
    const id = typeof session.installation_id === "string" ? session.installation_id : "";
    const start = time(session.started_at);
    if (!id || start === null) continue;
    const end = Math.min(
      Math.max(start, time(session.last_heartbeat_at) ?? start),
      start + MAX_SESSION_SECONDS * 1000,
      now,
    );
    const startKey = utcDay(start);
    if (started.has(startKey)) started.set(startKey, started.get(startKey)! + 1);
    const firstDay = Math.max(first, Date.UTC(
      new Date(start).getUTCFullYear(),
      new Date(start).getUTCMonth(),
      new Date(start).getUTCDate(),
    ));
    for (let day = firstDay; day <= end && day <= today; day += 86400000) {
      active.get(utcDay(day))?.add(id);
    }
  }

  return [...active.keys()].map((day) => ({
    day,
    active_installations: active.get(day)!.size,
    sessions_started: started.get(day) ?? 0,
  }));
}

export type SessionStats = {
  sessions: number;
  average_seconds: number | null;
  median_seconds: number | null;
  /// Sessions that never got a second message (no heartbeat after start).
  single_message_sessions: number;
  /// Sessions whose timestamps lie in the future beyond the skew tolerance.
  future_timestamps: number;
};

export function sessionStats(sessions: AnyRow[], now: number): SessionStats {
  const durations: number[] = [];
  let singleMessage = 0;
  let future = 0;
  for (const session of sessions) {
    const heartbeat = time(session.last_heartbeat_at);
    const start = time(session.started_at);
    if (
      (heartbeat !== null && heartbeat > now + CLOCK_SKEW_TOLERANCE_SECONDS * 1000) ||
      (start !== null && start > now + CLOCK_SKEW_TOLERANCE_SECONDS * 1000)
    ) {
      future++;
      continue;
    }
    const duration = sessionDurationSeconds(session);
    if (duration === null) continue;
    durations.push(duration);
    if (!session.ended_at && heartbeat !== null && start !== null && heartbeat - start < 1000) {
      singleMessage++;
    }
  }
  durations.sort((a, b) => a - b);
  const average = durations.length
    ? Math.round(durations.reduce((sum, value) => sum + value, 0) / durations.length)
    : null;
  const median = durations.length
    ? Math.round(
      durations.length % 2
        ? durations[(durations.length - 1) / 2]
        : (durations[durations.length / 2 - 1] + durations[durations.length / 2]) / 2,
    )
    : null;
  return {
    sessions: durations.length,
    average_seconds: average,
    median_seconds: median,
    single_message_sessions: singleMessage,
    future_timestamps: future,
  };
}

export type DataQuality = {
  installations_considered: number;
  unknown_platform: number;
  /// Up to five distinct unrecognized platform labels, truncated, so a new
  /// client label is noticed instead of silently disappearing.
  unknown_platform_labels: string[];
  unknown_country: number;
  form_factor_mismatch: number;
  missing_version: number;
};

export function dataQuality(installations: AnyRow[]): DataQuality {
  const labels = new Set<string>();
  let unknownPlatform = 0;
  let unknownCountry = 0;
  let mismatch = 0;
  let missingVersion = 0;
  for (const row of installations) {
    if (normalizePlatform(row.platform) === "Unknown") {
      unknownPlatform++;
      if (labels.size < 5) labels.add(String(row.platform ?? "(empty)").slice(0, 40));
    }
    if (!isKnownCountry(row.country_code)) unknownCountry++;
    if (isFormFactorMismatch(row.platform, row.device_type)) mismatch++;
    if (!versionKey(row.app_version)) missingVersion++;
  }
  return {
    installations_considered: installations.length,
    unknown_platform: unknownPlatform,
    unknown_platform_labels: [...labels],
    unknown_country: unknownCountry,
    form_factor_mismatch: mismatch,
    missing_version: missingVersion,
  };
}
