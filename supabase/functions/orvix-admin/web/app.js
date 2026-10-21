// Orvix Control Center page logic. Loaded as a same-origin module after the
// vendored supabase-js UMD build (vendor/supabase-js/<version>/supabase.js),
// which defines window.supabase. No script is loaded from a CDN.
const createClient = window.supabase?.createClient;
if (typeof createClient !== "function") {
  document.getElementById("loginError").textContent =
    "The Supabase client did not load. Host vendor/supabase-js next to this page.";
  throw new Error("supabase-js missing");
}
const projectUrl = "https://kpjuisxofwqxhbnnsyzf.supabase.co";
const publishableKey = "sb_publishable_HmqvNavX_iovenN3YRgpmA_cgxQdG9y";
// Explicit, so the page works wherever it is hosted.
const endpoint = projectUrl + "/functions/v1/orvix-admin";
const supabase = createClient(projectUrl, publishableKey);
const el = id => document.getElementById(id);
const countryNames = new Intl.DisplayNames(["en"], { type: "region" });
const fmt = new Intl.NumberFormat();
let clockOffset = 0; // server time minus browser time
let data = null;
let showAllReleases = false;
const serverNow = () => Date.now() + clockOffset;
const ago = value => {
  if (!value) return "—";
  const seconds = Math.max(0, Math.round((serverNow() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return seconds + "s ago";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago";
  return Math.floor(seconds / 86400) + "d ago";
};
const duration = seconds => {
  if (seconds === null || seconds === undefined) return "—";
  seconds = Number(seconds);
  if (seconds < 60) return Math.round(seconds) + "s";
  if (seconds < 3600) return Math.round(seconds / 60) + "m";
  return (seconds / 3600).toFixed(1) + "h";
};
const esc = value => String(value ?? "—").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const country = code => {
  if (!code || code === "Unknown") return "Unknown";
  try { return countryNames.of(code) + " (" + code + ")"; } catch { return code; }
};
const short = value => value ? String(value).slice(0, 8) : "—";
const num = value => typeof value === "number" ? fmt.format(value) : "—";
const def = key => (data && data.definitions && data.definitions[key]) || "";
const info = key => '<span class="info" title="'+esc(def(key))+'">i</span>';

async function api() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) throw Object.assign(new Error("Not signed in"), { auth: true });
  let response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: {"Content-Type":"application/json","Authorization":"Bearer "+session.access_token,"apikey":publishableKey},
      body: JSON.stringify({ action: "dashboard" }),
      signal: AbortSignal.timeout(30000),
    });
  } catch (error) {
    throw new Error("Control Center backend could not be reached (" + (error.name === "TimeoutError" ? "timed out" : "network error") + ")");
  }
  const payload = await response.json().catch(() => ({}));
  if (response.status === 401 || response.status === 403) throw Object.assign(new Error(payload.error || "Not authorized"), { auth: true });
  if (!response.ok) throw new Error((payload.error || "Dashboard request failed") + " (HTTP " + response.status + ")");
  return payload;
}

// One tile: shows "—" plus the reason when a value is unavailable, and
// flags stale or missing telemetry instead of presenting a bare zero.
function tile(label, key, m, format = num) {
  m = m || { value: null, state: "unavailable", note: "Not provided by the backend" };
  let stateHtml = "";
  if (m.state === "unavailable") stateHtml = '<div class="state bad">'+esc(m.note || "Unable to retrieve")+'</div>';
  else if (m.state === "stale" || m.state === "no_data") stateHtml = '<div class="state warn">'+esc(m.note)+'</div>';
  else if (m.value === 0) stateHtml = '<div class="state">0 observed</div>';
  const value = m.state === "unavailable" ? "—" : format(m.value);
  return '<div class="tile"><div class="label">'+esc(label)+(key ? info(key) : "")+'</div><div class="value">'+esc(value)+'</div>'+stateHtml+'</div>';
}

