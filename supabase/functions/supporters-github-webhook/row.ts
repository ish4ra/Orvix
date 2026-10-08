// Builds the supporters row for a GitHub Sponsors "sponsorship" webhook.
//
// GitHub sends the sponsor's login, name and avatar for private sponsorships
// too (the maintainer can see them); privacy_level says whether the sponsor
// chose to be listed. Only a sponsorship GitHub reports as "public" is shown
// on the supporters wall; anything else is stored without identifying
// details, like private Buy Me a Coffee and Ko-fi supporters.
// deno-lint-ignore no-explicit-any
export function githubSupporterRow(body: any, now: string): Record<string, unknown> | null {
  const sponsorship = body?.sponsorship ?? {};
  const sponsor = sponsorship.sponsor;
  if (!sponsor?.id) return null;
  const action = String(body.action ?? "").toLowerCase();
  const inactive = action === "cancelled" || action === "canceled";
  const listed = String(sponsorship.privacy_level ?? "").toLowerCase() === "public";
  const visible = !inactive && listed;
  return {
    provider: "github",
    provider_user_id: String(sponsor.id),
    display_name: visible ? (sponsor.name ?? sponsor.login ?? "GitHub supporter") : "Private supporter",
    avatar_url: visible ? (sponsor.avatar_url ?? null) : null,
    profile_url: visible ? (sponsor.html_url ?? null) : null,
    support_type: sponsorship.is_one_time_payment ? "One-time sponsor" : "Sponsor",
    tier: sponsorship.tier?.name ?? null,
    supporter_since: sponsorship.created_at ?? now,
    last_supported_at: now,
    is_recurring: !sponsorship.is_one_time_payment,
    is_active: !inactive,
    is_public: visible,
    updated_at: now,
  };
}
