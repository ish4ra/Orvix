// deno test --allow-read supabase/functions/orvix-admin/
import { buildDashboard, type DashboardInputs } from "./dashboard.ts";
import type { CachedGithubResult } from "./releases.ts";
import { assert, assertEquals } from "./test_assert.ts";

const NOW = Date.parse("2026-10-21T12:00:00.000Z");
const ago = (seconds: number) => new Date(NOW - seconds * 1000).toISOString();
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const fixture = JSON.parse(
  await Deno.readTextFile(new URL("./fixtures/github_releases.json", import.meta.url)),
);

const github: CachedGithubResult = {
  ok: true,
  releases: fixture,
  fetched_at: ago(120),
  pages: 1,
  truncated: false,
  error: null,
  source: "cache",
  last_error: null,
};

const installations = [
  { installation_id: id(1), user_id: "u1", platform: "Android TV", device_type: "TV", country_code: "LK", app_version: "0.7.10-beta.4", last_seen_at: ago(30) },
  { installation_id: id(2), user_id: null, platform: "Android Mobile", device_type: "Mobile", country_code: null, app_version: "0.7.9", last_seen_at: ago(3600) },
  { installation_id: id(3), user_id: "u1", platform: "Windows", device_type: "Desktop", country_code: "US", app_version: "0.7.9", last_seen_at: ago(86400 * 3) },
];

function inputs(overrides: Partial<DashboardInputs> = {}): DashboardInputs {
  return {
    now: NOW,
    counts: {
      installations_total: 40,
      active_5m: 1,
      active_24h: 2,
      active_7d: 3,
      active_30d: 3,
      sessions_30d: 4,
      sessions_total: 90,
      errors_30d: 0,
    },
    latestTelemetryAt: { ok: true, value: ago(30) },
    onlineSessions: {
      ok: true,
      value: [
        { session_id: "s1", installation_id: id(1), user_id: "u1", is_foreground: true, ended_at: null, platform: "Android TV", app_version: "0.7.10-beta.4", started_at: ago(900), last_heartbeat_at: ago(30) },
        // Returned by a wider query window, rejected by the definition.
        { session_id: "s2", installation_id: id(2), is_foreground: true, ended_at: null, platform: "Android Mobile", app_version: "0.7.9", started_at: ago(900), last_heartbeat_at: ago(400) },
      ],
    },
    activeInstallations: { ok: true, value: installations },
    sessions30d: {
      ok: true,
      value: [
        { installation_id: id(1), started_at: ago(900), last_heartbeat_at: ago(30) },
        { installation_id: id(2), started_at: ago(3700), last_heartbeat_at: ago(3600) },
      ],
    },
    recentInstallations: { ok: true, value: installations },
    events30d: { ok: true, value: [{ event_name: "app_resumed" }, { event_name: "app_resumed" }, { event_name: "auth_signed_in" }] },
    recentErrors: { ok: true, value: [] },
    users: { ok: true, value: [{ id: "u1", email: "owner@example.com", user_metadata: { display_name: "Owner" } }] },
    versionSessions: { ok: true, value: [{ installation_id: id(1), platform: "Android TV", app_version: "0.7.10-beta.4", started_at: ago(900) }] },
    github,
    ...overrides,
  };
}

Deno.test("a healthy dashboard reports measured values with definitions", () => {
  const d = buildDashboard(inputs());
  assertEquals(d.schema_version, 2);
  assertEquals(d.activity.online_now, { value: 1, state: "ok", note: null });
  assertEquals(d.online.length, 1);
  assertEquals(d.online[0].display_name, "Owner");
  assertEquals(d.activity.signed_in_accounts_30d.value, 1);
  assertEquals(d.activity.active_24h.value, 2);
  assertEquals(d.overview.active_today, 2, "legacy key now carries the rolling 24 h count");
  assertEquals(d.overview.github_downloads, 134);
  assertEquals(d.downloads.status, "ok");
  assertEquals(d.downloads.latest_stable?.tag, "v0.7.9");
  assertEquals(d.downloads.latest_prerelease?.tag, "v0.7.10-beta.4");
  assertEquals(d.breakdowns.countries.find((c) => c.name === "Unknown")?.count, 1);
  assertEquals(d.breakdowns.versions.map((v) => [v.version, v.channel]), [["0.7.10-beta.4", "prerelease"], ["0.7.9", "stable"]]);
  assertEquals(d.versions, [{ name: "0.7.10-beta.4", count: 1 }, { name: "0.7.9", count: 2 }]);
  assertEquals(d.event_counts[0], { name: "app_resumed", count: 2 });
  assert(d.definitions.github_downloads.includes("Not installations"), "download definition");
  assertEquals(d.health.sections.counts, { status: "ok" });
});

