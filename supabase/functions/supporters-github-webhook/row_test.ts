// deno test supabase/functions/supporters-github-webhook/row_test.ts
import { githubSupporterRow } from "./row.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

const NOW = "2026-10-08T00:00:00.000Z";
const sponsor = {
  id: 1001,
  login: "fake-sponsor",
  name: "Fake Sponsor",
  avatar_url: "https://avatars.example.test/u/1001",
  html_url: "https://github.example.test/fake-sponsor",
};
const event = (privacy: unknown, action = "created") => ({
  action,
  sponsorship: {
    created_at: "2026-10-01T00:00:00Z",
    privacy_level: privacy,
    is_one_time_payment: false,
    tier: { name: "Fake tier" },
    sponsor,
  },
});

Deno.test("a public sponsorship is listed with the sponsor's details", () => {
  const row = githubSupporterRow(event("public"), NOW)!;
  assertEquals(
    [row.is_public, row.display_name, row.avatar_url, row.profile_url],
    [true, "Fake Sponsor", sponsor.avatar_url, sponsor.html_url],
  );
});

Deno.test("a private sponsorship is stored without identifying details", () => {
  for (const privacy of ["private", "PRIVATE", undefined, null, ""]) {
    const row = githubSupporterRow(event(privacy), NOW)!;
    assertEquals(
      [row.is_public, row.display_name, row.avatar_url, row.profile_url, row.is_active],
      [false, "Private supporter", null, null, true],
      String(privacy),
    );
  }
});

Deno.test("a cancelled sponsorship is hidden and inactive", () => {
  const row = githubSupporterRow(event("public", "cancelled"), NOW)!;
  assertEquals([row.is_public, row.is_active, row.display_name], [false, false, "Private supporter"]);
});

Deno.test("an event without a sponsor id is ignored", () => {
  assertEquals(githubSupporterRow({ action: "created", sponsorship: {} }, NOW), null);
});

Deno.test("ingestion keys every row by provider and provider_user_id", () => {
  // The upsert's conflict target. These identifiers stay server side; the
  // app reads list_public_supporters, which does not return them.
  for (const privacy of ["public", "private"]) {
    const row = githubSupporterRow(event(privacy), NOW)!;
    assertEquals([row.provider, row.provider_user_id], ["github", "1001"], privacy);
  }
});
