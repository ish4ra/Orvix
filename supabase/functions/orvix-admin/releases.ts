// GitHub release download statistics for the Control Center.
//
// What these numbers are: GitHub's per-asset `download_count`. Every manual
// download, re-download, in-app update download, CI/test download and
// browser retry counts. They are not installations, devices or people, and
// they cannot be turned into any of those after the fact.

import {
  type AssetKind,
  type AssetPlatform,
  classifyReleaseAsset,
  emptyPlatformCounts,
} from "./platforms.ts";
import { compareVersions, versionKey } from "./versions.ts";

type AnyRow = Record<string, any>;

export type GithubErrorCode =
  | "rate_limited"
  | "http_error"
  | "timeout"
  | "network"
  | "invalid_response";

export type GithubError = {
  code: GithubErrorCode;
  message: string;
  http_status: number | null;
  rate_limit_reset_at: string | null;
};

export type GithubFetchResult = {
  ok: boolean;
  releases: AnyRow[];
  fetched_at: string;
  pages: number;
  /// True when the page cap stopped the walk before GitHub ran out of pages.
  truncated: boolean;
  error: GithubError | null;
};

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type GithubFetchOptions = {
  repo: string;
  token?: string | null;
  perPage?: number;
  maxPages?: number;
  timeoutMs?: number;
  fetchImpl?: FetchLike;
  now?: () => number;
};

function rateLimitError(response: Response): GithubError | null {
  const remaining = response.headers.get("x-ratelimit-remaining");
  const isLimited = response.status === 429 ||
    (response.status === 403 && remaining === "0");
  if (!isLimited) return null;
  const reset = Number(response.headers.get("x-ratelimit-reset"));
  return {
    code: "rate_limited",
    message: "GitHub API rate limit reached",
    http_status: response.status,
    rate_limit_reset_at: Number.isFinite(reset) && reset > 0
      ? new Date(reset * 1000).toISOString()
      : null,
  };
}

/// Walks every release page (newest first) until GitHub returns a short page
/// or the page cap is reached. Releases seen twice (a release published
/// while paging shifts the pages) are kept once.
export async function fetchGithubReleases(
  options: GithubFetchOptions,
): Promise<GithubFetchResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const perPage = options.perPage ?? 100;
  const maxPages = options.maxPages ?? 10;
  const timeoutMs = options.timeoutMs ?? 5000;
  const now = options.now ?? Date.now;

  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "Orvix-Control-Center",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;

  const seen = new Set<string>();
  const releases: AnyRow[] = [];
  let pages = 0;
  let truncated = false;

  const fail = (error: GithubError): GithubFetchResult => ({
    ok: false,
    releases: [],
    fetched_at: new Date(now()).toISOString(),
    pages,
    truncated: false,
    error,
  });

  for (let page = 1; page <= maxPages; page++) {
    let response: Response;
    try {
      response = await fetchImpl(
        `https://api.github.com/repos/${options.repo}/releases?per_page=${perPage}&page=${page}`,
        { headers, signal: AbortSignal.timeout(timeoutMs) },
      );
    } catch (error) {
      const name = (error as { name?: string })?.name ?? "";
      const timedOut = name === "TimeoutError" || name === "AbortError";
      return fail({
        code: timedOut ? "timeout" : "network",
        message: timedOut ? "GitHub did not answer in time" : "GitHub could not be reached",
        http_status: null,
        rate_limit_reset_at: null,
      });
    }

    if (!response.ok) {
      return fail(rateLimitError(response) ?? {
        code: "http_error",
        message: `GitHub answered HTTP ${response.status}`,
        http_status: response.status,
        rate_limit_reset_at: null,
      });
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    if (!Array.isArray(body)) {
      return fail({
        code: "invalid_response",
        message: "GitHub returned an unexpected response",
        http_status: response.status,
        rate_limit_reset_at: null,
      });
    }

    pages = page;
    for (const release of body as AnyRow[]) {
      const key = String(release?.id ?? release?.tag_name ?? "");
      if (!key || seen.has(key)) continue;
      seen.add(key);
      releases.push(release);
    }

    const hasNext = (response.headers.get("link") ?? "").includes('rel="next"');
    if (body.length < perPage && !hasNext) break;
    if (page === maxPages) truncated = true;
  }

  return {
    ok: true,
    releases,
    fetched_at: new Date(now()).toISOString(),
    pages,
    truncated,
    error: null,
  };
}

