import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const db = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

type AnyRow = Record<string, any>;

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function uniqueCount(rows: AnyRow[], key: string): number {
  return new Set(rows.map((row) => row[key]).filter(Boolean)).size;
}

function countBy(rows: AnyRow[], key: string) {
  const counts = new Map<string, number>();
  for (const row of rows) {
    const value = String(row[key] ?? "Unknown");
    counts.set(value, (counts.get(value) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count);
}

function nameForUser(user: AnyRow | undefined) {
  if (!user) return null;
  const meta = user.user_metadata ?? {};
  return meta.display_name ?? meta.full_name ?? meta.name ??
    (typeof user.email === "string" ? user.email.split("@")[0] : null);
}

async function requireAdmin(req: Request) {
  const auth = req.headers.get("authorization");
  if (!auth?.toLowerCase().startsWith("bearer ")) return null;
  const token = auth.slice(7).trim();
  if (!token) return null;

  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return null;

  const { data: admin } = await db
    .from("orvix_admins")
    .select("user_id")
    .eq("user_id", data.user.id)
    .maybeSingle();

  return admin ? data.user : null;
}

async function loadGithubReleases() {
  try {
    const response = await fetch(
      "https://api.github.com/repos/ish4ra/Orvix/releases?per_page=30",
      {
        headers: {
          Accept: "application/vnd.github+json",
          "User-Agent": "Orvix-Control-Center",
        },
        signal: AbortSignal.timeout(3000),
      },
    );
    if (!response.ok) return [];
    const releases = await response.json();
    return (Array.isArray(releases) ? releases : []).map((release: AnyRow) => ({
      tag: release.tag_name,
      name: release.name,
      published_at: release.published_at,
      prerelease: release.prerelease === true,
      draft: release.draft === true,
      total_downloads: Array.isArray(release.assets)
        ? release.assets.reduce(
            (sum: number, asset: AnyRow) =>
              sum + Number(asset.download_count ?? 0),
            0,
          )
        : 0,
      assets: Array.isArray(release.assets)
        ? release.assets.map((asset: AnyRow) => ({
            name: asset.name,
            downloads: Number(asset.download_count ?? 0),
            size: Number(asset.size ?? 0),
          }))
        : [],
    }));
  } catch {
    return [];
  }
}

async function dashboardData() {
  const thirtyDaysAgo = new Date(Date.now() - 30 * 86400000).toISOString();

  const [
    installationsResult,
    sessionsResult,
    eventsResult,
    errorsResult,
    usersResult,
    releases,
  ] = await Promise.all([
    db.from("orvix_analytics_installations").select("*")
      .order("last_seen_at", { ascending: false }).limit(10000),
    db.from("orvix_analytics_sessions").select("*")
      .gte("started_at", thirtyDaysAgo)
      .order("started_at", { ascending: false }).limit(10000),
    db.from("orvix_analytics_events").select("*")
      .gte("occurred_at", thirtyDaysAgo)
      .order("occurred_at", { ascending: false }).limit(5000),
    db.from("orvix_analytics_errors").select("*")
      .gte("occurred_at", thirtyDaysAgo)
      .order("occurred_at", { ascending: false }).limit(500),
    db.auth.admin.listUsers({ page: 1, perPage: 1000 }),
    loadGithubReleases(),
  ]);

  for (const result of [
    installationsResult,
    sessionsResult,
    eventsResult,
    errorsResult,
  ]) {
    if (result.error) throw result.error;
  }

  const installations = installationsResult.data ?? [];
  const sessions = sessionsResult.data ?? [];
  const events = eventsResult.data ?? [];
  const errors = errorsResult.data ?? [];
  const users = usersResult.data?.users ?? [];
  const usersById = new Map(users.map((user: AnyRow) => [user.id, user]));

  const now = Date.now();
  const onlineCutoff = now - 2 * 60 * 1000;
  const todayCutoff = new Date();
  todayCutoff.setHours(0, 0, 0, 0);
  const day7Cutoff = now - 7 * 86400000;
  const day30Cutoff = now - 30 * 86400000;

  const onlineSessions = sessions.filter(
    (session: AnyRow) =>
      session.is_foreground === true &&
      !session.ended_at &&
      new Date(session.last_heartbeat_at).getTime() >= onlineCutoff,
  );

  const durationSeconds = sessions.map((session: AnyRow) => {
    const start = new Date(session.started_at).getTime();
    const end = new Date(
      session.ended_at ?? session.last_heartbeat_at ?? session.started_at,
    ).getTime();
    return Math.max(0, Math.min((end - start) / 1000, 24 * 3600));
  }).filter((value: number) => Number.isFinite(value));

  const avgSessionSeconds = durationSeconds.length
    ? Math.round(
        durationSeconds.reduce(
          (sum: number, value: number) => sum + value,
          0,
        ) / durationSeconds.length,
      )
    : 0;

  const online = onlineSessions.map((session: AnyRow) => {
    const installation = installations.find(
      (row: AnyRow) => row.installation_id === session.installation_id,
    );
    const user = session.user_id
      ? usersById.get(session.user_id)
      : undefined;
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
      started_at: session.started_at,
      last_heartbeat_at: session.last_heartbeat_at,
    };
  });

  const userRows = users.map((user: AnyRow) => {
    const ownedInstalls = installations.filter(
      (installation: AnyRow) => installation.user_id === user.id,
    );
    const latest = ownedInstalls[0];
    return {
      id: user.id,
      display_name: nameForUser(user),
      email: user.email,
      created_at: user.created_at,
      last_sign_in_at: user.last_sign_in_at,
      email_confirmed_at: user.email_confirmed_at,
      installations: ownedInstalls.length,
      last_active_at: latest?.last_seen_at ?? null,
      country_code: latest?.country_code ?? null,
      platform: latest?.platform ?? null,
      app_version: latest?.app_version ?? null,
    };
  });

  const releaseDownloads = releases.reduce(
    (sum: number, release: AnyRow) =>
      sum + Number(release.total_downloads ?? 0),
    0,
  );

  return {
    generated_at: new Date().toISOString(),
    overview: {
      online_now: online.length,
      registered_users: users.length,
      known_installations: installations.length,
      active_today: uniqueCount(
        installations.filter(
          (row: AnyRow) =>
            new Date(row.last_seen_at).getTime() >= todayCutoff.getTime(),
        ),
        "installation_id",
      ),
      active_7d: uniqueCount(
        installations.filter(
          (row: AnyRow) =>
            new Date(row.last_seen_at).getTime() >= day7Cutoff,
        ),
        "installation_id",
      ),
      active_30d: uniqueCount(
        installations.filter(
          (row: AnyRow) =>
            new Date(row.last_seen_at).getTime() >= day30Cutoff,
        ),
        "installation_id",
      ),
      sessions_30d: sessions.length,
      avg_session_seconds: avgSessionSeconds,
      errors_30d: errors.length,
      github_downloads: releaseDownloads,
    },
    online,
    countries: countBy(installations, "country_code"),
    platforms: countBy(installations, "platform"),
    versions: countBy(installations, "app_version"),
    event_counts: countBy(events, "event_name"),
    users: userRows,
    installations: installations.slice(0, 500),
    recent_errors: errors.slice(0, 100),
    recent_events: events.slice(0, 100),
    releases,
  };
}

const dashboardHtml = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Orvix Control Center</title>
  <style>
    :root{color-scheme:dark;--bg:#050806;--surface:#0B0F0C;--card:#0D120E;--line:#1B2A1C;--lime:#B9FF45;--lime2:#CBFF75;--muted:#8EA18E;--danger:#ff7272}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:#edf5ed;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    button,input{font:inherit}.hidden{display:none!important}.wrap{max-width:1500px;margin:auto;padding:24px}.brand{display:flex;align-items:center;gap:12px;font-weight:900;font-size:22px}.dot{width:12px;height:12px;border-radius:50%;background:var(--lime);box-shadow:0 0 20px #b9ff4566}
    .top{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-bottom:22px}.sub{color:var(--muted);font-size:13px}.btn{background:var(--lime);color:#081006;border:0;border-radius:12px;padding:10px 14px;font-weight:850;cursor:pointer}.btn.secondary{background:#162018;color:var(--lime2);border:1px solid #29442a}
    .login{max-width:430px;margin:12vh auto;padding:28px;background:var(--card);border:1px solid var(--line);border-radius:22px}.login h1{margin-top:0}.login input{width:100%;margin:7px 0;padding:13px 14px;border-radius:12px;border:1px solid #263627;background:#0f1510;color:white}.login .btn{width:100%;margin-top:10px}.err{color:var(--danger);min-height:20px;font-size:13px}
    .cards{display:grid;grid-template-columns:repeat(8,minmax(135px,1fr));gap:12px}.card,.panel{background:var(--card);border:1px solid var(--line);border-radius:18px}.card{padding:16px}.metric{font-size:28px;font-weight:900;margin-top:8px}.label{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.09em}
    .grid2{display:grid;grid-template-columns:1.2fr .8fr;gap:14px;margin-top:14px}.grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:14px;margin-top:14px}.panel{padding:18px;min-width:0}.panel h2{font-size:16px;margin:0 0 14px}.tableWrap{overflow:auto;max-height:430px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:10px 9px;border-bottom:1px solid #172218;white-space:nowrap}th{color:var(--muted);font-weight:700;position:sticky;top:0;background:var(--card)}.online{color:var(--lime2);font-weight:800}
    .bars{display:grid;gap:10px}.barRow{display:grid;grid-template-columns:minmax(90px,180px) 1fr 48px;gap:10px;align-items:center}.barTrack{height:8px;background:#141d15;border-radius:20px;overflow:hidden}.barFill{height:100%;background:var(--lime);border-radius:20px}.barName{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}.barCount{text-align:right;color:var(--muted);font-variant-numeric:tabular-nums}
    .pill{display:inline-flex;align-items:center;padding:3px 8px;border-radius:999px;background:#152116;color:#cfff91;font-size:11px;font-weight:750}.danger{color:var(--danger)}.sectionTitle{margin:26px 0 10px;font-size:12px;color:var(--muted);font-weight:850;letter-spacing:.12em;text-transform:uppercase}.empty{color:var(--muted);padding:14px 0}
    @media(max-width:1200px){.cards{grid-template-columns:repeat(4,1fr)}}@media(max-width:850px){.cards{grid-template-columns:repeat(2,1fr)}.grid2,.grid3{grid-template-columns:1fr}.wrap{padding:16px}.top{align-items:flex-start;flex-direction:column}}
  </style>
</head>
<body>
  <div id="login" class="login">
    <div class="brand"><span class="dot"></span>Orvix Control Center</div>
    <p class="sub">Private owner analytics. Sign in with an authorized Orvix account.</p>
    <input id="email" type="email" placeholder="Email" autocomplete="username">
    <input id="password" type="password" placeholder="Password" autocomplete="current-password">
    <button id="loginBtn" class="btn">Sign in</button>
    <div id="loginError" class="err"></div>
  </div>
  <main id="app" class="wrap hidden">
    <div class="top">
      <div><div class="brand"><span class="dot"></span>Orvix Control Center</div><div id="generated" class="sub">Loading...</div></div>
      <div><button id="refreshBtn" class="btn secondary">Refresh</button> <button id="logoutBtn" class="btn secondary">Sign out</button></div>
    </div>
    <div id="cards" class="cards"></div>
    <div class="grid2">
      <section class="panel"><h2>Live users</h2><div class="tableWrap"><table><thead><tr><th>User</th><th>Country</th><th>Platform</th><th>Version</th><th>Session</th><th>OS</th></tr></thead><tbody id="liveBody"></tbody></table></div></section>
      <section class="panel"><h2>Countries</h2><div id="countries" class="bars"></div></section>
    </div>
    <div class="grid3">
      <section class="panel"><h2>Platforms</h2><div id="platforms" class="bars"></div></section>
      <section class="panel"><h2>Versions</h2><div id="versions" class="bars"></div></section>
      <section class="panel"><h2>Top events</h2><div id="events" class="bars"></div></section>
    </div>
    <div class="sectionTitle">Accounts & installs</div>
    <div class="grid2">
      <section class="panel"><h2>Registered users</h2><div class="tableWrap"><table><thead><tr><th>Name</th><th>Email</th><th>Country</th><th>Installs</th><th>Last active</th><th>Version</th></tr></thead><tbody id="usersBody"></tbody></table></div></section>
      <section class="panel"><h2>Recent installations</h2><div class="tableWrap"><table><thead><tr><th>ID</th><th>Country</th><th>Platform</th><th>Version</th><th>Locale</th><th>Last seen</th></tr></thead><tbody id="installsBody"></tbody></table></div></section>
    </div>
    <div class="sectionTitle">Releases & health</div>
    <div class="grid2">
      <section class="panel"><h2>GitHub releases</h2><div class="tableWrap"><table><thead><tr><th>Release</th><th>Published</th><th>Downloads</th><th>Type</th></tr></thead><tbody id="releasesBody"></tbody></table></div></section>
      <section class="panel"><h2>Recent errors</h2><div class="tableWrap"><table><thead><tr><th>Time</th><th>Type</th><th>Platform</th><th>Version</th><th>Message</th></tr></thead><tbody id="errorsBody"></tbody></table></div></section>
    </div>
  </main>
  <script type="module">
    import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
    const projectUrl = "https://kpjuisxofwqxhbnnsyzf.supabase.co";
    const publishableKey = "sb_publishable_HmqvNavX_iovenN3YRgpmA_cgxQdG9y";
    const supabase = createClient(projectUrl, publishableKey);
    const endpoint = location.href.split("?")[0].split("#")[0];
    const el = id => document.getElementById(id);
    const countryNames = new Intl.DisplayNames(["en"], { type: "region" });
    const fmt = new Intl.NumberFormat();
    const relative = value => {
      if (!value) return "—";
      const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
      if (seconds < 60) return seconds + "s ago";
      if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
      if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago";
      return Math.floor(seconds / 86400) + "d ago";
    };
    const duration = seconds => {
      seconds = Number(seconds || 0);
      if (seconds < 60) return Math.round(seconds) + "s";
      if (seconds < 3600) return Math.round(seconds / 60) + "m";
      return (seconds / 3600).toFixed(1) + "h";
    };
    const esc = value => String(value ?? "—").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
    const country = code => {
      if (!code || code === "Unknown") return "Unknown";
      try { return "🌐 " + countryNames.of(code); } catch { return code; }
    };
    const short = value => value ? String(value).slice(0, 8) : "—";
    async function api() {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) throw new Error("Not signed in");
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {"Content-Type":"application/json","Authorization":"Bearer "+session.access_token,"apikey":publishableKey},
        body: JSON.stringify({ action: "dashboard" })
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error || "Dashboard request failed");
      return payload;
    }
    function bars(id, rows, transform = x => x) {
      const host = el(id);
      if (!rows?.length) { host.innerHTML = '<div class="empty">No data yet</div>'; return; }
      const max = Math.max(...rows.map(r => Number(r.count || 0)), 1);
      host.innerHTML = rows.slice(0, 12).map(row => {
        const width = Math.max(2, Number(row.count || 0) / max * 100);
        return '<div class="barRow"><div class="barName">'+esc(transform(row.name))+'</div><div class="barTrack"><div class="barFill" style="width:'+width+'%"></div></div><div class="barCount">'+fmt.format(row.count)+'</div></div>';
      }).join("");
    }
    function render(data) {
      el("generated").textContent = "Updated " + new Date(data.generated_at).toLocaleString();
      const o = data.overview;
      const cards = [["Online now",o.online_now],["Registered users",o.registered_users],["Known installs",o.known_installations],["Active today",o.active_today],["Active 7d",o.active_7d],["Active 30d",o.active_30d],["GitHub downloads",o.github_downloads],["Avg session",duration(o.avg_session_seconds)]];
      el("cards").innerHTML = cards.map(([label,value]) => '<div class="card"><div class="label">'+esc(label)+'</div><div class="metric">'+esc(typeof value==="number"?fmt.format(value):value)+'</div></div>').join("");
      el("liveBody").innerHTML = data.online.length ? data.online.map(row => {
        const started = Math.max(0,Math.round((Date.now()-new Date(row.started_at).getTime())/1000));
        return '<tr><td><span class="online">●</span> '+esc(row.display_name||("Anonymous #"+short(row.installation_id)))+'<div class="sub">'+esc(row.email||"")+'</div></td><td>'+esc(country(row.country_code))+'</td><td>'+esc(row.platform)+(row.is_tv?' <span class="pill">TV</span>':'')+'</td><td>'+esc(row.app_version)+'</td><td>'+esc(duration(started))+'</td><td title="'+esc(row.os_version)+'">'+esc((row.os_version||"—").slice(0,38))+'</td></tr>';
      }).join("") : '<tr><td colspan="6" class="empty">Nobody is online right now</td></tr>';
      bars("countries",data.countries,country);bars("platforms",data.platforms);bars("versions",data.versions);bars("events",data.event_counts);
      el("usersBody").innerHTML = data.users.length ? data.users.map(row => '<tr><td>'+esc(row.display_name)+'</td><td>'+esc(row.email)+'</td><td>'+esc(country(row.country_code))+'</td><td>'+fmt.format(row.installations)+'</td><td>'+esc(relative(row.last_active_at))+'</td><td>'+esc(row.app_version)+'</td></tr>').join("") : '<tr><td colspan="6" class="empty">No accounts</td></tr>';
      el("installsBody").innerHTML = data.installations.length ? data.installations.slice(0,150).map(row => '<tr><td>'+esc(short(row.installation_id))+'</td><td>'+esc(country(row.country_code))+'</td><td>'+esc(row.platform)+(row.is_tv?' TV':'')+'</td><td>'+esc(row.app_version)+'</td><td>'+esc(row.locale)+'</td><td>'+esc(relative(row.last_seen_at))+'</td></tr>').join("") : '<tr><td colspan="6" class="empty">No telemetry received yet</td></tr>';
      el("releasesBody").innerHTML = data.releases.length ? data.releases.map(row => '<tr><td>'+esc(row.tag)+'</td><td>'+esc(row.published_at?new Date(row.published_at).toLocaleDateString():"—")+'</td><td>'+fmt.format(row.total_downloads)+'</td><td>'+(row.prerelease?'<span class="pill">Beta</span>':'<span class="pill">Stable</span>')+'</td></tr>').join("") : '<tr><td colspan="4" class="empty">GitHub release data unavailable</td></tr>';
      el("errorsBody").innerHTML = data.recent_errors.length ? data.recent_errors.map(row => '<tr><td>'+esc(relative(row.occurred_at))+'</td><td class="'+(row.fatal?'danger':'')+'">'+esc(row.error_type)+'</td><td>'+esc(row.platform)+'</td><td>'+esc(row.app_version)+'</td><td title="'+esc(row.message)+'">'+esc(String(row.message||"").slice(0,80))+'</td></tr>').join("") : '<tr><td colspan="5" class="empty">No recorded errors</td></tr>';
    }
    async function refresh() {
      el("refreshBtn").disabled = true;
      try { render(await api()); }
      catch (error) {
        if (String(error.message).toLowerCase().includes("authorized") || String(error.message).toLowerCase().includes("sign")) { await supabase.auth.signOut(); showLogin(error.message); }
        else el("generated").textContent = error.message;
      } finally { el("refreshBtn").disabled = false; }
    }
    function showApp(){el("login").classList.add("hidden");el("app").classList.remove("hidden");refresh();}
    function showLogin(message=""){el("app").classList.add("hidden");el("login").classList.remove("hidden");el("loginError").textContent=message;}
    el("loginBtn").onclick = async () => {
      el("loginError").textContent="";el("loginBtn").disabled=true;
      const { error } = await supabase.auth.signInWithPassword({email:el("email").value.trim(),password:el("password").value});
      el("loginBtn").disabled=false;if(error)return showLogin(error.message);showApp();
    };
    el("refreshBtn").onclick=refresh;
    el("logoutBtn").onclick=async()=>{await supabase.auth.signOut();showLogin();};
    const { data:{session} }=await supabase.auth.getSession();if(session)showApp();else showLogin();
    setInterval(()=>{if(!el("app").classList.contains("hidden"))refresh();},60000);
  </script>
</body>
</html>`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method === "GET") {
    return new Response(dashboardHtml, {
      headers: {
        ...corsHeaders,
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
      },
    });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const admin = await requireAdmin(req);
  if (!admin) return json({ error: "Not authorized for Orvix Control Center" }, 403);

  let body: AnyRow = {};
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  if (body.action !== "dashboard") return json({ error: "Unknown action" }, 400);

  try { return json(await dashboardData()); }
  catch (error) {
    console.error("orvix admin dashboard failed", error);
    return json({ error: "Dashboard data unavailable" }, 500);
  }
});
