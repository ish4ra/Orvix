// Prints a realistic dashboard payload (built by the real buildDashboard)
// for dashboard_e2e.cjs. Usage: deno run --allow-read e2e/payload.ts
import { buildDashboard } from "../dashboard.ts";

const fixture = JSON.parse(
  await Deno.readTextFile(new URL("../fixtures/github_releases.json", import.meta.url)),
);
const now = Date.now();
const ago = (s: number) => new Date(now - s * 1000).toISOString();
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const platforms = ["Android Mobile", "Android TV", "Windows", "macOS", "iOS"];
const installations = Array.from({ length: 12 }, (_, i) => ({
  installation_id: id(i),
  user_id: i === 0 ? "u1" : null,
  platform: platforms[i % 5],
  device_type: i % 5 === 1 ? "TV" : "Mobile",
  country_code: [null, "LK", "US"][i % 3],
  app_version: ["0.7.9", "0.7.10-beta.4"][i % 2],
  last_seen_at: ago(i * 600),
}));
const sessions = installations.map((row, i) => ({
  session_id: `s${i}`,
  installation_id: row.installation_id,
  started_at: ago(i * 600 + 300),
  last_heartbeat_at: ago(i * 600),
}));

console.log(JSON.stringify(buildDashboard({
  now,
  counts: {
    installations_total: 30, active_5m: 1, active_24h: 12, active_7d: 12, active_30d: 12,
    sessions_30d: 12, sessions_total: 80, errors_30d: 0,
  },
  latestTelemetryAt: { ok: true, value: ago(10) },
  onlineSessions: {
    ok: true,
    value: [{ ...sessions[0], user_id: "u1", is_foreground: true, ended_at: null, platform: "Android TV", app_version: "0.7.10-beta.4" }],
  },
  activeInstallations: { ok: true, value: installations },
  sessions30d: { ok: true, value: sessions },
  recentInstallations: { ok: true, value: installations },
  events30d: { ok: true, value: [{ event_name: "app_resumed" }] },
  recentErrors: { ok: true, value: [] },
  users: { ok: true, value: [{ id: "u1", email: "owner@example.com", user_metadata: { display_name: "Owner" } }] },
  versionSessions: { ok: true, value: sessions.map((s, i) => ({ ...s, platform: platforms[i % 5], app_version: installations[i].app_version })) },
  github: { ok: true, releases: fixture, fetched_at: ago(60), pages: 1, truncated: false, error: null, source: "live", last_error: null },
})));
