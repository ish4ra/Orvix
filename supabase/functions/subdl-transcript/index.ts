import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

type Candidate = {
  id: string;
  url: string;
  label: string;
  language: string;
  provider: string;
  score: number;
};

const cache = new Map<string, { expires: number; candidates: Candidate[] }>();

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function cleanString(value: unknown, max = 300): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function cleanInt(value: unknown): number | null {
  const n = Number(value);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

function normalizedDownloadUrl(raw: unknown): string {
  const value = cleanString(raw, 1000);
  if (!value) return "";
  if (/^https?:\/\//i.test(value)) return value;
  return "https://dl.subdl.com" + (value.startsWith("/") ? value : "/" + value);
}

function candidateFrom(raw: Record<string, unknown>, fallbackScore = 0): Candidate | null {
  const url = normalizedDownloadUrl(raw.url);
  if (!url) return null;
  const label = cleanString(
    raw.release_name ?? raw.releaseName ?? raw.name ?? raw.filename ?? "SubDL subtitle",
    500,
  );
  const id = cleanString(
    raw.file_n_id ?? raw.n_id ?? raw.id ?? raw.md5 ?? url,
    500,
  );
  const matchScore = Number(raw.match_score ?? raw.matchScore);
  const score = Number.isFinite(matchScore)
    ? Math.round(matchScore * 1000) + 560
    : fallbackScore + 520;
  return {
    id: "subdl:" + id,
    url,
    label: label || "SubDL subtitle",
    language: "eng",
    provider: "SubDL",
    score,
  };
}

function collectCandidates(payload: unknown, fallbackScore = 0): Candidate[] {
  if (!payload || typeof payload !== "object") return [];
  const body = payload as Record<string, unknown>;
  const out: Candidate[] = [];
  const seen = new Set<string>();

  const subtitles = Array.isArray(body.subtitles) ? body.subtitles : [];
  for (const entry of subtitles) {
    if (!entry || typeof entry !== "object") continue;
    const raw = entry as Record<string, unknown>;

    const unpack = Array.isArray(raw.unpack_files) ? raw.unpack_files : [];
    let addedUnpacked = false;
    for (const unpacked of unpack) {
      if (!unpacked || typeof unpacked !== "object") continue;
      const candidate = candidateFrom(
        unpacked as Record<string, unknown>,
        fallbackScore + 20,
      );
      if (candidate && seen.add(candidate.url)) {
        out.push(candidate);
        addedUnpacked = true;
      }
    }

    if (!addedUnpacked) {
      const candidate = candidateFrom(raw, fallbackScore);
      if (candidate && seen.add(candidate.url)) out.push(candidate);
    }
  }

  return out;
}

async function subdlGet(
  path: string,
  params: URLSearchParams,
  apiKey: string,
): Promise<Record<string, unknown> | null> {
  const url = new URL("https://api.subdl.com" + path);
  for (const [key, value] of params) url.searchParams.set(key, value);
  try {
    const response = await fetch(url, {
      headers: {
        Authorization: "Bearer " + apiKey,
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) {
      console.error("SubDL request failed", response.status, path);
      return null;
    }
    const decoded = await response.json();
    return decoded && typeof decoded === "object"
      ? decoded as Record<string, unknown>
      : null;
  } catch (error) {
    console.error("SubDL request unavailable", path, error);
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const apiKey = Deno.env.get("SUBDL_API_KEY")?.trim();
  if (!apiKey) {
    return reply(503, {
      error: "subdl_not_configured",
      message: "Server-side SubDL fallback is not configured.",
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return reply(400, { error: "invalid_json" });
  }

  const imdbId = cleanString(body.imdb_id, 32).toLowerCase();
  const type = cleanString(body.type, 16).toLowerCase();
  const fileName = cleanString(body.file_name, 500);
  const season = cleanInt(body.season);
  const episode = cleanInt(body.episode);
  const year = cleanInt(body.year);

  if (!/^tt\d+$/.test(imdbId)) {
    return reply(400, { error: "invalid_imdb_id" });
  }
  if (type !== "movie" && type !== "tv") {
    return reply(400, { error: "invalid_type" });
  }

  const cacheKey = JSON.stringify({ imdbId, type, fileName, season, episode, year });
  const cached = cache.get(cacheKey);
  if (cached && cached.expires > Date.now()) {
    return reply(200, { status: true, cached: true, candidates: cached.candidates });
  }

  const byUrl = new Map<string, Candidate>();

  if (fileName) {
    const params = new URLSearchParams({
      filename: fileName,
      languages: "en",
      type,
      engine: "local",
      episode_scope: "exact",
      subs_per_page: "30",
    });
    const fileSearch = await subdlGet("/api/v2/files/search", params, apiKey);
    for (const candidate of collectCandidates(fileSearch, 80)) {
      byUrl.set(candidate.url, candidate);
    }
  }

  if (byUrl.size < 4) {
    const params = new URLSearchParams({
      imdb_id: imdbId,
      languages: "en",
      type,
      unpack: "1",
    });
    if (season != null && season > 0) params.set("season", String(season));
    if (episode != null && episode > 0) params.set("episode", String(episode));
    if (year != null && year > 0) params.set("year", String(year));

    const subtitleSearch = await subdlGet(
      "/api/v2/subtitles/search",
      params,
      apiKey,
    );
    for (const candidate of collectCandidates(subtitleSearch, 30)) {
      const existing = byUrl.get(candidate.url);
      if (!existing || candidate.score > existing.score) {
        byUrl.set(candidate.url, candidate);
      }
    }
  }

  const candidates = [...byUrl.values()]
    .sort((a, b) => b.score - a.score || a.label.localeCompare(b.label))
    .slice(0, 30);

  cache.set(cacheKey, {
    expires: Date.now() + 10 * 60 * 1000,
    candidates,
  });
  if (cache.size > 128) {
    const first = cache.keys().next().value;
    if (first) cache.delete(first);
  }

  return reply(200, { status: true, cached: false, candidates });
});
