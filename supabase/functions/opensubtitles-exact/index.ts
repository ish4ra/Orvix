import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function asNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function candidateScore(attrs: Record<string, unknown>): number {
  let score = 0;
  if (attrs.foreign_parts_only === true) score -= 500_000;
  if (attrs.hearing_impaired === true) score -= 20_000;
  if (attrs.machine_translated === true || attrs.ai_translated === true) score -= 5_000;
  if (attrs.from_trusted === true) score += 25_000;
  score += Math.round(asNumber(attrs.ratings) * 1_000);
  score += asNumber(attrs.download_count);
  score += asNumber(attrs.new_download_count);
  return score;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const apiKey = Deno.env.get("OPENSUBTITLES_API_KEY")?.trim();
  if (!apiKey) {
    return reply(503, {
      error: "opensubtitles_rest_not_configured",
      message: "OpenSubtitles REST API key is not configured on the Orvix backend.",
    });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch (_) {
    return reply(400, { error: "invalid_json" });
  }

  const moviehash = typeof payload.moviehash === "string"
    ? payload.moviehash.trim().toLowerCase()
    : "";
  const moviebytesize = Math.trunc(asNumber(payload.moviebytesize));
  const language = typeof payload.language === "string" && payload.language.trim()
    ? payload.language.trim().toLowerCase()
    : "en";

  if (!/^[0-9a-f]{16}$/.test(moviehash)) {
    return reply(400, { error: "invalid_moviehash" });
  }
  if (moviebytesize <= 0) {
    return reply(400, { error: "invalid_moviebytesize" });
  }

  const userAgent = "Orvix v0.7.4-alpha.11";
  const baseUrl = "https://api.opensubtitles.com/api/v1";
  const apiHeaders = {
    "Api-Key": apiKey,
    "User-Agent": userAgent,
    "Accept": "application/json",
  };

  // OpenSubtitles' 2026 guidance is explicit: moviehash + moviebytesize is the
  // exact-file lookup. Do not add undocumented match filters that can turn a
  // valid exact query into an empty response.
  const search = new URL(baseUrl + "/subtitles");
  search.searchParams.set("languages", language);
  search.searchParams.set("moviehash", moviehash);
  search.searchParams.set("moviebytesize", String(moviebytesize));
  search.searchParams.set("order_by", "download_count");
  search.searchParams.set("order_direction", "desc");

  let searchResponse: Response;
  try {
    searchResponse = await fetch(search, {
      method: "GET",
      headers: apiHeaders,
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    console.error("OpenSubtitles exact search network error", error);
    return reply(502, { error: "opensubtitles_search_unavailable" });
  }

  if (searchResponse.status === 401 || searchResponse.status === 403) {
    console.error("OpenSubtitles rejected API key", searchResponse.status, await searchResponse.text());
    return reply(503, { error: "opensubtitles_bad_api_key" });
  }
  if (searchResponse.status === 429) {
    return reply(429, { error: "opensubtitles_rate_limited" });
  }
  if (!searchResponse.ok) {
    console.error("OpenSubtitles exact search failed", searchResponse.status, await searchResponse.text());
    return reply(502, { error: "opensubtitles_search_failed" });
  }

  const searchJson = await searchResponse.json();
  const data = Array.isArray(searchJson?.data) ? searchJson.data : [];
  const ranked: Array<{
    attrs: Record<string, unknown>;
    file: Record<string, unknown>;
    score: number;
  }> = [];

  for (const row of data) {
    const attrs = row?.attributes;
    if (!attrs || typeof attrs !== "object") continue;
    const files = Array.isArray(attrs.files) ? attrs.files : [];
    for (const file of files) {
      if (!file || typeof file !== "object") continue;
      const fileId = Math.trunc(asNumber(file.file_id));
      if (fileId <= 0) continue;
      ranked.push({
        attrs: attrs as Record<string, unknown>,
        file: file as Record<string, unknown>,
        score: candidateScore(attrs as Record<string, unknown>),
      });
    }
  }

  ranked.sort((a, b) => b.score - a.score);
  const best = ranked[0];
  if (!best) {
    return reply(404, {
      error: "no_exact_hash_match",
      exact_query: true,
      moviehash_match: false,
    });
  }

  const fileId = Math.trunc(asNumber(best.file.file_id));

  // The current REST API expects file_id as a query parameter on POST /download.
  const download = new URL(baseUrl + "/download");
  download.searchParams.set("file_id", String(fileId));

  let downloadResponse: Response;
  try {
    downloadResponse = await fetch(download, {
      method: "POST",
      headers: apiHeaders,
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    console.error("OpenSubtitles download-link network error", error);
    return reply(502, { error: "opensubtitles_download_unavailable" });
  }

  if (downloadResponse.status === 401 || downloadResponse.status === 403) {
    console.error("OpenSubtitles download rejected", downloadResponse.status, await downloadResponse.text());
    return reply(503, { error: "opensubtitles_download_rejected" });
  }
  if (downloadResponse.status === 429) {
    return reply(429, { error: "opensubtitles_rate_limited" });
  }
  if (!downloadResponse.ok) {
    console.error("OpenSubtitles download-link failed", downloadResponse.status, await downloadResponse.text());
    return reply(502, { error: "opensubtitles_download_failed" });
  }

  const downloadJson = await downloadResponse.json();
  const link = typeof downloadJson?.link === "string" ? downloadJson.link.trim() : "";
  if (!/^https:\/\//i.test(link)) {
    return reply(502, { error: "opensubtitles_download_link_missing" });
  }

  let subtitleResponse: Response;
  try {
    subtitleResponse = await fetch(link, {
      method: "GET",
      headers: { "User-Agent": userAgent },
      signal: AbortSignal.timeout(20000),
    });
  } catch (error) {
    console.error("OpenSubtitles subtitle fetch network error", error);
    return reply(502, { error: "subtitle_fetch_unavailable" });
  }

  if (!subtitleResponse.ok) {
    return reply(502, { error: "subtitle_fetch_failed" });
  }

  const lengthHeader = subtitleResponse.headers.get("content-length");
  const contentLength = lengthHeader ? Math.trunc(asNumber(lengthHeader)) : 0;
  if (contentLength > 4 * 1024 * 1024) {
    return reply(413, { error: "subtitle_too_large" });
  }

  const bytes = new Uint8Array(await subtitleResponse.arrayBuffer());
  if (bytes.byteLength === 0 || bytes.byteLength > 4 * 1024 * 1024) {
    return reply(502, { error: "subtitle_payload_invalid" });
  }

  const subtitle = new TextDecoder("utf-8", { fatal: false }).decode(bytes).trim();
  if (!subtitle) return reply(502, { error: "subtitle_payload_empty" });

  // A successful result came from an exact moviehash + moviebytesize query.
  // The public response keeps moviehash_match=true for the Orvix client contract.
  return reply(200, {
    exact_query: true,
    moviehash_match: true,
    match: "moviehash+moviebytesize",
    provider: "OpenSubtitles REST v1",
    subtitle,
    file_id: fileId,
    file_name: typeof best.file.file_name === "string" ? best.file.file_name : null,
    release: typeof best.attrs.release === "string" ? best.attrs.release : null,
    ratings: asNumber(best.attrs.ratings),
    download_count: asNumber(best.attrs.download_count) + asNumber(best.attrs.new_download_count),
    candidates: ranked.length,
  });
});
