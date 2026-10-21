// deno test --allow-read supabase/functions/orvix-admin/
import {
  fetchGithubReleases,
  type GithubFetchResult,
  GithubReleaseCache,
  releaseChannelIndex,
  summarizeReleases,
} from "./releases.ts";
import { assert, assertEquals } from "./test_assert.ts";

// Real asset names and public counts of nine Orvix releases, including a
// draft, a stream-server component release, Pikora-era Windows files, a DMG,
// the Compat APK and both iOS IPA generations.
const fixture = JSON.parse(
  await Deno.readTextFile(new URL("./fixtures/github_releases.json", import.meta.url)),
);

Deno.test("public totals add up per platform with no asset counted twice", () => {
  const { totals } = summarizeReleases(fixture);
  assertEquals(totals.by_platform, {
    "Android Mobile": 87,
    "Android TV": 22,
    "Windows": 18,
    "macOS": 5,
    "iOS": 2,
    "Other": 0,
  });
  assertEquals(totals.public_app_downloads, 134);
  const platformSum = Object.values(totals.by_platform).reduce((a, b) => a + b, 0);
  assertEquals(platformSum, totals.public_app_downloads, "platform split equals total");
  assertEquals(totals.by_channel, { stable: 58, prerelease: 76 });
  assertEquals(totals.public_app_releases, 7);
  assertEquals(totals.stable_releases, 2);
  assertEquals(totals.prerelease_releases, 5);
});

Deno.test("drafts are excluded from totals but listed as drafts", () => {
  const withDraftDownloads = fixture.map((r: any) =>
    r.draft ? { ...r, assets: r.assets.map((a: any) => ({ ...a, download_count: 50 })) } : r
  );
  const { releases, totals } = summarizeReleases(withDraftDownloads);
  assertEquals(totals.public_app_downloads, 134);
  assertEquals(totals.draft, { releases: 1, downloads: 250 });
  const draft = releases.find((r) => r.tag === "v0.7.10-beta.3")!;
  assertEquals(draft.channel, "draft");
  assertEquals(draft.total_downloads, 250);
});

Deno.test("stream-server downloads are a component, not Windows", () => {
  const { releases, totals } = summarizeReleases(fixture);
  assertEquals(totals.component_downloads, 84);
  assertEquals(totals.by_platform.Windows, 18);
  const component = releases.find((r) => r.tag.startsWith("stream-server"))!;
  assertEquals(component.release_kind, "component");
  assertEquals(component.total_downloads, 0);
  assertEquals(component.version, null);
});

Deno.test("Windows installer and ZIP are reported separately and summed once", () => {
  const { totals, releases } = summarizeReleases(fixture);
  const windows = totals.by_variant.filter((v) => v.platform === "Windows");
  assertEquals(windows, [
    { platform: "Windows", variant: "Installer", downloads: 11 },
    { platform: "Windows", variant: "Portable ZIP", downloads: 7 },
  ]);
  const beta4 = releases.find((r) => r.tag === "v0.7.10-beta.4")!;
  assertEquals(beta4.downloads_by_platform.Windows, 5);
  assertEquals(beta4.downloads_by_platform.iOS, 2);
  assertEquals(beta4.total_downloads, 39);
});

Deno.test("Android Mobile includes universal and per-ABI APKs; TV stays separate", () => {
  const { releases } = summarizeReleases(fixture);
  const stable = releases.find((r) => r.tag === "v0.7.9")!;
  assertEquals(stable.downloads_by_platform["Android Mobile"], 32);
  assertEquals(stable.downloads_by_platform["Android TV"], 13);
});

Deno.test("releases are ordered newest version first, components last", () => {
  const { releases } = summarizeReleases(fixture);
  assertEquals(releases.map((r) => r.tag), [
    "v0.7.10-beta.4",
    "v0.7.10-beta.3",
    "v0.7.9",
    "v0.7.9-beta.69",
    "v0.7.9-beta.68",
    "v0.7.4-alpha.01",
    "v0.7.3-alpha.9",
    "v0.3.2",
    "stream-server-orvix-v0.1.8.3",
  ]);
});