function bars(id, rows, transform = x => x, emptyText = "No data yet") {
  const host = el(id);
  if (rows === null) { host.innerHTML = '<div class="empty danger">Unable to retrieve this breakdown</div>'; return; }
  if (!rows?.length) { host.innerHTML = '<div class="empty">'+esc(emptyText)+'</div>'; return; }
  const total = rows.reduce((sum, r) => sum + Number(r.count || 0), 0);
  const max = Math.max(...rows.map(r => Number(r.count || 0)), 1);
  host.innerHTML = rows.slice(0, 15).map(row => {
    const width = Math.max(2, Number(row.count || 0) / max * 100);
    const pct = total ? Math.round(Number(row.count || 0) / total * 100) : 0;
    return '<div class="barRow" title="'+esc(transform(row.name))+': '+fmt.format(row.count)+' ('+pct+'%)"><div class="barName">'+esc(transform(row.name))+'</div><div class="barTrack"><div class="barFill" style="width:'+width+'%"></div></div><div class="barCount">'+fmt.format(row.count)+'</div></div>';
  }).join("") + (rows.length > 15 ? '<div class="sub">+'+(rows.length-15)+' more, total '+fmt.format(total)+'</div>' : '<div class="sub">Total '+fmt.format(total)+'</div>');
}

function dailyChart(points) {
  const host = el("dailyChart");
  if (!points?.length) { host.innerHTML = '<div class="empty">No session data</div>'; return; }
  const W = 600, H = 180, padL = 30, padB = 22, padT = 8;
  const max = Math.max(1, ...points.map(p => p.active_installations));
  const step = (W - padL) / points.length;
  const barW = Math.min(24, Math.max(2, step - 2));
  const y = v => H - padB - (v / max) * (H - padB - padT);
  const ticks = [0, Math.ceil(max / 2), max];
  let svg = '<svg viewBox="0 0 '+W+' '+H+'" preserveAspectRatio="none" role="img" aria-label="Daily active installations, last 30 UTC days">';
  for (const t of ticks) svg += '<line x1="'+padL+'" x2="'+W+'" y1="'+y(t)+'" y2="'+y(t)+'" stroke="var(--grid)" stroke-width="1"/><text x="'+(padL-6)+'" y="'+(y(t)+4)+'" fill="var(--muted)" font-size="10" text-anchor="end">'+t+'</text>';
  points.forEach((p, i) => {
    const x = padL + i * step + (step - barW) / 2;
    const top = y(p.active_installations), h = H - padB - top;
    if (h > 0) svg += '<path d="M'+x+','+(H-padB)+'V'+(top+Math.min(4,h))+'q0,-'+Math.min(4,h)+' '+Math.min(4,barW/2)+',-'+Math.min(4,h)+'H'+(x+barW-Math.min(4,barW/2))+'q'+Math.min(4,barW/2)+',0 '+Math.min(4,barW/2)+','+Math.min(4,h)+'V'+(H-padB)+'Z" fill="var(--lime)"/>';
    svg += '<rect data-i="'+i+'" x="'+(padL+i*step)+'" y="0" width="'+step+'" height="'+(H-padB)+'" fill="transparent"/>';
  });
  const label = d => d.slice(5);
  svg += '<text x="'+padL+'" y="'+(H-6)+'" fill="var(--muted)" font-size="10">'+label(points[0].day)+'</text><text x="'+W+'" y="'+(H-6)+'" fill="var(--muted)" font-size="10" text-anchor="end">'+label(points[points.length-1].day)+'</text></svg><div class="tip hidden"></div>';
  host.innerHTML = svg;
  const tip = host.querySelector(".tip");
  host.querySelectorAll("rect[data-i]").forEach(rect => {
    rect.addEventListener("mouseenter", () => {
      const p = points[Number(rect.dataset.i)];
      const box = rect.getBoundingClientRect(), hostBox = host.getBoundingClientRect();
      tip.innerHTML = '<strong>'+esc(p.day)+'</strong> (UTC)<br>'+fmt.format(p.active_installations)+' active installations<br>'+fmt.format(p.sessions_started)+' sessions started';
      tip.style.left = (box.left - hostBox.left + box.width / 2) + "px";
      tip.style.top = "40px";
      tip.classList.remove("hidden");
    });
    rect.addEventListener("mouseleave", () => tip.classList.add("hidden"));
  });
}

