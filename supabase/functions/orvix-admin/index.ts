import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { buildDashboard, type CountKey, type Loaded } from "./dashboard.ts";
import { handleAdminRequest } from "./handler.ts";
import { ONLINE_WINDOW_SECONDS } from "./activity.ts";
import { fetchGithubReleases, GithubReleaseCache } from "./releases.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Optional read-only token. Without it GitHub's shared unauthenticated limit
// (60 requests/hour per egress IP) applies and draft releases stay hidden.
const githubToken = Deno.env.get("ORVIX_GITHUB_TOKEN") ?? null;

const db = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type AnyRow = Record<string, any>;

const ownerUserId = "87ac8a23-e207-408c-ab7d-65412353fc72";

// PostgREST returns at most 1000 rows per request (Supabase's default
// max-rows), whatever .limit() asks for, so row reads page explicitly and
// report when they stop at their cap.
const PAGE_SIZE = 1000;
const MAX_ROWS = 20000;
const MAX_VERSION_SESSION_ROWS = 50000;
const CACHE_TTL_MS = 10 * 60 * 1000;

const githubCache = new GithubReleaseCache(CACHE_TTL_MS);
let versionSessionsCache: { at: number; value: Loaded<AnyRow[]> } | null = null;

type PageResult = PromiseLike<{ data: AnyRow[] | null; error: unknown }>;

async function paginate(
  page: (from: number, to: number) => PageResult,
  maxRows = MAX_ROWS,
): Promise<Loaded<AnyRow[]>> {
  const rows: AnyRow[] = [];
  for (let from = 0; from < maxRows; from += PAGE_SIZE) {
    const { data, error } = await page(from, from + PAGE_SIZE - 1);
    if (error) {
      console.error("orvix admin paged read failed", error);
      return { ok: false, error: "Query failed" };
    }
    const batch = data ?? [];
    rows.push(...batch);
    if (batch.length < PAGE_SIZE) return { ok: true, value: rows, truncated: false };
  }
  return { ok: true, value: rows, truncated: true };
}

async function countRows(
  query: PromiseLike<{ count: number | null; error: unknown }>,
): Promise<number | null> {
  try {
    const { count, error } = await query;
    if (error || typeof count !== "number") {
      if (error) console.error("orvix admin count failed", error);
      return null;
    }
    return count;
  } catch (error) {
    console.error("orvix admin count failed", error);
    return null;
  }
}

async function settle<T>(work: () => Promise<Loaded<T>>): Promise<Loaded<T>> {
  try {
    return await work();
  } catch (error) {
    console.error("orvix admin read failed", error);
    return { ok: false, error: "Query failed" };
  }
}

function installationCount(sinceIso: string | null) {
  let query = db.from("orvix_analytics_installations")
    .select("installation_id", { count: "exact", head: true });
  if (sinceIso) query = query.gte("last_seen_at", sinceIso);
  return countRows(query);
}

async function loadUsers(): Promise<Loaded<AnyRow[]>> {
  const users: AnyRow[] = [];
  const perPage = 1000;
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage });
    if (error) {
      console.error("orvix admin user list failed", error);
      return { ok: false, error: "Account list unavailable" };
    }
    const batch = data?.users ?? [];
    users.push(...batch);
    if (batch.length < perPage) return { ok: true, value: users, truncated: false };
  }
  return { ok: true, value: users, truncated: true };
}

async function loadVersionSessions(now: number): Promise<Loaded<AnyRow[]>> {
  if (versionSessionsCache && now - versionSessionsCache.at < CACHE_TTL_MS) {
    return versionSessionsCache.value;
  }
  const value = await paginate(
    (from, to) =>
      db.from("orvix_analytics_sessions")
        .select("installation_id,platform,app_version,started_at,last_heartbeat_at")
        .order("started_at", { ascending: false })
        .order("session_id", { ascending: true })
        .range(from, to),
    MAX_VERSION_SESSION_ROWS,
  );
  if (value.ok) versionSessionsCache = { at: now, value };
  return value;
}