export type CachedGithubResult = GithubFetchResult & {
  /// "live": fetched for this request. "cache": a fresh cached copy.
  /// "stale": GitHub failed and the last good copy is served instead.
  source: "live" | "cache" | "stale";
  /// The error of the latest attempt, even when stale data is served.
  last_error: GithubError | null;
};

/// Keeps the last good GitHub answer for `ttlMs` so dashboard refreshes do
/// not spend the shared unauthenticated rate limit, and serves it (marked
/// stale) when GitHub later fails.
export class GithubReleaseCache {
  private value: GithubFetchResult | null = null;
  private storedAt = 0;
  private inFlight: Promise<CachedGithubResult> | null = null;

  constructor(
    private readonly ttlMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  get(loader: () => Promise<GithubFetchResult>): Promise<CachedGithubResult> {
    if (this.value && this.now() - this.storedAt < this.ttlMs) {
      return Promise.resolve({ ...this.value, source: "cache", last_error: null });
    }
    if (this.inFlight) return this.inFlight;
    this.inFlight = (async () => {
      try {
        const result = await loader();
        if (result.ok) {
          this.value = result;
          this.storedAt = this.now();
          return { ...result, source: "live" as const, last_error: null };
        }
        if (this.value) {
          return {
            ...this.value,
            source: "stale" as const,
            last_error: result.error,
          };
        }
        return { ...result, source: "live" as const, last_error: result.error };
      } finally {
        this.inFlight = null;
      }
    })();
    return this.inFlight;
  }
}

export type ReleaseChannel = "stable" | "prerelease" | "draft";

export type AssetSummary = {
  name: string;
  downloads: number;
  size: number;
  asset_platform: AssetPlatform;
  variant: string;
  kind: AssetKind;
};

export type ReleaseSummary = {
  tag: string;
  name: string | null;
  version: string | null;
  published_at: string | null;
  created_at: string | null;
  prerelease: boolean;
  draft: boolean;
  channel: ReleaseChannel;
  /// "component" releases ship build helpers (the Windows stream server),
  /// not the app.
  release_kind: "app" | "component";
  /// App-asset downloads only; checksums and helper binaries are excluded.
  total_downloads: number;
  downloads_by_platform: Record<AssetPlatform, number>;
  assets: AssetSummary[];
};

export type VariantTotal = {
  platform: AssetPlatform;
  variant: string;
  downloads: number;
};

export type DownloadTotals = {
  /// Public (non-draft) app releases only.
  public_app_downloads: number;
  by_platform: Record<AssetPlatform, number>;
  by_variant: VariantTotal[];
  by_channel: { stable: number; prerelease: number };
  public_app_releases: number;
  stable_releases: number;
  prerelease_releases: number;
  draft: { releases: number; downloads: number };
  component_downloads: number;
  metadata_downloads: number;
};

function count(value: unknown): number {
  const n = Number(value ?? 0);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

export function summarizeRelease(release: AnyRow): ReleaseSummary {
  const tag = String(release.tag_name ?? "");
  const seenAssets = new Set<string>();
  const assets: AssetSummary[] = [];
  for (const asset of Array.isArray(release.assets) ? release.assets : []) {
    const key = String(asset?.id ?? asset?.name ?? "");
    if (!key || seenAssets.has(key)) continue;
    seenAssets.add(key);
    const classification = classifyReleaseAsset(asset.name);
    assets.push({
      name: String(asset.name ?? ""),
      downloads: count(asset.download_count),
      size: count(asset.size),
      asset_platform: classification.platform,
      variant: classification.variant,
      kind: classification.kind,
    });
  }

  const appAssets = assets.filter((asset) => asset.kind === "app");
  const releaseKind =
    tag.toLowerCase().startsWith("stream-server") || (assets.length > 0 && appAssets.length === 0)
      ? "component"
      : "app";

  const downloadsByPlatform = emptyPlatformCounts();
  if (releaseKind === "app") {
    for (const asset of appAssets) {
      downloadsByPlatform[asset.asset_platform] += asset.downloads;
    }
  }

  const draft = release.draft === true;
  const prerelease = release.prerelease === true;
  return {
    tag,
    name: typeof release.name === "string" ? release.name : null,
    version: releaseKind === "app" ? versionKey(tag) : null,
    published_at: typeof release.published_at === "string" ? release.published_at : null,
    created_at: typeof release.created_at === "string" ? release.created_at : null,
    prerelease,
    draft,
    channel: draft ? "draft" : prerelease ? "prerelease" : "stable",
    release_kind: releaseKind,
    total_downloads: releaseKind === "app"
      ? appAssets.reduce((sum, asset) => sum + asset.downloads, 0)
      : 0,
    downloads_by_platform: downloadsByPlatform,
    assets,
  };
}

/// Newest version first; component releases after app releases.
export function compareReleasesDescending(a: ReleaseSummary, b: ReleaseSummary): number {
  if (a.release_kind !== b.release_kind) return a.release_kind === "app" ? -1 : 1;
  const byVersion = compareVersions(b.tag, a.tag);
  if (byVersion !== 0) return byVersion;
  return String(b.published_at ?? b.created_at ?? "").localeCompare(
    String(a.published_at ?? a.created_at ?? ""),
  );
}

export function summarizeReleases(raw: AnyRow[]): {
  releases: ReleaseSummary[];
  totals: DownloadTotals;
} {
  const releases = raw.map(summarizeRelease).sort(compareReleasesDescending);
  const totals: DownloadTotals = {
    public_app_downloads: 0,
    by_platform: emptyPlatformCounts(),
    by_variant: [],
    by_channel: { stable: 0, prerelease: 0 },
    public_app_releases: 0,
    stable_releases: 0,
    prerelease_releases: 0,
    draft: { releases: 0, downloads: 0 },
    component_downloads: 0,
    metadata_downloads: 0,
  };
  const variants = new Map<string, VariantTotal>();

  for (const release of releases) {
    if (release.draft) {
      // Drafts are private test builds: listed for the owner, never in totals.
      totals.draft.releases++;
      totals.draft.downloads += release.total_downloads;
      continue;
    }
    for (const asset of release.assets) {
      if (asset.kind === "metadata") totals.metadata_downloads += asset.downloads;
      if (asset.kind === "component" || release.release_kind === "component") {
        if (asset.kind !== "metadata") totals.component_downloads += asset.downloads;
      }
    }
    if (release.release_kind !== "app") continue;

    totals.public_app_releases++;
    if (release.prerelease) totals.prerelease_releases++;
    else totals.stable_releases++;
    totals.public_app_downloads += release.total_downloads;
    if (release.prerelease) totals.by_channel.prerelease += release.total_downloads;
    else totals.by_channel.stable += release.total_downloads;

    for (const asset of release.assets) {
      if (asset.kind !== "app") continue;
      totals.by_platform[asset.asset_platform] += asset.downloads;
      const key = `${asset.asset_platform}\u0000${asset.variant}`;
      const entry = variants.get(key) ??
        { platform: asset.asset_platform, variant: asset.variant, downloads: 0 };
      entry.downloads += asset.downloads;
      variants.set(key, entry);
    }
  }

  totals.by_variant = [...variants.values()].sort((a, b) =>
    a.platform === b.platform ? b.downloads - a.downloads : a.platform.localeCompare(b.platform)
  );
  return { releases, totals };
}

/// Maps a reported app version to the channel of its GitHub release, so the
/// dashboard can tell a public beta from a private draft or a local build.
export function releaseChannelIndex(
  releases: ReleaseSummary[],
): Map<string, ReleaseChannel> {
  const index = new Map<string, ReleaseChannel>();
  for (const release of releases) {
    if (release.release_kind !== "app" || !release.version) continue;
    const existing = index.get(release.version);
    // A public release wins over a draft that reuses the same tag.
    if (!existing || existing === "draft") index.set(release.version, release.channel);
  }
  return index;
}
