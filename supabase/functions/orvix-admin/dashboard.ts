// Assembles the Control Center payload from independently loaded parts.
// Every part can fail on its own; a failure marks that part unavailable
// instead of failing the whole dashboard or turning into a zero.

import {
  buildVerifiedVersionStats,
  countryBreakdown,
  dailyActivity,
  dataQuality,
  isOnlineSession,
  metric,
  ONLINE_WINDOW_SECONDS,
  platformBreakdown,
  sessionStats,
  telemetryFreshness,
  uniqueInstallations,
  versionBreakdown,
} from "./activity.ts";
import {
  type CachedGithubResult,
  releaseChannelIndex,
  type ReleaseSummary,
  summarizeReleases,
} from "./releases.ts";

type AnyRow = Record<string, any>;

export type Loaded<T> =
  | { ok: true; value: T; truncated?: boolean }
  | { ok: false; error: string };

export type CountKey =
  | "installations_total"
  | "active_5m"
  | "active_24h"
  | "active_7d"
  | "active_30d"
  | "sessions_30d"
  | "sessions_total"
  | "errors_30d";

export type DashboardInputs = {
  now: number;
  counts: Record<CountKey, number | null>;
  latestTelemetryAt: Loaded<string | null>;
  onlineSessions: Loaded<AnyRow[]>;
  activeInstallations: Loaded<AnyRow[]>;
  sessions30d: Loaded<AnyRow[]>;
  recentInstallations: Loaded<AnyRow[]>;
  events30d: Loaded<AnyRow[]>;
  recentErrors: Loaded<AnyRow[]>;
  users: Loaded<AnyRow[]>;
  versionSessions: Loaded<AnyRow[]>;
  github: CachedGithubResult;
};

/// Shown as tooltips and legends; the page renders these, so the wording
/// lives next to the code that computes the numbers.
export const METRIC_DEFINITIONS: Record<string, string> = {
  online_now:
    `Foreground app sessions whose latest heartbeat is under ${ONLINE_WINDOW_SECONDS / 60} minutes old and that have not ended. The app sends a heartbeat every 60 seconds while it is on screen. It does not show whether someone is watching.`,
  active_5m:
    "Installations that sent any telemetry (start, heartbeat, background, event) in the last 5 minutes.",
  active_24h: "Installations that sent any telemetry in the last 24 hours (rolling, not a calendar day).",
  active_7d: "Installations that sent any telemetry in the last 7 days.",
  active_30d: "Installations that sent any telemetry in the last 30 days.",
  installations:
    "Random installation IDs that have reported at least once. Reinstalling or clearing app data creates a new ID, and each Orvix build on each device has its own, so this is not a count of people or devices.",
  signed_in_accounts_30d:
    "Distinct Orvix accounts signed in on an installation active in the last 30 days. Signed-out use is not included.",
  sessions_30d: "App sessions started in the last 30 days. A session starts at app launch, or on return after 30 minutes in the background (newer clients).",
  sessions_total: "All recorded app sessions.",
  avg_session:
    "Average session length over sessions started in the last 30 days: from start to the last message, capped at 24 hours.",
  github_downloads:
    "GitHub release asset download counts for public (non-draft) app releases. Includes manual downloads, re-downloads, in-app update downloads and CI or test downloads. Not installations and not unique users.",
  countries:
    "Approximate network country of installations active in the last 30 days, from the request's network location. VPNs and proxies change it. Unknown means no country could be established.",
  platforms:
    "Orvix build reported by installations active in the last 30 days. Android TV means the TV build, Android Mobile the phone build, regardless of hardware.",
  versions:
    "Latest app version reported by each installation active in the last 30 days.",
  verified_versions:
    "Distinct installations that opened at least one session on each version, all time.",
};

function rows(loaded: Loaded<AnyRow[]>): AnyRow[] {
  return loaded.ok ? loaded.value : [];
}

function section(loaded: Loaded<unknown>) {
  return loaded.ok
    ? { status: "ok", truncated: loaded.truncated === true }
    : { status: "unavailable", error: loaded.error };
}

export function nameForUser(user: AnyRow | undefined) {
  if (!user) return null;
  const meta = user.user_metadata ?? {};
  return meta.display_name ?? meta.full_name ?? meta.name ??
    (typeof user.email === "string" ? user.email.split("@")[0] : null);
}