async function dashboardData() {
  const now = Date.now();
  const iso = (msAgo: number) => new Date(now - msAgo).toISOString();
  const day30 = iso(30 * 86400000);

  const countEntries: [CountKey, Promise<number | null>][] = [
    ["installations_total", installationCount(null)],
    ["active_5m", installationCount(iso(5 * 60000))],
    ["active_24h", installationCount(iso(86400000))],
    ["active_7d", installationCount(iso(7 * 86400000))],
    ["active_30d", installationCount(day30)],
    ["sessions_30d", countRows(
      db.from("orvix_analytics_sessions")
        .select("session_id", { count: "exact", head: true })
        .gte("started_at", day30),
    )],
    ["sessions_total", countRows(
      db.from("orvix_analytics_sessions")
        .select("session_id", { count: "exact", head: true }),
    )],
    ["errors_30d", countRows(
      db.from("orvix_analytics_errors")
        .select("id", { count: "exact", head: true })
        .gte("occurred_at", day30),
    )],
  ];

  const [
    countValues,
    latestTelemetryAt,
    onlineSessions,
    activeInstallations,
    sessions30d,
    recentInstallations,
    events30d,
    recentErrors,
    users,
    versionSessions,
    github,
  ] = await Promise.all([
    Promise.all(countEntries.map(([, promise]) => promise)),
    settle<string | null>(async () => {
      const { data, error } = await db.from("orvix_analytics_installations")
        .select("last_seen_at")
        .order("last_seen_at", { ascending: false })
        .limit(1);
      if (error) throw error;
      return { ok: true, value: data?.[0]?.last_seen_at ?? null };
    }),
    settle(async () => {
      const { data, error } = await db.from("orvix_analytics_sessions")
        .select("*")
        .eq("is_foreground", true)
        .is("ended_at", null)
        .gte("last_heartbeat_at", iso(ONLINE_WINDOW_SECONDS * 1000))
        .order("last_heartbeat_at", { ascending: false })
        .limit(PAGE_SIZE);
      if (error) throw error;
      return { ok: true, value: data ?? [] };
    }),
    settle(() =>
      paginate((from, to) =>
        db.from("orvix_analytics_installations")
          .select("*")
          .gte("last_seen_at", day30)
          // Stable key only: every heartbeat moves last_seen_at, which would
          // shift rows between pages. Consumers aggregate, so order is moot.
          .order("installation_id", { ascending: true })
          .range(from, to)
      )
    ),
    settle(() =>
      paginate((from, to) =>
        db.from("orvix_analytics_sessions")
          .select("session_id,installation_id,started_at,last_heartbeat_at,ended_at")
          .gte("started_at", day30)
          .order("started_at", { ascending: false })
          .order("session_id", { ascending: true })
          .range(from, to)
      )
    ),
    settle(() =>
      paginate(
        (from, to) =>
          db.from("orvix_analytics_installations")
            .select("*")
            .order("last_seen_at", { ascending: false })
            .order("installation_id", { ascending: true })
            .range(from, to),
        // Newest first for the table and each account's latest install; a
        // heartbeat during paging can still shift a row, which only affects
        // this display list.
        5000,
      )
    ),
    settle(() =>
      paginate((from, to) =>
        db.from("orvix_analytics_events")
          .select("event_name")
          .gte("occurred_at", day30)
          .order("id", { ascending: false })
          .range(from, to)
      )
    ),
    settle(async () => {
      const { data, error } = await db.from("orvix_analytics_errors")
        .select("*")
        .order("occurred_at", { ascending: false })
        .limit(100);
      if (error) throw error;
      return { ok: true, value: data ?? [] };
    }),
    settle(loadUsers),
    settle(() => loadVersionSessions(now)),
    githubCache.get(() => fetchGithubReleases({ repo: "ish4ra/Orvix", token: githubToken })),
  ]);

  const counts = Object.fromEntries(
    countEntries.map(([key], index) => [key, countValues[index]]),
  ) as Record<CountKey, number | null>;

  return buildDashboard({
    now,
    counts,
    latestTelemetryAt,
    onlineSessions,
    activeInstallations,
    sessions30d,
    recentInstallations,
    events30d,
    recentErrors,
    users,
    versionSessions,
    github,
  });
}

Deno.serve((req: Request) =>
  handleAdminRequest(req, {
    async isOwner(token) {
      const { data, error } = await db.auth.getUser(token);
      return !error && data.user?.id === ownerUserId;
    },
    loadDashboard: dashboardData,
    log: (message, error) => console.error(message, error),
  })
);
