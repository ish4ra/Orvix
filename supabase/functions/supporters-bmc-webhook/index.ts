import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const enc = new TextEncoder();

function hex(bytes: Uint8Array) {
  return Array.from(bytes).map((value) => value.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string) {
  a = a.toLowerCase().trim();
  b = b.toLowerCase().trim();
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmac(secret: string, value: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(value))));
}

function iso(value: unknown) {
  if (typeof value === "number") return new Date(value * 1000).toISOString();
  if (typeof value === "string" && value) {
    const numeric = Number(value);
    if (Number.isFinite(numeric) && /^\d+$/.test(value)) return new Date(numeric * 1000).toISOString();
    const date = new Date(value);
    if (!Number.isNaN(date.getTime())) return date.toISOString();
  }
  return new Date().toISOString();
}

function optionalText(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const secret = Deno.env.get("BMC_WEBHOOK_SIGNING_SECRET");
  if (!secret) return new Response("Webhook secret not configured", { status: 503 });

  const raw = await req.text();
  const signature = req.headers.get("x-signature-sha256") ?? "";
  const expected = await hmac(secret, raw);
  if (!signature || !safeEqual(expected, signature.replace(/^sha256=/i, ""))) {
    return new Response("Invalid signature", { status: 401 });
  }

  let body: Record<string, any>;
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  if (body.live_mode === false) {
    return Response.json({ ok: true, ignored: "test event" });
  }

  const type = String(body.type ?? "").toLowerCase();
  const data = body.data ?? {};
  const supporterId = data.supporter_id;
  if (supporterId === null || supporterId === undefined) {
    return Response.json({ ok: true, ignored: "anonymous/no supporter_id" });
  }

  const refunded = type.endsWith(".refunded");
  const endedRecurring =
    type.endsWith(".cancelled") ||
    type.endsWith(".canceled") ||
    type.endsWith(".paused");

  const recurring =
    type.startsWith("membership.") ||
    type.startsWith("recurring_donation.") ||
    type.startsWith("monthly_support.") ||
    type.startsWith("subscription.");

  const privateSupport =
    data.is_public === false ||
    data.is_public === "false" ||
    data.supporter_name_type === "private" ||
    data.supporter_name_type === "anonymous";

  const former = recurring && endedRecurring;
  const visible = !refunded && !privateSupport;
  const eventAt = iso(data.created_at ?? data.started_at ?? body.created);
  const now = new Date().toISOString();
  const providerSyncId = data.id === null || data.id === undefined ? null : String(data.id);

  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const existing = await client
    .from("supporters")
    .select("display_name,avatar_url,profile_url,supporter_since,tier")
    .eq("provider", "buymeacoffee")
    .eq("provider_user_id", String(supporterId))
    .maybeSingle();

  if (existing.error) return new Response("Database read error", { status: 500 });

  const current = existing.data;
  const incomingName = optionalText(data.supporter_name);
  const incomingAvatar = optionalText(
    data.supporter_avatar ??
      data.avatar_url ??
      data.avatar ??
      data.profile_image ??
      data.profile_image_url ??
      data.profile_picture ??
      data.profile_picture_url,
  );
  const incomingProfile = optionalText(
    data.supporter_page_url ??
      data.profile_url ??
      data.supporter_profile_url,
  );

  const row: Record<string, unknown> = {
    provider: "buymeacoffee",
    provider_user_id: String(supporterId),
    provider_sync_id: providerSyncId,
    display_name: visible
      ? incomingName ?? current?.display_name ?? "BMC supporter"
      : "Private supporter",
    avatar_url: incomingAvatar ?? current?.avatar_url ?? null,
    profile_url: incomingProfile ?? current?.profile_url ?? null,
    support_type: former
      ? (type.startsWith("membership.") ? "Former Member" : "Former Monthly supporter")
      : recurring
          ? (type.startsWith("membership.") ? "Member" : "Monthly supporter")
          : String(data.support_type ?? "Supporter"),
    tier: data.membership_level_name ?? data.membership_name ?? data.tier_name ?? current?.tier ?? null,
    supporter_since: current?.supporter_since ?? eventAt,
    last_supported_at: eventAt,
    is_recurring: recurring && !former,
    is_active: !refunded,
    is_public: visible,
    updated_at: now,
  };

  const { error } = await client
    .from("supporters")
    .upsert(row, { onConflict: "provider,provider_user_id" });

  if (error) return new Response("Database error", { status: 500 });
  return Response.json({ ok: true, event: type });
});
