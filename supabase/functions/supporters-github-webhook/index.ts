import { hmacHex, safeEqual, upsertSupporter } from "../_shared/supporters.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("GITHUB_SPONSORS_WEBHOOK_SECRET");
  if (!secret) return new Response("Webhook secret not configured", { status: 503 });

  const raw = await req.text();
  const signature = req.headers.get("x-hub-signature-256") ?? "";
  const expected = "sha256=" + await hmacHex(secret, raw);
  if (!safeEqual(signature, expected)) return new Response("Invalid signature", { status: 401 });

  const body = JSON.parse(raw);
  const sponsorship = body.sponsorship ?? {};
  const sponsor = sponsorship.sponsor;
  if (!sponsor?.id) return Response.json({ ok: true, ignored: "private sponsor" });

  const id = String(sponsor.id);
  const cancelled = String(body.action ?? "") === "cancelled";
  await upsertSupporter({
    provider: "github", provider_user_id: id,
    display_name: sponsor.name ?? sponsor.login ?? "GitHub supporter",
    avatar_url: sponsor.avatar_url ?? null, profile_url: sponsor.html_url ?? null,
    support_type: sponsorship.is_one_time_payment ? "One-time sponsor" : "Sponsor",
    tier: sponsorship.tier?.name ?? null,
    supporter_since: sponsorship.created_at ?? new Date().toISOString(),
    last_supported_at: new Date().toISOString(),
    is_recurring: !sponsorship.is_one_time_payment,
    is_active: !cancelled, is_public: !cancelled,
    updated_at: new Date().toISOString(),
  });
  return Response.json({ ok: true });
});