Deno.test("zero online with fresh telemetry is an observed zero", () => {
  const d = buildDashboard(inputs({ onlineSessions: { ok: true, value: [] } }));
  assertEquals(d.activity.online_now, { value: 0, state: "ok", note: null });
});

Deno.test("a failed session query is unavailable, not zero", () => {
  const d = buildDashboard(inputs({ onlineSessions: { ok: false, error: "Query failed" } }));
  assertEquals(d.activity.online_now.value, null);
  assertEquals(d.activity.online_now.state, "unavailable");
  assertEquals(d.overview.online_now, null);
  assertEquals(d.health.sections.online_sessions.status, "unavailable");
});

Deno.test("stale telemetry flags zero counts as possibly incomplete", () => {
  const d = buildDashboard(inputs({
    latestTelemetryAt: { ok: true, value: ago(2 * 86400) },
    onlineSessions: { ok: true, value: [] },
    counts: { ...inputs().counts, active_5m: 0, active_24h: 0 },
  }));
  assertEquals(d.activity.freshness.state, "stale");
  assertEquals(d.activity.online_now.state, "stale");
  assertEquals(d.activity.active_24h.state, "stale");
  assertEquals(d.activity.installations_total.state, "ok", "cumulative totals stay ok");
});

Deno.test("empty telemetry tables report no data", () => {
  const d = buildDashboard(inputs({
    latestTelemetryAt: { ok: true, value: null },
    onlineSessions: { ok: true, value: [] },
    activeInstallations: { ok: true, value: [] },
    counts: { installations_total: 0, active_5m: 0, active_24h: 0, active_7d: 0, active_30d: 0, sessions_30d: 0, sessions_total: 0, errors_30d: 0 },
  }));
  assertEquals(d.activity.freshness.state, "none");
  assertEquals(d.activity.installations_total.state, "no_data");
  assertEquals(d.breakdowns.countries, []);
});

Deno.test("partial backend outage keeps the other sections", () => {
  const d = buildDashboard(inputs({
    counts: { ...inputs().counts, active_7d: null },
    activeInstallations: { ok: false, error: "Query failed" },
    users: { ok: false, error: "Account list unavailable" },
  }));
  assertEquals(d.activity.active_7d.state, "unavailable");
  assertEquals(d.activity.active_24h.state, "ok");
  assertEquals(d.breakdowns.status, "unavailable");
  assertEquals(d.breakdowns.countries, []);
  assertEquals(d.overview.registered_users, null);
  assertEquals(d.activity.registered_users.state, "unavailable");
  assertEquals(d.health.sections.counts, { status: "partial", unavailable: ["active_7d"] });
  assertEquals(d.downloads.status, "ok", "GitHub section is unaffected");
});

Deno.test("GitHub outage without cache: downloads unavailable, versions channel unknown", () => {
  const d = buildDashboard(inputs({
    github: {
      ok: false, releases: [], fetched_at: ago(0), pages: 0, truncated: false, source: "live",
      error: { code: "rate_limited", message: "GitHub API rate limit reached", http_status: 403, rate_limit_reset_at: null },
      last_error: { code: "rate_limited", message: "GitHub API rate limit reached", http_status: 403, rate_limit_reset_at: null },
    },
  }));
  assertEquals(d.downloads.status, "unavailable");
  assertEquals(d.downloads.totals, null);
  assertEquals(d.overview.github_downloads, null);
  assertEquals(d.downloads.error?.code, "rate_limited");
  assertEquals(d.breakdowns.versions[0].channel, "unknown");
});

Deno.test("GitHub outage with cache: stale downloads with their original time", () => {
  const d = buildDashboard(inputs({
    github: { ...github, source: "stale", fetched_at: ago(3600), last_error: { code: "timeout", message: "GitHub did not answer in time", http_status: null, rate_limit_reset_at: null } },
  }));
  assertEquals(d.downloads.status, "stale");
  assertEquals(d.downloads.fetched_at, ago(3600));
  assertEquals(d.downloads.totals?.public_app_downloads, 134);
  assertEquals(d.downloads.error?.code, "timeout");
});

Deno.test("payload exposes no IP addresses or raw secrets", () => {
  const text = JSON.stringify(buildDashboard(inputs()));
  assert(!/\b\d{1,3}(\.\d{1,3}){3}\b/.test(text.replace(/\d+\.\d+\.\d+(-[a-z]+\.\d+)?/g, "")), "no IPv4-looking values");
  assert(!text.includes("service_role"), "no service role");
});
