import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

type JsonRow = Record<string, unknown>;

const API_BASE = "https://developers.buymeacoffee.com/api/v1";
const PAGE_LIMIT = 100;
const LEGACY_MATCH_WINDOW_MS = 15 * 60 * 1000;

function textValue(row: JsonRow, keys: string[]) {
  for (const key of keys) {
    const value = row[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

function intValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === "string" && /^-?\d+$/.test(value.trim())) return Number(value);
  return null;
}

function truthy(value: unknown) {
  if (value === true || value === 1) return true;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return normalized === "true" || normalized === "1" || normalized === "yes";
  }
  return false;
}

function parseBmcDate(value: unknown) {
  if (typeof value !== "string" || !value.trim()) return null;
  const raw = value.trim();
  const normalized = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(raw)
    ? raw.replace(" ", "T") + "Z"
    : raw;
  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? null : date;
}

function safePublicName(value: unknown) {
  if (typeof value !== "string") return null;
  const name = value.trim();
  if (!name) return null;
  const normalized = name.toLowerCase();
  if (normalized === "someone" || normalized === "anonymous" || normalized === "private supporter") {
    return null;
  }
  return name;
}

async function fetchPage(token: string, page: number) {
  const response = await fetch(`${API_BASE}/supporters?page=${page}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "User-Agent": "Orvix-Supporters-Sync/1.0",
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Buy Me a Coffee API failed (${response.status}): ${body.slice(0, 500)}`);
  }

  return await response.json() as JsonRow;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const token = req.headers.get("x-bmc-token")?.trim();
  if (!token) {
    return Response.json({ ok: false, configured: false, reason: "BMC API token not configured" }, { status: 503 });
  }

  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  let page = 1;
  let updated = 0;
  let linkedLegacy = 0;
  let skipped = 0;
  let inspected = 0;

  while (page <= PAGE_LIMIT) {
    const payload = await fetchPage(token, page);
    const rows = Array.isArray(payload.data) ? payload.data as JsonRow[] : [];
    const lastPage = intValue(payload.last_page) ?? page;

    for (const item of rows) {
      inspected += 1;

      const supportId = intValue(item.support_id);
      if (supportId === null) {
        skipped += 1;
        continue;
      }

      const syncId = String(supportId);
      const created = parseBmcDate(item.support_created_on);
      const refunded = truthy(item.is_refunded);
      const visibility = intValue(item.support_visibility);
      const publicSupport = visibility === null ? null : visibility > 0;
      const name = safePublicName(item.supporter_name);
      const avatar = textValue(item, [
        "supporter_avatar",
        "avatar_url",
        "avatar",
        "profile_image",
        "profile_image_url",
        "profile_picture",
        "profile_picture_url",
      ]);
      const profileUrl = textValue(item, [
        "supporter_page_url",
        "profile_url",
        "supporter_profile_url",
      ]);

      const exact = await client
        .from("supporters")
        .select("id,display_name,avatar_url,profile_url,is_public,is_active,supporter_since")
        .eq("provider", "buymeacoffee")
        .eq("provider_sync_id", syncId)
        .maybeSingle();

      if (exact.error) throw exact.error;

      let target = exact.data as JsonRow | null;
      let legacyLink = false;

      if (!target && created) {
        const from = new Date(created.getTime() - LEGACY_MATCH_WINDOW_MS).toISOString();
        const to = new Date(created.getTime() + LEGACY_MATCH_WINDOW_MS).toISOString();

        const legacy = await client
          .from("supporters")
          .select("id,display_name,avatar_url,profile_url,is_public,is_active,supporter_since")
          .eq("provider", "buymeacoffee")
          .is("provider_sync_id", null)
          .gte("supporter_since", from)
          .lte("supporter_since", to)
          .order("supporter_since", { ascending: true })
          .limit(2);

        if (legacy.error) throw legacy.error;
        if ((legacy.data?.length ?? 0) === 1) {
          target = legacy.data![0] as JsonRow;
          legacyLink = true;
        }
      }

      if (!target) {
        skipped += 1;
        continue;
      }

      const patch: JsonRow = {
        provider_sync_id: syncId,
        updated_at: new Date().toISOString(),
      };

      if (name && publicSupport !== false) patch.display_name = name;
      if (avatar) patch.avatar_url = avatar;
      if (profileUrl) patch.profile_url = profileUrl;
      if (publicSupport !== null) patch.is_public = publicSupport && !refunded;
      if (refunded) patch.is_active = false;

      const write = await client
        .from("supporters")
        .update(patch)
        .eq("id", String(target.id));

      if (write.error) throw write.error;
      updated += 1;
      if (legacyLink) linkedLegacy += 1;
    }

    if (page >= lastPage || rows.length === 0) break;
    page += 1;
  }

  return Response.json({
    ok: true,
    inspected,
    updated,
    linked_legacy: linkedLegacy,
    skipped,
  });
});
