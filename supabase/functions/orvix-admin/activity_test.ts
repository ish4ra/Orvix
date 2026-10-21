// deno test --allow-read supabase/functions/orvix-admin/
import {
  buildVerifiedVersionStats,
  countryBreakdown,
  dailyActivity,
  dataQuality,
  isOnlineSession,
  metric,
  platformBreakdown,
  sessionDurationSeconds,
  sessionStats,
  telemetryFreshness,
  uniqueInstallations,
  versionBreakdown,
} from "./activity.ts";
import { assertEquals } from "./test_assert.ts";

const NOW = Date.parse("2026-10-21T12:00:00.000Z");
const ago = (seconds: number) => new Date(NOW - seconds * 1000).toISOString();
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

Deno.test("online needs a foreground, unended session with a heartbeat under 3 minutes old", () => {
  const base = { is_foreground: true, ended_at: null };
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: ago(30) }, NOW), true);
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: ago(179) }, NOW), true);
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: ago(181) }, NOW), false, "timed out");
  assertEquals(isOnlineSession({ ...base, is_foreground: false, last_heartbeat_at: ago(10) }, NOW), false, "backgrounded");
  assertEquals(isOnlineSession({ ...base, ended_at: ago(5), last_heartbeat_at: ago(5) }, NOW), false, "ended");
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: "not a date" }, NOW), false);
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: ago(-3600) }, NOW), false, "far future");
  assertEquals(isOnlineSession({ ...base, last_heartbeat_at: ago(-60) }, NOW), true, "small skew tolerated");
});

Deno.test("freshness separates fresh, quiet, stale, empty and unknown", () => {
  assertEquals(telemetryFreshness(ago(60), NOW).state, "fresh");
  assertEquals(telemetryFreshness(ago(3600), NOW).state, "quiet");
  assertEquals(telemetryFreshness(ago(7 * 3600), NOW).state, "stale");
  assertEquals(telemetryFreshness(null, NOW).state, "none");
  assertEquals(telemetryFreshness(ago(60), NOW, true).state, "unknown");
});

Deno.test("zero, unavailable and stale are different metric states", () => {
  const fresh = telemetryFreshness(ago(30), NOW);
  assertEquals(metric(0, fresh), { value: 0, state: "ok", note: null });
  assertEquals(metric(null, fresh).state, "unavailable");
  assertEquals(metric(null, fresh).value, null);
  assertEquals(metric(0, telemetryFreshness(ago(8 * 3600), NOW)).state, "stale");
  assertEquals(metric(0, telemetryFreshness(null, NOW)).state, "no_data");
  assertEquals(metric(Number.NaN, fresh).state, "unavailable");
  const stale = telemetryFreshness(ago(8 * 3600), NOW);
  assertEquals(metric(120, stale, true).state, "ok", "all-time totals are not stale");
  assertEquals(metric(null, stale, true).state, "unavailable");
});

Deno.test("countries keep Unknown in the total", () => {
  const rows = [
    { country_code: "LK" }, { country_code: "LK" }, { country_code: "US" },
    { country_code: null }, { country_code: "XX" }, { country_code: "lk" }, {},
  ];
  const breakdown = countryBreakdown(rows);
  assertEquals(breakdown, [
    { name: "Unknown", count: 4 },
    { name: "LK", count: 2 },
    { name: "US", count: 1 },
  ]);
  assertEquals(breakdown.reduce((s, r) => s + r.count, 0), rows.length);
});

Deno.test("platform breakdown keeps TV and Mobile apart and unknowns visible", () => {
  const rows = [
    { platform: "Android TV" }, { platform: "Android TV" }, { platform: "Android Mobile" },
    { platform: "Windows" }, { platform: "iOS" }, { platform: "android" }, { platform: null },
  ];
  assertEquals(platformBreakdown(rows), [
    { name: "Android TV", count: 2 },
    { name: "Unknown", count: 2 },
    { name: "Android Mobile", count: 1 },
    { name: "iOS", count: 1 },
    { name: "Windows", count: 1 },
  ]);
});

Deno.test("versions sort semantically and carry the release channel", () => {
  const channels = new Map([["0.7.9", "stable" as const], ["0.7.10-beta.4", "prerelease" as const], ["0.7.10-beta.3", "draft" as const]]);
  const rows = [
    { app_version: "0.7.9", platform: "Android TV" },
    { app_version: "0.7.10-beta.4", platform: "Android Mobile" },
    { app_version: "0.7.10-beta.4", platform: "Windows" },
    { app_version: "0.7.10-beta.10", platform: "macOS" },
    { app_version: "0.7.10-beta.3", platform: "Android Mobile" },
    { app_version: null, platform: "iOS" },
  ];
  const result = versionBreakdown(rows, channels);
  assertEquals(result.map((r) => [r.version, r.installations, r.channel]), [
    ["0.7.10-beta.10", 1, "not_published"],
    ["0.7.10-beta.4", 2, "prerelease"],
    ["0.7.10-beta.3", 1, "draft"],
    ["0.7.9", 1, "stable"],
    ["Unknown", 1, "not_published"],
  ]);
  assertEquals(result[1].devices_by_platform, { "Android Mobile": 1, "Windows": 1 });
  assertEquals(versionBreakdown(rows, null)[0].channel, "unknown", "no GitHub data -> unknown, not guessed");
});