export function friendlyDeviceName(
  manufacturer: unknown,
  model: unknown,
  type: unknown,
) {
  const make = typeof manufacturer === "string" ? manufacturer.trim() : "";
  const rawModel = typeof model === "string" ? model.trim() : "";
  const normalizedModel = rawModel.toUpperCase();

  const s24UltraModels = new Set([
    "SM-S928B",
    "SM-S928U",
    "SM-S928U1",
    "SM-S928W",
    "SM-S928N",
    "SM-S9280",
  ]);
  if (s24UltraModels.has(normalizedModel)) {
    return "Samsung Galaxy S24 Ultra";
  }

  if (
    normalizedModel.startsWith("MIBOX") ||
    ["MDZ-16-AB", "MDZ-22-AB", "MDZ-28-AA"].includes(normalizedModel)
  ) {
    return "Xiaomi Mi Box";
  }

  if (make && rawModel) {
    if (rawModel.toLowerCase().includes(make.toLowerCase())) return rawModel;
    const prettyMake = make.charAt(0).toUpperCase() + make.slice(1);
    return `${prettyMake} ${rawModel}`;
  }

  if (rawModel) return rawModel;
  if (make) return make;
  return typeof type === "string" && type.trim() ? type.trim() : "Unknown device";
}

function latestOf(releases: ReleaseSummary[], channel: "stable" | "prerelease") {
  const release = releases.find((r) => r.release_kind === "app" && r.channel === channel);
  if (!release) return null;
  return {
    tag: release.tag,
    published_at: release.published_at,
    total_downloads: release.total_downloads,
    downloads_by_platform: release.downloads_by_platform,
  };
}