function channelPill(channel) {
  if (channel === "draft") return '<span class="pill warn">Draft / Private</span>';
  if (channel === "prerelease") return '<span class="pill">Beta</span>';
  if (channel === "stable") return '<span class="pill">Stable</span>';
  if (channel === "not_published") return '<span class="pill muted">Not a public release</span>';
  return '<span class="pill muted">Unknown</span>';
}

function renderReleases() {
  const releases = data.releases || [];
  const d = data.downloads || {};
  if (!releases.length) {
    el("releasesBody").innerHTML = '<tr><td colspan="9" class="empty">'+(d.status === "unavailable" ? "GitHub release data unavailable" : "No releases")+'</td></tr>';
    el("releasesMore").innerHTML = "";
    return;
  }
  const visible = showAllReleases ? releases : releases.slice(0, 25);
  el("releasesBody").innerHTML = visible.map(row => {
    const p = row.downloads_by_platform || {};
    const assets = Array.isArray(row.assets) ? row.assets : [];
    const assetHtml = assets.length ? '<details class="assets"><summary>'+assets.length+' files</summary><div class="releaseAssets">'+assets.map(asset =>
      '<div class="releaseAsset"><span class="releaseAssetName" title="'+esc(asset.name)+'">'+esc(asset.name)+(asset.kind !== "app" ? ' <em>(not counted)</em>' : '')+'</span><strong>'+fmt.format(asset.downloads||0)+'</strong></div>'
    ).join('')+'</div></details>' : '';
    const type = row.release_kind === "component" ? '<span class="pill muted">Component</span>' : channelPill(row.draft ? "draft" : row.prerelease ? "prerelease" : "stable");
    return '<tr><td>'+esc(row.tag)+assetHtml+'</td><td>'+esc(row.published_at?new Date(row.published_at).toLocaleDateString():"—")+'</td><td class="num"><strong>'+fmt.format(row.total_downloads)+'</strong></td><td class="num">'+fmt.format(p["Android Mobile"]||0)+'</td><td class="num">'+fmt.format(p["Android TV"]||0)+'</td><td class="num">'+fmt.format(p["Windows"]||0)+'</td><td class="num">'+fmt.format(p["macOS"]||0)+'</td><td class="num">'+fmt.format(p["iOS"]||0)+'</td><td>'+type+'</td></tr>';
  }).join("");
  el("releasesMore").innerHTML = releases.length > 25 ? '<button class="btn secondary" id="moreBtn" style="margin-top:10px">'+(showAllReleases ? "Show newest 25" : "Show all "+releases.length+" releases")+'</button>' : "";
  const more = el("moreBtn"); if (more) more.onclick = () => { showAllReleases = !showAllReleases; renderReleases(); };
}

