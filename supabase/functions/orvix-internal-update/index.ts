import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// Private GitHub Draft Releases are the binary storage. Only this server has
// the GitHub fine-grained, repository-scoped Contents:read token. NEVER put
// GitHub credentials into Flutter builds, URLs, or client-facing metadata.
const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const githubToken = Deno.env.get("ORVIX_INTERNAL_GITHUB_TOKEN") ?? "";
const owner = "ish4ra";
const repo = "Orvix";
const api = "https://api.github.com/repos/" + owner + "/" + repo;
const assets: Record<string, (name: string) => boolean> = {
  windows: (n) => n.startsWith("Orvix-Setup-") && n.endsWith("-Windows-x64.exe"),
  android_tv: (n) => n.endsWith("-Android-TV.apk"),
  android_mobile: (n) => n.endsWith("-Android-Mobile.apk"),
  macos: (n) => n.endsWith("-macOS.zip"),
  ios_modern: (n) => n.endsWith("-iOS-15.5-Plus.ipa"),
  ios_legacy: (n) => n.endsWith("-iOS-12-Legacy.ipa"),
};
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
type Asset = { id: number; name: string; size: number; digest?: string };
type Release = { draft: boolean; tag_name: string; body?: string; assets: Asset[] };

async function getDrafts(): Promise<Release[]> {
  const response = await fetch(api + "/releases?per_page=50", {
    headers: {
      Authorization: "Bearer " + githubToken,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "Orvix-Internal-Updates",
    },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error("GitHub draft retrieval failed");
  const releases: Release[] = await response.json();
  // Include only unpublished Orvix version tags. NEVER expose public releases
  // through the private endpoint, and never use client-provided URLs.
  return releases.filter((r) =>
    r.draft === true && /^v[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[0-9]+)?$/.test(r.tag_name));
}

function assetFor(release: Release, platform: string): Asset | undefined {
  return release.assets.find((a) => assets[platform](a.name)
    && a.size > 0 && typeof a.digest === "string"
    && /^sha256:[a-f0-9]{64}$/.test(a.digest));
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: cors });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!supabaseUrl || !anonKey || !serviceKey || !githubToken)
    return json({ error: "internal_updates_unconfigured" }, 503);

  const bearer = /^Bearer (.+)$/i.exec(request.headers.get("authorization") ?? "");
  if (!bearer) return json({ error: "unauthorized" }, 401);
  try {
    const auth = createClient(supabaseUrl, anonKey, { auth: { persistSession: false } });
    const { data: identity, error: authError } = await auth.auth.getUser(bearer[1]);
    if (authError || !identity.user) return json({ error: "unauthorized" }, 401);

    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: adminRow, error: adminError } = await admin
      .from("orvix_admins").select("user_id").eq("user_id", identity.user.id).maybeSingle();
    if (adminError) return json({ error: "unavailable" }, 503);
    if (!adminRow) return json({ error: "forbidden" }, 403);

    let body: Record<string, unknown>;
    try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
    const platform = body.platform;
    const action = body.action;
    if (typeof platform !== "string" || !Object.hasOwn(assets, platform))
      return json({ error: "invalid_platform" }, 400);
    if (action !== "check" && action !== "download")
      return json({ error: "invalid_action" }, 400);

    const releases = await getDrafts();
    if (action === "check") {
      const rows = releases.flatMap((release) => {
        const asset = assetFor(release, platform);
        if (!asset) return [];
        return [{
          version: release.tag_name.slice(1), asset_name: asset.name,
          size_bytes: asset.size, sha256: asset.digest!.slice(7),
          notes: release.body ?? "",
        }];
      });
      return json({ releases: rows });
    }

    const version = body.version;
    if (typeof version !== "string" || version.length > 100)
      return json({ error: "invalid_version" }, 400);
    const release = releases.find((r) => r.tag_name === "v" + version);
    const asset = release ? assetFor(release, platform) : undefined;
    if (!asset) return json({ error: "not_found" }, 404);

    const result = await fetch(api + "/releases/assets/" + asset.id, {
      headers: {
        Authorization: "Bearer " + githubToken,
        Accept: "application/octet-stream",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Orvix-Internal-Updates",
      },
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
    });
    const redirect = result.headers.get("location");
    const location = redirect ? new URL(redirect) : null;
    // Only return GitHub's short-lived asset CDN link after fresh admin auth.
    if (result.status !== 302 || location?.protocol !== "https:" ||
        !location.hostname.endsWith(".githubusercontent.com"))
      return json({ error: "download_unavailable" }, 503);
    return json({
      url: location.href,
      asset_name: asset.name,
      size_bytes: asset.size,
      sha256: asset.digest!.slice(7),
    });
  } catch (_) {
    return json({ error: "internal_updates_unavailable" }, 503);
  }
});