Deno.test("legacy session rows count distinct installations per version", () => {
  const rows = [
    { installation_id: id(1), platform: "Android TV", app_version: "0.7.9", started_at: ago(9000) },
    { installation_id: id(1), platform: "Android TV", app_version: "0.7.9", started_at: ago(8000) },
    { installation_id: id(1), platform: "Android TV", app_version: "0.7.10-beta.4", started_at: ago(100), last_heartbeat_at: ago(10) },
    { installation_id: id(2), platform: "Windows", app_version: "0.7.9+4223", started_at: ago(500) },
    { installation_id: "", platform: "Windows", app_version: "0.7.9", started_at: ago(500) },
    { installation_id: id(3), platform: "Mystery", app_version: "", started_at: ago(500) },
  ];
  const stats = buildVerifiedVersionStats(rows);
  assertEquals(stats.map((s) => [s.version, s.unique_devices]), [["0.7.10-beta.4", 1], ["0.7.9", 2]]);
  assertEquals(stats[1].devices_by_platform, { "Android TV": 1, "Windows": 1 });
  assertEquals(stats[0].last_seen_at, ago(10));
});

Deno.test("duplicated installation rows are counted once", () => {
  const rows = [
    { installation_id: id(1), last_seen_at: ago(100), platform: "Windows" },
    { installation_id: id(1), last_seen_at: ago(10), platform: "Windows" },
    { installation_id: id(2), last_seen_at: ago(10), platform: "macOS" },
  ];
  const unique = uniqueInstallations(rows);
  assertEquals(unique.length, 2);
  assertEquals(unique.find((r) => r.installation_id === id(1))!.last_seen_at, ago(10));
});

Deno.test("session durations use the last message and are capped", () => {
  assertEquals(sessionDurationSeconds({ started_at: ago(600), last_heartbeat_at: ago(0) }), 600);
  assertEquals(sessionDurationSeconds({ started_at: ago(600), ended_at: ago(300), last_heartbeat_at: ago(0) }), 300);
  assertEquals(sessionDurationSeconds({ started_at: ago(3 * 86400), last_heartbeat_at: ago(0) }), 86400);
  assertEquals(sessionDurationSeconds({ started_at: "bad" }), null);
});

Deno.test("session stats report median, single-message sessions and future timestamps", () => {
  const stats = sessionStats([
    { started_at: ago(600), last_heartbeat_at: ago(0) },
    { started_at: ago(120), last_heartbeat_at: ago(60) },
    { started_at: ago(50), last_heartbeat_at: ago(50) },
    { started_at: ago(-7200), last_heartbeat_at: ago(-7200) },
  ], NOW);
  assertEquals(stats, {
    sessions: 3,
    average_seconds: 220,
    median_seconds: 60,
    single_message_sessions: 1,
    future_timestamps: 1,
  });
  assertEquals(sessionStats([], NOW).average_seconds, null);
});

Deno.test("daily activity counts distinct installations per UTC day", () => {
  const sessions = [
    // Spans midnight UTC: active on both days.
    { installation_id: id(1), started_at: "2026-10-20T23:50:00.000Z", last_heartbeat_at: "2026-10-21T00:20:00.000Z" },
    { installation_id: id(1), started_at: "2026-10-21T08:00:00.000Z", last_heartbeat_at: "2026-10-21T09:00:00.000Z" },
    { installation_id: id(2), started_at: "2026-10-21T10:00:00.000Z", last_heartbeat_at: "2026-10-21T10:01:00.000Z" },
    { installation_id: id(3), started_at: "2026-09-01T10:00:00.000Z", last_heartbeat_at: "2026-09-01T10:01:00.000Z" },
    { installation_id: "", started_at: "2026-10-21T10:00:00.000Z" },
  ];
  const days = dailyActivity(sessions, NOW, 3);
  assertEquals(days, [
    { day: "2026-10-19", active_installations: 0, sessions_started: 0 },
    { day: "2026-10-20", active_installations: 1, sessions_started: 1 },
    { day: "2026-10-21", active_installations: 2, sessions_started: 2 },
  ]);
});

Deno.test("data quality counts unknown platforms, countries and build mismatches", () => {
  const quality = dataQuality([
    { platform: "Android Mobile", device_type: "TV", country_code: "LK", app_version: "0.7.9" },
    { platform: "Android TV", device_type: "TV", country_code: null, app_version: "0.7.9" },
    { platform: "fuchsia", country_code: "US", app_version: "" },
  ]);
  assertEquals(quality, {
    installations_considered: 3,
    unknown_platform: 1,
    unknown_platform_labels: ["fuchsia"],
    unknown_country: 1,
    form_factor_mismatch: 1,
    missing_version: 1,
  });
});
