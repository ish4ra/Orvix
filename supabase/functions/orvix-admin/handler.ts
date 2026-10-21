// Request handling for the orvix-admin Edge Function. Auth and data loading
// are injected so the access rules can be tested without a project;
// index.ts wires in the real clients.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

/// The public Orvix page. Supabase serves Edge Function HTML as plain text,
/// so a browser opening the function URL is sent here instead.
export const DASHBOARD_REDIRECT = "https://isharalakshan.xyz/orvix/";

export interface AdminDeps {
  /// True only for the Control Center owner. Must return false (not throw)
  /// for a missing, invalid or expired token.
  isOwner(accessToken: string): Promise<boolean>;
  loadDashboard(): Promise<unknown>;
  /// Receives fixed messages only, never tokens or request data.
  log(message: string, error?: unknown): void;
}

export function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      // Owner analytics must never sit in a shared or browser cache.
      "Cache-Control": "no-store",
    },
  });
}

export function bearerToken(req: Request): string | null {
  const auth = req.headers.get("authorization");
  if (!auth?.toLowerCase().startsWith("bearer ")) return null;
  const token = auth.slice(7).trim();
  return token || null;
}

export async function handleAdminRequest(req: Request, deps: AdminDeps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method === "GET") {
    return new Response(null, {
      status: 302,
      headers: {
        ...corsHeaders,
        "Location": DASHBOARD_REDIRECT,
        "Cache-Control": "no-store",
      },
    });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const token = bearerToken(req);
  let owner = false;
  if (token) {
    try {
      owner = await deps.isOwner(token);
    } catch (error) {
      deps.log("orvix admin auth check failed", error);
      owner = false;
    }
  }
  if (!owner) return json({ error: "Not authorized for Orvix Control Center" }, 403);

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  if (body?.action !== "dashboard") return json({ error: "Unknown action" }, 400);

  try {
    return json(await deps.loadDashboard());
  } catch (error) {
    deps.log("orvix admin dashboard failed", error);
    return json({ error: "Dashboard data unavailable" }, 500);
  }
}