Deno.test("duplicate assets inside a release are counted once", () => {
  const release = fixture.find((r: any) => r.tag_name === "v0.7.9");
  const duplicated = { ...release, assets: [...release.assets, release.assets[0]] };
  const { totals } = summarizeReleases([duplicated]);
  assertEquals(totals.public_app_downloads, 53);
});

Deno.test("empty and malformed release lists produce zero totals", () => {
  const { releases, totals } = summarizeReleases([]);
  assertEquals(releases, []);
  assertEquals(totals.public_app_downloads, 0);
  const odd = summarizeReleases([{ tag_name: "v1.0.0", assets: [{ name: "Orvix-v1.0.0-Android-TV.apk", download_count: "x" }] }]);
  assertEquals(odd.totals.public_app_downloads, 0);
});

Deno.test("release channel index prefers a public release over a draft", () => {
  const { releases } = summarizeReleases([
    ...fixture,
    { id: 1, tag_name: "v0.7.9", draft: true, prerelease: false, assets: [] },
  ]);
  const index = releaseChannelIndex(releases);
  assertEquals(index.get("0.7.9"), "stable");
  assertEquals(index.get("0.7.10-beta.4"), "prerelease");
  assertEquals(index.get("0.7.10-beta.3"), "draft");
  assertEquals(index.has("0.1.8.3"), false);
});

function page(body: unknown, init: ResponseInit & { link?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.link) headers.set("link", init.link);
  return new Response(JSON.stringify(body), { status: init.status ?? 200, headers });
}

Deno.test("pagination walks every page and dedupes shifted releases", async () => {
  const pages: Record<number, unknown[]> = {
    1: [{ id: 1, tag_name: "v3" }, { id: 2, tag_name: "v2" }],
    2: [{ id: 2, tag_name: "v2" }, { id: 3, tag_name: "v1" }],
    3: [{ id: 4, tag_name: "v0" }],
  };
  const urls: string[] = [];
  const result = await fetchGithubReleases({
    repo: "ish4ra/Orvix",
    perPage: 2,
    fetchImpl: (url) => {
      urls.push(url);
      const n = Number(new URL(url).searchParams.get("page"));
      return Promise.resolve(page(pages[n] ?? [], { link: n < 3 ? '<x>; rel="next"' : "" }));
    },
  });
  assertEquals(result.ok, true);
  assertEquals(result.releases.map((r) => r.id), [1, 2, 3, 4]);
  assertEquals(result.pages, 3);
  assertEquals(result.truncated, false);
  assert(urls[0].includes("per_page=2&page=1"), urls[0]);
});

Deno.test("the page cap is reported as truncated", async () => {
  const result = await fetchGithubReleases({
    repo: "ish4ra/Orvix",
    perPage: 1,
    maxPages: 2,
    fetchImpl: (url) => Promise.resolve(page([{ id: Number(new URL(url).searchParams.get("page")) }])),
  });
  assertEquals(result.truncated, true);
  assertEquals(result.releases.length, 2);
});

Deno.test("rate limits, HTTP errors, timeouts and bad JSON are reported, not zeroed", async () => {
  const limited = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () =>
      Promise.resolve(page({ message: "API rate limit exceeded" }, {
        status: 403,
        headers: { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000" },
      })),
  });
  assertEquals(limited.ok, false);
  assertEquals(limited.error?.code, "rate_limited");
  assertEquals(limited.error?.rate_limit_reset_at, "2027-01-15T08:00:00.000Z");

  const forbidden = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () => Promise.resolve(page({}, { status: 403, headers: { "x-ratelimit-remaining": "12" } })),
  });
  assertEquals(forbidden.error?.code, "http_error");

  const tooMany = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () => Promise.resolve(page({}, { status: 429 })),
  });
  assertEquals(tooMany.error?.code, "rate_limited");

  const timeout = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () => Promise.reject(new DOMException("timed out", "TimeoutError")),
  });
  assertEquals(timeout.error?.code, "timeout");

  const offline = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () => Promise.reject(new TypeError("dns")),
  });
  assertEquals(offline.error?.code, "network");

  const notArray = await fetchGithubReleases({
    repo: "r/r",
    fetchImpl: () => Promise.resolve(page({ message: "Not Found" })),
  });
  assertEquals(notArray.error?.code, "invalid_response");
  assertEquals(notArray.releases, []);
});