function render(payload) {
  data = payload;
  clockOffset = new Date(payload.generated_at).getTime() - Date.now();
  const a = payload.activity || {};
  const fr = a.freshness || {};
  el("generated").textContent = "Updated " + new Date(payload.generated_at).toLocaleString() + (fr.latest_telemetry_at ? " · last telemetry " + ago(fr.latest_telemetry_at) : "");

  const banners = [];
  if (!payload.schema_version || payload.schema_version < 2) banners.push(["error", "The orvix-admin function is older than this page. Deploy the current function to see accurate definitions."]);
  if (fr.state === "none") banners.push(["warn", "No telemetry has been received yet. Activity numbers are not meaningful until clients report."]);
  if (fr.state === "stale") banners.push(["warn", "No telemetry received for " + ago(fr.latest_telemetry_at).replace(" ago", "") + ". Zero activity may mean telemetry is not arriving, not that nobody uses Orvix."]);
  if (fr.state === "unknown") banners.push(["error", "Telemetry freshness could not be checked."]);
  const sections = (payload.health && payload.health.sections) || {};
  const down = Object.entries(sections).filter(([, s]) => s && (s.status === "unavailable" || s.status === "partial")).map(([k]) => k.replace(/_/g, " "));
  if (down.length) banners.push(["error", "Partially unavailable: " + down.join(", ") + ". Affected values show “—”, not zero."]);
  el("banners").innerHTML = banners.map(([k, t]) => '<div class="banner '+(k === "error" ? "error" : "")+'">'+esc(t)+'</div>').join("");

  el("activityTiles").innerHTML = [
    tile("Online now", "online_now", a.online_now),
    tile("Active 5 min", "active_5m", a.active_5m),
    tile("Active 24 h", "active_24h", a.active_24h),
    tile("Active 7 days", "active_7d", a.active_7d),
    tile("Active 30 days", "active_30d", a.active_30d),
    tile("Installations (all time)", "installations", a.installations_total),
    tile("Signed-in accounts 30d", "signed_in_accounts_30d", a.signed_in_accounts_30d),
    tile("Registered accounts", null, a.registered_users),
  ].join("");

  el("liveBody").innerHTML = !a.online_now || a.online_now.state === "unavailable"
    ? '<tr><td colspan="7" class="empty danger">Unable to retrieve active-session data</td></tr>'
    : payload.online.length ? payload.online.map(row => {
      const started = Math.max(0,Math.round((serverNow()-new Date(row.started_at).getTime())/1000));
      return '<tr><td><span class="online">●</span> '+esc(row.display_name||("Anonymous #"+short(row.installation_id)))+'<div class="sub">'+esc(row.email||"")+'</div></td><td>'+esc(country(row.country_code))+'</td><td>'+esc(row.platform)+(row.is_tv?' <span class="pill">TV</span>':'')+'</td><td>'+esc(row.device_display_name)+'</td><td>'+esc(row.app_version)+'</td><td>'+esc(duration(started))+'</td><td title="'+esc(row.os_version)+'">'+esc((row.os_version||"—").slice(0,38))+'</td></tr>';
    }).join("") : '<tr><td colspan="7" class="empty">0 observed active sessions'+(fr.state === "stale" || fr.state === "none" ? " — telemetry is unavailable or incomplete" : "")+'</td></tr>';

  const b = payload.breakdowns || {};
  const bOk = b.status === "ok";
  el("countriesInfo").title = def("countries");
  bars("countries", bOk ? b.countries : null, country);
  el("platformsInfo").title = def("platforms");
  bars("platforms", bOk ? b.platforms : null);

  el("dailyInfo").title = "Distinct installations with a session on each UTC day. Bars show active installations; hover for sessions started.";
  dailyChart(a.daily);
  el("dailyNote").textContent = a.daily_truncated ? "Row limit reached; older days may be undercounted." : "";
  el("sessionTiles").innerHTML = [
    tile("Sessions 30 days", "sessions_30d", a.sessions_30d),
    tile("All sessions", "sessions_total", a.sessions_total),
    tile("Average session", "avg_session", a.avg_session_seconds, duration),
    tile("Median session", "avg_session", a.median_session_seconds, duration),
    tile("Errors 30 days", null, a.errors_30d),
  ].join("");

  const d = payload.downloads || {};
  const t = d.totals;
  let status = "";
  if (d.status === "ok") status = "GitHub data fetched " + ago(d.fetched_at) + (d.source === "cache" ? " (cached, refreshed every 10 minutes)" : "") + ".";
  else if (d.status === "stale") status = '<span style="color:var(--warn)">Showing GitHub data from ' + esc(ago(d.fetched_at)) + ': the latest refresh failed (' + esc(d.error?.message || "unknown error") + ').</span>';
  else status = '<span class="danger">GitHub release data unavailable: ' + esc(d.error?.message || "unknown error") + (d.error?.rate_limit_reset_at ? ", resets " + esc(new Date(d.error.rate_limit_reset_at).toLocaleTimeString()) : "") + '.</span>';
  if (d.truncated) status += " Only the newest " + d.pages + " pages of releases were read.";
  el("downloadStatus").innerHTML = status;
  const dm = v => t ? { value: v, state: "ok", note: null } : { value: null, state: "unavailable", note: "GitHub data unavailable" };
  el("downloadTiles").innerHTML = [
    tile("All public downloads", "github_downloads", dm(t?.public_app_downloads)),
    tile("Stable release downloads", null, dm(t?.by_channel?.stable)),
    tile("Beta release downloads", null, dm(t?.by_channel?.prerelease)),
    tile("Latest stable " + (d.latest_stable?.tag || "") + " downloads", null, dm(d.latest_stable ? d.latest_stable.total_downloads : (t ? 0 : undefined))),
    tile("Latest beta " + (d.latest_prerelease?.tag || "") + " downloads", null, dm(d.latest_prerelease ? d.latest_prerelease.total_downloads : (t ? 0 : undefined))),
    tile("Public app releases", null, dm(t?.public_app_releases)),
  ].join("");
  el("variantInfo").title = def("github_downloads");
  el("variantBody").innerHTML = t && t.by_variant.length ? t.by_variant.map(v => '<tr><td>'+esc(v.platform)+'</td><td>'+esc(v.variant)+'</td><td class="num">'+fmt.format(v.downloads)+'</td></tr>').join("")
    + '<tr><td colspan="2" class="sub">Not counted: stream-server component</td><td class="num sub">'+fmt.format(t.component_downloads)+'</td></tr>'
    + '<tr><td colspan="2" class="sub">Not counted: '+fmt.format(t.draft.releases)+' draft releases</td><td class="num sub">'+fmt.format(t.draft.downloads)+'</td></tr>'
    : '<tr><td colspan="3" class="empty">'+(t ? "No downloads" : "GitHub data unavailable")+'</td></tr>';
  bars("downloadPlatforms", t ? Object.entries(t.by_platform).filter(([, c]) => c > 0).map(([name, count]) => ({ name, count })).sort((x, y) => y.count - x.count) : null);
  renderReleases();

  el("versionsInfo").title = def("versions");
  el("versionsBody").innerHTML = !bOk ? '<tr><td colspan="3" class="empty danger">Unable to retrieve versions</td></tr>'
    : (b.versions || []).length ? b.versions.map(v => '<tr><td>'+esc(v.version)+'</td><td>'+channelPill(v.channel)+'</td><td class="num">'+fmt.format(v.installations)+'</td></tr>').join("")
    : '<tr><td colspan="3" class="empty">No version telemetry in the last 30 days</td></tr>';
  el("verifiedInfo").title = def("verified_versions");
  el("verifiedBody").innerHTML = (payload.verified_versions || []).length ? payload.verified_versions.map(v => '<tr><td>'+esc(v.version)+'</td><td class="num">'+fmt.format(v.unique_devices)+'</td><td>'+esc(ago(v.last_seen_at))+'</td></tr>').join("")
    : '<tr><td colspan="3" class="empty">'+(sections.version_sessions?.status === "unavailable" ? "Unable to retrieve" : "No sessions recorded")+'</td></tr>';

  const h = payload.health || {};
  const q = h.data_quality || {};
  const sq = h.session_quality || {};
  const statusPill = s => s === "ok" ? '<span class="pill">OK</span>' : s === "stale" || s === "partial" ? '<span class="pill warn">'+esc(s)+'</span>' : '<span class="pill bad">'+esc(s || "unknown")+'</span>';
  const freshPill = { fresh: '<span class="pill">Fresh</span>', quiet: '<span class="pill muted">Quiet</span>', stale: '<span class="pill warn">Stale</span>', none: '<span class="pill warn">No data</span>', unknown: '<span class="pill bad">Unknown</span>' }[fr.state] || "";
  el("healthList").innerHTML =
    '<dt>Latest telemetry</dt><dd>'+esc(ago(fr.latest_telemetry_at))+' '+freshPill+'</dd>' +
    Object.entries(sections).map(([k, s]) => '<dt>'+esc(k.replace(/_/g, " "))+'</dt><dd>'+statusPill(s.status)+(s.truncated ? ' <span class="pill warn">row cap reached</span>' : '')+'</dd>').join("");
  el("qualityList").innerHTML =
    '<dt>Installations checked (30d)</dt><dd>'+num(q.installations_considered)+'</dd>' +
    '<dt>Unknown platform</dt><dd>'+num(q.unknown_platform)+(q.unknown_platform_labels?.length ? ' <span class="sub">'+esc(q.unknown_platform_labels.join(", "))+'</span>' : '')+'</dd>' +
    '<dt>Unknown country</dt><dd>'+num(q.unknown_country)+'</dd>' +
    '<dt title="Mobile build on a TV device, or TV build on a phone. Counted under the build that is running.">Build/hardware mismatch</dt><dd>'+num(q.form_factor_mismatch)+'</dd>' +
    '<dt>Missing version</dt><dd>'+num(q.missing_version)+'</dd>' +
    '<dt title="Sessions with only a start message and no heartbeat">Single-message sessions</dt><dd>'+num(sq.single_message_sessions)+' / '+num(sq.sessions_30d_considered)+'</dd>' +
    '<dt>Future timestamps</dt><dd>'+num(sq.future_timestamps)+'</dd>';
  bars("events", sections.events_30d?.status === "unavailable" ? null : payload.event_counts);

  el("usersBody").innerHTML = payload.users.length ? payload.users.map(row => '<tr><td>'+esc(row.display_name)+'</td><td>'+esc(row.email)+'</td><td>'+esc(country(row.country_code))+'</td><td class="num">'+fmt.format(row.installations)+'</td><td>'+esc(row.device_display_name)+'</td><td>'+esc(ago(row.last_active_at))+'</td><td>'+esc(row.app_version)+'</td></tr>').join("") : '<tr><td colspan="7" class="empty">'+(sections.users?.status === "unavailable" ? "Unable to retrieve accounts" : "No accounts")+'</td></tr>';
  el("installsBody").innerHTML = payload.installations.length ? payload.installations.slice(0,150).map(row => '<tr><td>'+esc(short(row.installation_id))+'</td><td>'+esc(country(row.country_code))+'</td><td>'+esc(row.platform)+(row.is_tv?' TV':'')+'</td><td>'+esc(row.device_display_name)+'</td><td>'+esc(row.app_version)+'</td><td>'+esc(row.locale)+'</td><td>'+esc(ago(row.last_seen_at))+'</td></tr>').join("") : '<tr><td colspan="7" class="empty">'+(sections.recent_installations?.status === "unavailable" ? "Unable to retrieve installations" : "No telemetry received yet")+'</td></tr>';
  el("errorsBody").innerHTML = payload.recent_errors.length ? payload.recent_errors.map(row => '<tr><td>'+esc(ago(row.occurred_at))+'</td><td class="'+(row.fatal?'danger':'')+'">'+esc(row.error_type)+'</td><td>'+esc(row.platform)+'</td><td>'+esc(row.app_version)+'</td><td title="'+esc(row.message)+'">'+esc(String(row.message||"").slice(0,80))+'</td></tr>').join("") : '<tr><td colspan="5" class="empty">'+(sections.recent_errors?.status === "unavailable" ? "Unable to retrieve errors" : "No recorded errors")+'</td></tr>';
}

