// deno test --allow-read supabase/functions/orvix-admin/
import { compareVersions, isPrereleaseVersion, parseVersion, versionKey } from "./versions.ts";
import { assert, assertEquals } from "./test_assert.ts";

Deno.test("prerelease numbers order numerically, not lexically", () => {
  const shuffled = ["0.7.10-beta.100", "0.7.10-beta.9", "0.7.10-beta.999", "0.7.10-beta.10", "0.7.10-beta.99"];
  assertEquals([...shuffled].sort(compareVersions), [
    "0.7.10-beta.9",
    "0.7.10-beta.10",
    "0.7.10-beta.99",
    "0.7.10-beta.100",
    "0.7.10-beta.999",
  ]);
});

Deno.test("a release ranks above its prereleases and below the next minor", () => {
  const sorted = ["0.7.10", "0.7.9", "0.7.10-beta.4", "0.7.9-beta.71", "0.7.10-alpha.1", "0.7.10-rc.1", "0.8.0-beta.1"]
    .sort(compareVersions);
  assertEquals(sorted, [
    "0.7.9-beta.71",
    "0.7.9",
    "0.7.10-alpha.1",
    "0.7.10-beta.4",
    "0.7.10-rc.1",
    "0.7.10",
    "0.8.0-beta.1",
  ]);
});

Deno.test("v0.7.9 and v0.7.10-beta.4 compare across the minor-patch boundary", () => {
  assert(compareVersions("0.7.10-beta.4", "0.7.9") > 0, "0.7.10-beta.4 is newer than 0.7.9");
  assert(compareVersions("v0.7.9", "0.7.9") === 0, "leading v is ignored");
  assert(compareVersions("0.7.9+4223", "0.7.9") === 0, "+BUILD does not affect order");
});

Deno.test("leading zeros and four-part component versions parse", () => {
  assert(compareVersions("0.7.4-alpha.01", "0.7.4-alpha.2") < 0, "alpha.01 < alpha.2");
  assertEquals(parseVersion("stream-server-orvix-v0.1.8.3"), null);
  assertEquals(parseVersion("0.1.8.3")?.core, [0, 1, 8, 3]);
});

Deno.test("unparseable versions sort below real versions", () => {
  assertEquals(["Unknown", "0.7.9", "dev"].sort(compareVersions), ["dev", "Unknown", "0.7.9"]);
});

Deno.test("versionKey strips v and +BUILD", () => {
  assertEquals(versionKey("v0.7.10-beta.4+4230"), "0.7.10-beta.4");
  assertEquals(versionKey("  "), null);
  assertEquals(versionKey(42), null);
  assert(isPrereleaseVersion("0.7.10-beta.4"), "beta is prerelease");
  assert(!isPrereleaseVersion("0.7.9"), "0.7.9 is stable");
});
