import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const bucket = "orvix-internal-updates";
const platforms = new Set(["windows", "android_tv", "android_mobile", "macos", "ios_modern", "ios_legacy"]);
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: cors });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!url || !anonKey || !serviceKey) return json({ error: "unavailable" }, 503);

  const match = /^Bearer (.+)$/i.exec(request.headers.get("authorization") ?? "");
  if (!match) return json({ error: "unauthorized" }, 401);

  // Never trust user_id, internal channel, or elevated role from the request.
  const client = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: identity, error: authError } = await client.auth.getUser(match[1]);
  if (authError || !identity.user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: adminRow, error: adminError } = await admin
    .from("orvix_admins").select("user_id")
    .eq("user_id", identity.user.id).maybeSingle();
  if (adminError) return json({ error: "unavailable" }, 503);
  if (!adminRow) return json({ error: "forbidden" }, 403);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "bad_json" }, 400); }
  const platform = body.platform;
  const action = body.action;
  if (typeof platform !== "string" || !platforms.has(platform)) {
    return json({ error: "invalid_platform" }, 400);
  }
  if (action !== "check" && action !== "download") return json({ error: "invalid_action" }, 400);
  const { data: rows, error: rowError } = await admin
    .from("orvix_internal_release_assets")
    .select("version,platform,object_path,asset_name,size_bytes,sha256,notes")
    .eq("platform", platform).order("created_at", { ascending: false }).limit(100);
  if (rowError) return json({ error: "unavailable" }, 503);
  const list = rows ?? [];
  // Client may compare versions semantically; server only returns entitled data.
  if (action === "check") return json({ releases: list.map(({ object_path: _private, ...r }) => r) });
  const requestedPath = body.object_path;
  if (typeof requestedPath !== "string" || requestedPath.length > 500) {
    return json({ error: "invalid_path" }, 400);
  }
  const selected = list.find((r) => r.object_path === requestedPath);
  if (!selected) return json({ error: "not_found" }, 404);
  // Short lifetime, per-request authorization, private bucket. Never cache URL.
  const { data: signed, error: signError } = await admin.storage
    .from(bucket).createSignedUrl(selected.object_path, 900);
  if (signError || !signed?.signedUrl) return json({ error: "unavailable" }, 503);
  return json({
    url: signed.signedUrl,
    asset_name: selected.asset_name,
    size_bytes: selected.size_bytes,
    sha256: selected.sha256,
  });
});
