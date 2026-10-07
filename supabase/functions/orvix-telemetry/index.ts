import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const uuidRe =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function text(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, max) : null;
}

function countryHeader(req: Request): string | null {
  const candidates = [
    req.headers.get("cf-ipcountry"),
    req.headers.get("x-country-code"),
    req.headers.get("x-vercel-ip-country"),
  ];
  for (const raw of candidates) {
    const code = raw?.trim().toUpperCase();
    if (code && /^[A-Z]{2}$/.test(code) && code !== "XX") return code;
  }
  return null;
}

function clientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (!forwarded) return null;
  const ip = forwarded.split(",")[0]?.trim();
  if (!ip || ip.length > 80) return null;
  return ip;
}

async function resolveCountry(req: Request): Promise<string | null> {
  const fromHeader = countryHeader(req);
  if (fromHeader) return fromHeader;

  const ip = clientIp(req);
  if (!ip) return null;

  try {
    const response = await fetch(
      `https://api.country.is/${encodeURIComponent(ip)}`,
      { signal: AbortSignal.timeout(1200) },
    );
    if (!response.ok) return null;
    const data = await response.json();
    const code =
      typeof data?.country === "string" ? data.country.toUpperCase() : "";
    return /^[A-Z]{2}$/.test(code) ? code : null;
  } catch {
    return null;
  }
}

async function authenticatedUserId(req: Request): Promise<string | null> {
  const auth = req.headers.get("authorization");
  if (!auth?.toLowerCase().startsWith("bearer ")) return null;
  const token = auth.slice(7).trim();
  if (!token || !token.includes(".")) return null;

  try {
    const { data, error } = await db.auth.getUser(token);
    if (error) return null;
    return data.user?.id ?? null;
  } catch {
    return null;
  }
}

function safeProperties(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const source = value as Record<string, unknown>;
  const output: Record<string, unknown> = {};
  let count = 0;

  for (const [key, item] of Object.entries(source)) {
    if (count >= 20) break;
    if (key.length > 64) continue;
    if (
      item === null ||
      typeof item === "boolean" ||
      typeof item === "number" ||
      typeof item === "string"
    ) {
      output[key] =
        typeof item === "string" ? item.slice(0, 500) : item;
      count++;
    }
  }
  return output;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", {
      status: 405,
      headers: corsHeaders,
    });
  }

  const contentLength = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > 32768) {
    return new Response("Payload too large", {
      status: 413,
      headers: corsHeaders,
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response("Invalid JSON", {
      status: 400,
      headers: corsHeaders,
    });
  }

  const installationId = text(body.installation_id, 36);
  const sessionId = text(body.session_id, 36);
  const type = text(body.type, 40);
  const platform = text(body.platform, 40);
  const appVersion = text(body.app_version, 80);

  if (
    !installationId ||
    !uuidRe.test(installationId) ||
    !sessionId ||
    !uuidRe.test(sessionId) ||
    !type ||
    !platform ||
    !appVersion
  ) {
    return new Response("Missing or invalid telemetry identity", {
      status: 400,
      headers: corsHeaders,
    });
  }

  const userId = await authenticatedUserId(req);
  const existing = await db
    .from("orvix_analytics_installations")
    .select("country_code")
    .eq("installation_id", installationId)
    .maybeSingle();

  const countryCode =
    existing.data?.country_code ?? (await resolveCountry(req));

  const installation = {
    installation_id: installationId,
    user_id: userId,
    last_seen_at: new Date().toISOString(),
    country_code: countryCode,
    platform,
    os_version: text(body.os_version, 300),
    locale: text(body.locale, 40),
    app_version: appVersion,
    build_number: text(body.build_number, 40),
    is_tv: body.is_tv === true,
  };

  const { error: installationError } = await db
    .from("orvix_analytics_installations")
    .upsert(installation, { onConflict: "installation_id" });

  if (installationError) {
    console.error("telemetry installation upsert failed", installationError);
    return new Response("Storage error", {
      status: 500,
      headers: corsHeaders,
    });
  }

  const now = new Date().toISOString();
  const foreground = body.is_foreground !== false;

  const { error: sessionError } = await db
    .from("orvix_analytics_sessions")
    .upsert(
      {
        session_id: sessionId,
        installation_id: installationId,
        user_id: userId,
        last_heartbeat_at: now,
        is_foreground: foreground,
        country_code: countryCode,
        platform,
        app_version: appVersion,
        build_number: text(body.build_number, 40),
        ...(type === "session_end" ? { ended_at: now } : {}),
      },
      { onConflict: "session_id" },
    );

  if (sessionError) {
    console.error("telemetry session upsert failed", sessionError);
    return new Response("Storage error", {
      status: 500,
      headers: corsHeaders,
    });
  }

  if (type === "error") {
    const errorType = text(body.error_type, 120) ?? "unknown";
    const message = text(body.message, 1200) ?? "Unknown error";
    const { error } = await db.from("orvix_analytics_errors").insert({
      installation_id: installationId,
      session_id: sessionId,
      user_id: userId,
      error_type: errorType,
      message,
      stack: text(body.stack, 6000),
      fatal: body.fatal === true,
      platform,
      app_version: appVersion,
    });
    if (error) console.error("telemetry error insert failed", error);
  } else if (!["heartbeat", "session_start", "session_end"].includes(type)) {
    const eventName = text(body.event_name, 120) ?? type;
    const { error } = await db.from("orvix_analytics_events").insert({
      installation_id: installationId,
      session_id: sessionId,
      user_id: userId,
      event_name: eventName,
      event_category: text(body.event_category, 80) ?? "app",
      properties: safeProperties(body.properties),
    });
    if (error) console.error("telemetry event insert failed", error);
  }

  return new Response(
    JSON.stringify({ ok: true, country_code: countryCode }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
});
