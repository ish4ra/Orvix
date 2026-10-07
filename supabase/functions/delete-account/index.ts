import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleDeleteAccount } from "./handler.ts";

// Deploy with JWT verification on (the default; never --no-verify-jwt).
// The service role key comes from the function's environment only.
Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!url || !serviceKey) {
    return Response.json({ error: "server_configuration" }, { status: 503 });
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return handleDeleteAccount(req, {
    async lookupCaller(accessToken) {
      const { data, error } = await admin.auth.getUser(accessToken);
      if (!error && data?.user?.id) return { kind: "user", id: data.user.id };
      if (error?.code === "user_not_found") return { kind: "not_found" };
      if (!error?.status || error.status >= 500) throw new Error("auth_unavailable");
      return { kind: "invalid" };
    },
    async deleteAccountData(userId) {
      const { error } = await admin.rpc("delete_orvix_account_data", { p_user_id: userId });
      if (error) throw new Error("cleanup_failed");
    },
    async deleteAuthUser(userId) {
      // Hard delete: the user row, its sessions and identities are removed.
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (!error) return "deleted";
      if (error.code === "user_not_found" || error.status === 404) return "not_found";
      throw new Error("delete_failed");
    },
    nowSeconds: () => Math.floor(Date.now() / 1000),
    log: (message) => console.error(message),
  });
});
