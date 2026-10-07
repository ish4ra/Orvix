// Browser fallback for the Orvix TV QR code: a phone without the Orvix app
// signs in here and approves the code. Deploy with --no-verify-jwt (a browser
// opens the link without a token).
import { linkCode, linkPage, securityHeaders } from "./page.ts";

Deno.serve((req) => {
  if (req.method !== "GET") return new Response("Method not allowed", { status: 405 });
  const code = linkCode(req.url);
  if (!code) {
    return new Response("Invalid link code", { status: 400, headers: { "cache-control": "no-store" } });
  }
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !anon) return new Response("Server configuration error", { status: 503 });
  const nonce = crypto.randomUUID().replace(/-/g, "");
  return new Response(linkPage(url, anon, code, nonce), { headers: securityHeaders(url, nonce) });
});
