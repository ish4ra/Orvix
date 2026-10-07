import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleTvLoginExchange } from "./handler.ts";

// Deploy with --no-verify-jwt: the TV is signed out and calls with the
// project's publishable key. The device code and nonce authenticate the TV;
// see README.md. The service role key comes from the environment only.
Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !serviceKey || !anonKey) {
    return Response.json({ error: "server_configuration" }, {
      status: 503,
      headers: { "cache-control": "no-store" },
    });
  }
  const options = { auth: { persistSession: false, autoRefreshToken: false } };
  const admin = createClient(url, serviceKey, options);

  return handleTvLoginExchange(req, {
    async beginExchange(deviceCode, deviceNonce) {
      const { data, error } = await admin.rpc("begin_tv_login_exchange", {
        p_device_code: deviceCode,
        p_device_nonce: deviceNonce,
      });
      if (error) throw new Error("begin_failed");
      const row = Array.isArray(data) ? data[0] : null;
      if (row?.state === "leased" && row.user_id && row.exchange_token) {
        return { state: "leased", userId: row.user_id, exchangeToken: row.exchange_token };
      }
      return { state: row?.state === "busy" ? "busy" : "unavailable" };
    },
    async createSession(userId) {
      const { data: userData, error: userError } = await admin.auth.admin.getUserById(userId);
      if (userError?.status === 404) return "user_unavailable";
      if (userError) throw new Error("user_lookup_failed");
      const email = userData?.user?.email;
      if (!email) return "user_unavailable";

      const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email,
      });
      const tokenHash = linkData?.properties?.hashed_token;
      if (linkError || !tokenHash) throw new Error("link_failed");

      const authClient = createClient(url, anonKey, options);
      const { data: verified, error: verifyError } = await authClient.auth.verifyOtp({
        token_hash: tokenHash,
        type: "email",
      });
      if (verifyError || !verified.session) throw new Error("verify_failed");
      return {
        access_token: verified.session.access_token,
        refresh_token: verified.session.refresh_token,
        token_type: verified.session.token_type,
        expires_in: verified.session.expires_in,
      };
    },
    async completeExchange(deviceCode, exchangeToken) {
      const { data, error } = await admin.rpc("complete_tv_login_exchange", {
        p_device_code: deviceCode,
        p_exchange_token: exchangeToken,
      });
      if (error) throw new Error("complete_failed");
      return data === true;
    },
    async releaseExchange(deviceCode, exchangeToken) {
      const { error } = await admin.rpc("release_tv_login_exchange", {
        p_device_code: deviceCode,
        p_exchange_token: exchangeToken,
      });
      if (error) throw new Error("release_failed");
    },
    async revokeSession(accessToken) {
      const { error } = await admin.auth.admin.signOut(accessToken, "local");
      if (error) throw new Error("revoke_failed");
    },
    log: (message) => console.error(message),
  });
});