async function refresh() {
  el("refreshBtn").disabled = true;
  try { render(await api()); }
  catch (error) {
    if (error.auth) { await supabase.auth.signOut(); showLogin(error.message); }
    else {
      el("generated").textContent = (data ? "Showing data from " + new Date(data.generated_at).toLocaleString() + " · " : "") + "Refresh failed: " + error.message;
      if (!data) el("banners").innerHTML = '<div class="banner error">'+esc(error.message)+'</div>';
    }
  } finally { el("refreshBtn").disabled = false; }
}
function showApp(){el("login").classList.add("hidden");el("app").classList.remove("hidden");refresh();}
function showLogin(message=""){el("app").classList.add("hidden");el("login").classList.remove("hidden");el("loginError").textContent=message;}
// A form so Enter submits; preventDefault keeps it from navigating.
el("loginForm").onsubmit = async (event) => {
  event.preventDefault();
  el("loginError").textContent="";el("loginBtn").disabled=true;
  let error = null;
  try {
    ({ error } = await supabase.auth.signInWithPassword({email:el("email").value.trim(),password:el("password").value}));
  } catch (e) {
    error = { message: "Sign-in failed: " + (e?.message || "network error") };
  } finally {
    el("loginBtn").disabled=false;
  }
  if(error)return showLogin(error.message);showApp();
};
el("refreshBtn").onclick=refresh;
el("logoutBtn").onclick=async()=>{await supabase.auth.signOut();showLogin();};
let initialSession = null;
try { ({ data: { session: initialSession } } = await supabase.auth.getSession()); } catch { initialSession = null; }
if (initialSession) showApp(); else showLogin();
// Every 2 minutes while the tab is visible; GitHub data is cached for 10.
setInterval(()=>{if(!document.hidden && !el("app").classList.contains("hidden"))refresh();},120000);
