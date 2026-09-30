import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !serviceKey || !anonKey) return Response.json({ error: "server_configuration" }, { status: 503 });

  let body: { device_code?: string; device_nonce?: string };
  try { body = await req.json(); } catch { return Response.json({ error: "invalid_request" }, { status: 400 }); }
  if (!body.device_code || !body.device_nonce) return Response.json({ error: "invalid_request" }, { status: 400 });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: rows, error: claimError } = await admin.rpc("claim_tv_login_session", {
    p_device_code: body.device_code,
    p_device_nonce: body.device_nonce,
  });
  if (claimError) return Response.json({ error: "claim_failed" }, { status: 400 });
  const userId = Array.isArray(rows) ? rows[0]?.user_id : null;
  if (!userId) return Response.json({ error: "not_approved_or_expired" }, { status: 409 });

  const { data: userData, error: userError } = await admin.auth.admin.getUserById(userId);
  const email = userData?.user?.email;
  if (userError || !email) return Response.json({ error: "user_unavailable" }, { status: 400 });

  const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  const tokenHash = linkData?.properties?.hashed_token;
  if (linkError || !tokenHash) return Response.json({ error: "session_generation_failed" }, { status: 500 });

  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: verified, error: verifyError } = await authClient.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
  if (verifyError || !verified.session) return Response.json({ error: "session_exchange_failed" }, { status: 500 });

  return Response.json({
    access_token: verified.session.access_token,
    refresh_token: verified.session.refresh_token,
    token_type: verified.session.token_type,
    expires_in: verified.session.expires_in,
  }, { headers: { "cache-control": "no-store" } });
});