export function buildDashboard(input: DashboardInputs) {
  const { now, counts } = input;
  const freshness = telemetryFreshness(
    input.latestTelemetryAt.ok ? input.latestTelemetryAt.value : null,
    now,
    !input.latestTelemetryAt.ok,
  );

  const users = rows(input.users);
  const usersById = new Map(users.map((user) => [user.id, user]));
  const recentInstallations = rows(input.recentInstallations);
  const installationById = new Map(
    recentInstallations.map((row) => [row.installation_id, row]),
  );
  const activeInstallations = uniqueInstallations(rows(input.activeInstallations));
  const activeById = new Map(activeInstallations.map((row) => [row.installation_id, row]));

  // Online sessions are re-checked here so the definition is applied in one
  // place even if the query window is wider.
  const onlineSessions = rows(input.onlineSessions).filter((s) => isOnlineSession(s, now));
  const online = onlineSessions.map((session) => {
    const installation = activeById.get(session.installation_id) ??
      installationById.get(session.installation_id);
    const user = session.user_id ? usersById.get(session.user_id) : undefined;
    return {
      session_id: session.session_id,
      installation_id: session.installation_id,
      user_id: session.user_id,
      display_name: nameForUser(user),
      email: user?.email ?? null,
      country_code: session.country_code ?? installation?.country_code ?? null,
      platform: session.platform,
      app_version: session.app_version,
      build_number: session.build_number,
      os_version: installation?.os_version ?? null,
      locale: installation?.locale ?? null,
      is_tv: installation?.is_tv === true,
      device_manufacturer: installation?.device_manufacturer ?? null,
      device_model: installation?.device_model ?? null,
      device_type: installation?.device_type ?? null,
      device_display_name: friendlyDeviceName(
        installation?.device_manufacturer,
        installation?.device_model,
        installation?.device_type,
      ),
      started_at: session.started_at,
      last_heartbeat_at: session.last_heartbeat_at,
    };
  });

  const sessions30d = rows(input.sessions30d);
  const stats = sessionStats(sessions30d, now);

  const github = input.github;
  const summary = summarizeReleases(github.releases);
  const githubAvailable = github.ok || github.source === "stale";
  const channels = githubAvailable ? releaseChannelIndex(summary.releases) : null;

  const onlineMetric = input.onlineSessions.ok
    ? metric(online.length, freshness)
    : metric(null, freshness);
  const onlineInstallations = input.onlineSessions.ok
    ? metric(new Set(online.map((row) => row.installation_id)).size, freshness)
    : metric(null, freshness);

  const signedInAccounts = input.activeInstallations.ok
    ? metric(
      new Set(activeInstallations.map((row) => row.user_id).filter(Boolean)).size,
      freshness,
    )
    : metric(null, freshness);

  const avgMetric = input.sessions30d.ok
    ? metric(stats.average_seconds ?? 0, freshness)
    : metric(null, freshness);

  const versionRows = input.activeInstallations.ok
    ? versionBreakdown(activeInstallations, channels)
    : [];

  const events = rows(input.events30d);
  const eventCounts = new Map<string, number>();
  for (const event of events) {
    const name = String(event.event_name ?? "Unknown");
    eventCounts.set(name, (eventCounts.get(name) ?? 0) + 1);
  }

  const installationsForUsers = recentInstallations;
  const userRows = users.map((user) => {
    const owned = installationsForUsers.filter((row) => row.user_id === user.id);
    const latest = owned[0];
    return {
      id: user.id,
      display_name: nameForUser(user),
      email: user.email,
      created_at: user.created_at,
      last_sign_in_at: user.last_sign_in_at,
      email_confirmed_at: user.email_confirmed_at,
      installations: owned.length,
      last_active_at: latest?.last_seen_at ?? null,
      country_code: latest?.country_code ?? null,
      platform: latest?.platform ?? null,
      device_display_name: friendlyDeviceName(
        latest?.device_manufacturer,
        latest?.device_model,
        latest?.device_type,
      ),
      app_version: latest?.app_version ?? null,
    };
  });

  const downloadsStatus = github.ok && github.source !== "stale"
    ? "ok"
    : github.source === "stale"
    ? "stale"
    : "unavailable";

  const breakdownRows = activeInstallations;
  const countries = input.activeInstallations.ok ? countryBreakdown(breakdownRows) : [];
  const platforms = input.activeInstallations.ok ? platformBreakdown(breakdownRows) : [];

  return {
    schema_version: 2,
    generated_at: new Date(now).toISOString(),
    definitions: METRIC_DEFINITIONS,

    // Legacy shape (schema 1), kept so an older copy of the dashboard page
    // keeps rendering. Values follow the corrected definitions above; a
    // number is null when it could not be retrieved.
    overview: {
      online_now: onlineMetric.value,
      registered_users: input.users.ok ? users.length : null,
      known_installations: counts.installations_total,
      active_today: counts.active_24h,
      active_7d: counts.active_7d,
      active_30d: counts.active_30d,
      sessions_30d: counts.sessions_30d,
      avg_session_seconds: avgMetric.value,
      errors_30d: counts.errors_30d,
      github_downloads: githubAvailable ? summary.totals.public_app_downloads : null,
    },
    online,
    countries,
    platforms,
    versions: versionRows.map((row) => ({ name: row.version, count: row.installations })),
    event_counts: [...eventCounts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count),
    users: userRows,
    installations: recentInstallations.slice(0, 500).map((row) => ({
      ...row,
      device_display_name: friendlyDeviceName(
        row.device_manufacturer,
        row.device_model,
        row.device_type,
      ),
    })),
    recent_errors: rows(input.recentErrors).slice(0, 100),
    releases: summary.releases,
    verified_versions: input.versionSessions.ok
      ? buildVerifiedVersionStats(rows(input.versionSessions))
      : [],

    activity: {
      freshness,
      online_now: onlineMetric,
      online_installations: onlineInstallations,
      active_5m: metric(counts.active_5m, freshness),
      active_24h: metric(counts.active_24h, freshness),
      active_7d: metric(counts.active_7d, freshness),
      active_30d: metric(counts.active_30d, freshness),
      installations_total: metric(counts.installations_total, freshness, true),
      signed_in_accounts_30d: signedInAccounts,
      registered_users: input.users.ok
        ? { value: users.length, state: "ok", note: null }
        : { value: null, state: "unavailable", note: "Unable to retrieve accounts" },
      sessions_30d: metric(counts.sessions_30d, freshness),
      sessions_total: metric(counts.sessions_total, freshness, true),
      errors_30d: metric(counts.errors_30d, freshness),
      avg_session_seconds: avgMetric,
      median_session_seconds: input.sessions30d.ok
        ? metric(stats.median_seconds ?? 0, freshness)
        : metric(null, freshness),
      daily: input.sessions30d.ok ? dailyActivity(sessions30d, now, 30) : [],
      daily_truncated: input.sessions30d.ok && input.sessions30d.truncated === true,
    },

    breakdowns: {
      window_days: 30,
      status: input.activeInstallations.ok ? "ok" : "unavailable",
      truncated: input.activeInstallations.ok && input.activeInstallations.truncated === true,
      installations: activeInstallations.length,
      countries,
      platforms,
      versions: versionRows,
      release_channels_known: channels !== null,
    },

    downloads: {
      status: downloadsStatus,
      source: github.source,
      fetched_at: github.fetched_at,
      error: github.last_error ?? github.error,
      pages: github.pages,
      truncated: github.truncated,
      totals: githubAvailable ? summary.totals : null,
      latest_stable: githubAvailable ? latestOf(summary.releases, "stable") : null,
      latest_prerelease: githubAvailable ? latestOf(summary.releases, "prerelease") : null,
    },

    health: {
      freshness,
      sections: {
        counts: Object.values(counts).some((value) => value === null)
          ? {
            status: "partial",
            unavailable: Object.entries(counts)
              .filter(([, value]) => value === null)
              .map(([key]) => key),
          }
          : { status: "ok" },
        latest_telemetry: section(input.latestTelemetryAt),
        online_sessions: section(input.onlineSessions),
        active_installations: section(input.activeInstallations),
        sessions_30d: section(input.sessions30d),
        recent_installations: section(input.recentInstallations),
        events_30d: section(input.events30d),
        recent_errors: section(input.recentErrors),
        users: section(input.users),
        version_sessions: section(input.versionSessions),
        github: {
          status: downloadsStatus,
          source: github.source,
          error: github.last_error ?? github.error,
        },
      },
      data_quality: dataQuality(activeInstallations),
      session_quality: {
        sessions_30d_considered: stats.sessions + stats.future_timestamps,
        single_message_sessions: stats.single_message_sessions,
        future_timestamps: stats.future_timestamps,
      },
    },
  };
}
