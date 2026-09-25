import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const jsonHeaders = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

type Cue = {
  start_ms: number;
  end_ms: number;
  english: string;
  sinhala: string;
};

function cleanCue(value: unknown, durationMs: number): Cue | null {
  if (value == null || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const start = Number(raw.start_ms);
  const end = Number(raw.end_ms);
  const english = typeof raw.english === "string" ? raw.english.trim() : "";
  const sinhala = typeof raw.sinhala === "string" ? raw.sinhala.trim() : "";
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (!english || !sinhala) return null;

  const boundedStart = Math.max(0, Math.min(durationMs, Math.round(start)));
  const boundedEnd = Math.max(
    boundedStart + 120,
    Math.min(durationMs, Math.round(end)),
  );
  if (boundedStart >= durationMs || boundedEnd <= boundedStart) return null;

  // Ordinary dialogue should contain Sinhala script after translation.
  const englishWords = english.match(/[A-Za-z][A-Za-z'’-]*/g) ?? [];
  if (englishWords.length >= 3 && !/[\u0D80-\u0DFF]/u.test(sinhala)) {
    return null;
  }

  return {
    start_ms: boundedStart,
    end_ms: boundedEnd,
    english,
    sinhala,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return reply(405, { error: "method_not_allowed" });
  }

  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    return reply(503, { error: "ai_not_configured" });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch (_) {
    return reply(400, { error: "invalid_json" });
  }

  const title = typeof payload.title === "string"
    ? payload.title.trim().slice(0, 300)
    : "";
  const mimeType = typeof payload.mime_type === "string"
    ? payload.mime_type.trim()
    : "audio/wav";
  const audio = typeof payload.audio_base64 === "string"
    ? payload.audio_base64.trim()
    : "";
  const durationMs = Number(payload.duration_ms);

  if (
    !audio ||
    audio.length > 1_250_000 ||
    !Number.isFinite(durationMs) ||
    durationMs < 1_000 ||
    durationMs > 30_000
  ) {
    return reply(400, { error: "invalid_audio_window" });
  }
  if (!/^audio\/(wav|x-wav|mpeg|mp3|aac|ogg|flac|mp4)$/i.test(mimeType)) {
    return reply(400, { error: "unsupported_audio_type" });
  }

  const prompt = `You create timed Sinhala subtitles for Orvix.

Listen to the attached short movie/TV audio window. Detect only clearly spoken ENGLISH dialogue. For each spoken subtitle-sized phrase, return:
- start_ms: when that phrase begins, relative to the START OF THIS AUDIO WINDOW.
- end_ms: when that phrase ends, relative to the START OF THIS AUDIO WINDOW.
- english: concise verbatim English dialogue.
- sinhala: natural concise Sri Lankan Sinhala translation in Sinhala Unicode.

Rules:
- Timestamps MUST stay between 0 and ${Math.round(durationMs)} ms.
- Timing accuracy is critical: start_ms should be the first clearly audible phoneme of the phrase and end_ms the last clearly audible phoneme, rounded to about 100 ms.
- Never shift a phrase toward the start or end of the clip merely because the clip begins/ends nearby.
- Keep natural subtitle-sized phrases; do not create word-by-word entries.
- Preserve dialogue order exactly and keep one spoken phrase per cue.
- Preserve names, emotion, slang, jokes and profanity level.
- Do not invent dialogue during silence, music, effects, breaths or unclear speech.
- If speech is uncertain, omit it instead of guessing.
- Avoid duplicated overlapping phrases.
- Use Sinhala script for ordinary translated dialogue.
- Return an empty JSON array if there is no clear English dialogue.
- Return JSON only.

TITLE: ${title || "Unknown"}`;

  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=${encodeURIComponent(apiKey)}`;

  const requestBody = {
    contents: [{
      role: "user",
      parts: [
        { text: prompt },
        {
          inlineData: {
            mimeType,
            data: audio,
          },
        },
      ],
    }],
    generationConfig: {
      maxOutputTokens: 8192,
      thinkingConfig: { thinkingLevel: "minimal" },
      responseMimeType: "application/json",
      responseSchema: {
        type: "ARRAY",
        items: {
          type: "OBJECT",
          properties: {
            start_ms: { type: "INTEGER" },
            end_ms: { type: "INTEGER" },
            english: { type: "STRING" },
            sinhala: { type: "STRING" },
          },
          required: ["start_ms", "end_ms", "english", "sinhala"],
        },
      },
    },
  };

  const delays = [0, 700, 1600];
  const retryable = new Set([429, 500, 502, 503, 504]);
  let response: Response | null = null;
  let detail = "";

  for (let attempt = 0; attempt < delays.length; attempt++) {
    if (delays[attempt] > 0) {
      await new Promise((resolve) => setTimeout(resolve, delays[attempt]));
    }
    try {
      response = await fetch(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(requestBody),
      });
    } catch (error) {
      detail = error instanceof Error ? error.message : String(error);
      if (attempt + 1 < delays.length) continue;
      return reply(503, { error: "stt_network_error" });
    }

    if (response.ok) break;
    detail = await response.text();
    if (!retryable.has(response.status) || attempt + 1 >= delays.length) {
      console.error("Gemini audio STT failed", response.status, detail);
      return reply(response.status === 429 ? 429 : 502, {
        error: response.status === 429 ? "rate_limited" : "stt_failed",
      });
    }
  }

  if (response == null || !response.ok) {
    return reply(503, { error: "stt_unavailable" });
  }

  try {
    const data = await response.json();
    const rawText = data?.candidates?.[0]?.content?.parts
      ?.map((part: { text?: string }) => part?.text ?? "")
      .join("")
      .trim();
    if (!rawText) return reply(200, { cues: [] });

    const parsed = JSON.parse(rawText);
    if (!Array.isArray(parsed)) {
      return reply(502, { error: "invalid_stt_json" });
    }

    const cues = parsed
      .map((entry) => cleanCue(entry, Math.round(durationMs)))
      .filter((entry): entry is Cue => entry != null)
      .sort((a, b) => a.start_ms - b.start_ms)
      .slice(0, 80);

    return reply(200, {
      cues,
      model: "gemini-3.1-flash-lite",
    });
  } catch (error) {
    console.error("Audio STT parse error", error);
    return reply(502, { error: "invalid_stt_response" });
  }
});