Deno.test("an empty repository is ok with no releases", async () => {
  const result = await fetchGithubReleases({ repo: "r/r", fetchImpl: () => Promise.resolve(page([])) });
  assertEquals(result.ok, true);
  assertEquals(result.releases, []);
});

Deno.test("token is sent only when configured", async () => {
  const seen: (string | null)[] = [];
  const fetchImpl = (_url: string, init?: RequestInit) => {
    seen.push(new Headers(init?.headers).get("authorization"));
    return Promise.resolve(page([]));
  };
  await fetchGithubReleases({ repo: "r/r", fetchImpl });
  await fetchGithubReleases({ repo: "r/r", token: "test-token", fetchImpl });
  assertEquals(seen, [null, "Bearer test-token"]);
});

function ok(tag: string, at: number): GithubFetchResult {
  return { ok: true, releases: [{ id: tag, tag_name: tag }], fetched_at: new Date(at).toISOString(), pages: 1, truncated: false, error: null };
}
function failed(at: number): GithubFetchResult {
  return {
    ok: false,
    releases: [],
    fetched_at: new Date(at).toISOString(),
    pages: 0,
    truncated: false,
    error: { code: "rate_limited", message: "GitHub API rate limit reached", http_status: 403, rate_limit_reset_at: null },
  };
}

Deno.test("cache serves fresh copies, refreshes after the TTL, and falls back to stale data", async () => {
  let clock = 1_000_000;
  const cache = new GithubReleaseCache(600_000, () => clock);
  let calls = 0;

  const first = await cache.get(() => { calls++; return Promise.resolve(ok("v1", clock)); });
  assertEquals([first.source, calls], ["live", 1]);

  clock += 60_000;
  const cached = await cache.get(() => { calls++; return Promise.resolve(ok("v2", clock)); });
  assertEquals([cached.source, cached.releases[0].tag_name, calls], ["cache", "v1", 1]);

  clock += 600_000;
  const stale = await cache.get(() => { calls++; return Promise.resolve(failed(clock)); });
  assertEquals([stale.source, stale.releases[0].tag_name, stale.last_error?.code, calls], ["stale", "v1", "rate_limited", 2]);
  assertEquals(stale.fetched_at, new Date(1_000_000).toISOString(), "stale data keeps its original fetch time");

  const refreshed = await cache.get(() => { calls++; return Promise.resolve(ok("v3", clock)); });
  assertEquals([refreshed.source, refreshed.releases[0].tag_name], ["live", "v3"]);
});

Deno.test("cache without a previous copy surfaces the failure", async () => {
  const cache = new GithubReleaseCache(600_000, () => 0);
  const result = await cache.get(() => Promise.resolve(failed(0)));
  assertEquals([result.ok, result.source, result.last_error?.code], [false, "live", "rate_limited"]);
});

Deno.test("concurrent refreshes share one GitHub request", async () => {
  const cache = new GithubReleaseCache(600_000, () => 0);
  let calls = 0;
  const loader = () => { calls++; return new Promise<GithubFetchResult>((r) => setTimeout(() => r(ok("v1", 0)), 5)); };
  await Promise.all([cache.get(loader), cache.get(loader), cache.get(loader)]);
  assertEquals(calls, 1);
});
