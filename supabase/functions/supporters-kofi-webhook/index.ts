import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const token = Deno.env.get("KOFI_VERIFICATION_TOKEN");
  if (!token) return new Response("Verification token not configured", { status: 503 });
  const form = await req.formData();
  const raw = form.get("data");
  if (typeof raw !== "string") return new Response("Missing data", { status: 400 });
  let body: any;
  try { body = JSON.parse(raw); } catch { return new Response("Invalid data", { status: 400 }); }
  if (body.verification_token !== token) return new Response("Invalid token", { status: 401 });
  const transactionId = String(body.kofi_transaction_id ?? "");
  if (!transactionId) return new Response("Missing transaction id", { status: 400 });
  const isPublic = body.is_public === true;
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  let supporterId = "tx:" + transactionId;
  if (email) {
    const bytes = new TextEncoder().encode(email);
    const hash = await crypto.subtle.digest("SHA-256", bytes);
    supporterId = "email-sha256:" + Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, "0")).join("");
  }
  const now = new Date().toISOString();
  const eventAt = typeof body.timestamp === "string" && !Number.isNaN(Date.parse(body.timestamp)) ? new Date(body.timestamp).toISOString() : now;
  const type = String(body.type ?? "Tip");
  const recurring = body.is_subscription_payment === true || type === "Subscription";
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { error } = await client.from("supporters").upsert({
    provider: "kofi", provider_user_id: supporterId,
    display_name: isPublic ? String(body.from_name ?? "Ko-fi supporter") : "Private supporter",
    avatar_url: null, profile_url: null,
    support_type: type === "Subscription" ? "Member" : "Supporter",
    tier: body.tier_name ? String(body.tier_name) : null,
    supporter_since: eventAt, last_supported_at: eventAt,
    is_recurring: recurring, is_active: true, is_public: isPublic, updated_at: now
  }, { onConflict: "provider,provider_user_id" });
  if (error) return new Response("Database error", { status: 500 });
  return Response.json({ ok: true });
});