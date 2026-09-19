import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function likelySinhala(source: string, translation: string): boolean {
  const output = translation.trim();
  if (!output) return false;
  const sourceWords = source.match(/[A-Za-z][A-Za-z'’-]*/g) ?? [];
  if (sourceWords.length < 3) return true;
  return /[\u0D80-\u0DFF]/u.test(output);
}

async function callGemini(
  apiKey: string,
  prompt: string,
  batch: boolean,
): Promise<{ ok: true; text: string } | { ok: false; status: number; detail: string }> {
  const generationConfig: Record<string, unknown> = {
    temperature: 0.15,
    topP: 0.9,
    maxOutputTokens: batch ? 8192 : 220,
  };
  if (batch) {
    generationConfig.responseMimeType = "application/json";
    generationConfig.responseSchema = {
      type: "ARRAY",
      items: { type: "STRING" },
    };
  }

  const gemini = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=${encodeURIComponent(apiKey)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig,
      }),
    },
  );

  if (!gemini.ok) {
    return { ok: false, status: gemini.status, detail: await gemini.text() };
  }
  const data = await gemini.json();
  const text = data?.candidates?.[0]?.content?.parts
    ?.map((part: { text?: string }) => part?.text ?? "")
    .join("")
    .trim();
  if (!text) return { ok: false, status: 502, detail: "empty_translation" };
  return { ok: true, text };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    return reply(503, {
      error: "ai_not_configured",
      message: "Orvix AI subtitles are not configured yet.",
    });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch (_) {
    return reply(400, { error: "invalid_json" });
  }

  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const rawSegments = Array.isArray(payload.segments) ? payload.segments : null;

  try {
    if (rawSegments != null) {
      const segments = rawSegments
        .filter((value): value is string => typeof value === "string")
        .map((value) => value.trim());
      if (segments.length === 0 || segments.length !== rawSegments.length || segments.length > 80) {
        return reply(400, { error: "invalid_segments" });
      }
      if (segments.some((value) => value.length > 1200)) {
        return reply(400, { error: "segment_too_large" });
      }
      const totalChars = segments.reduce((sum, value) => sum + value.length, 0);
      if (totalChars > 32000) return reply(400, { error: "batch_too_large" });

      const prompt = `You are the Sinhala subtitle translator for Orvix, a movie and TV player used in Sri Lanka.\n\nTranslate every subtitle cue in the JSON array below into natural, concise Sri Lankan Sinhala suitable for on-screen subtitles.\n\nRules:\n- Return a JSON array of strings with EXACTLY the same number of entries and in the same order.\n- Preserve meaning, emotion, slang, jokes, profanity level, and character tone.\n- Prefer natural spoken Sinhala over literal or formal textbook Sinhala.\n- Do not translate proper names unless Sinhala audiences normally do so.\n- For ordinary English dialogue, use Sinhala Unicode script for the translated words. Never return an English sentence unchanged. Latin letters are allowed only for proper names/acronyms that should stay untranslated.\n- Keep each result concise enough for subtitles.\n- Preserve useful line breaks inside each cue where possible.\n- Do not add explanations, labels, romanization, notes, or extra entries.\n- Use neighboring cues as dialogue context so pronouns and tone remain coherent.\n\nTITLE: ${title || "Unknown"}\nSUBTITLE CUES JSON:\n${JSON.stringify(segments)}`;

      const result = await callGemini(apiKey, prompt, true);
      if (!result.ok) {
        console.error("Gemini batch subtitle translation failed", result.status, result.detail);
        return reply(result.status === 429 ? 429 : 502, {
          error: result.status === 429 ? "rate_limited" : "translation_failed",
        });
      }

      let translations: unknown;
      try {
        translations = JSON.parse(result.text);
      } catch (_) {
        console.error("Gemini batch response was not JSON", result.text);
        return reply(502, { error: "invalid_translation_json" });
      }
      if (!Array.isArray(translations) ||
          translations.length !== segments.length ||
          translations.some((value) => typeof value !== "string")) {
        return reply(502, { error: "translation_count_mismatch" });
      }
      const cleaned = translations.map((value) => (value as string).trim());
      if (cleaned.some((value, index) => !likelySinhala(segments[index], value))) {
        return reply(502, { error: "non_sinhala_translation" });
      }
      return reply(200, { translations: cleaned });
    }

    const text = typeof payload.text === "string" ? payload.text.trim() : "";
    const cleanContext = (Array.isArray(payload.context) ? payload.context : [])
      .filter((value): value is string => typeof value === "string")
      .map((value) => value.trim())
      .filter(Boolean)
      .slice(-6)
      .join("\n");

    if (!text || text.length > 1200) return reply(400, { error: "invalid_text" });

    const prompt = `You are the Sinhala subtitle translator for Orvix, a movie and TV player used in Sri Lanka.\n\nTranslate ONLY the CURRENT SUBTITLE into natural, concise Sri Lankan Sinhala suitable for on-screen subtitles.\n\nRules:\n- Preserve meaning, emotion, slang, jokes, profanity level, and character tone.\n- Prefer natural spoken Sinhala over literal or formal textbook Sinhala.\n- Do not translate proper names unless Sinhala audiences normally do so.\n- For ordinary English dialogue, use Sinhala Unicode script. Never return the English sentence unchanged. Latin letters are allowed only for proper names/acronyms that should stay untranslated.\n- Keep the result short enough to read comfortably on screen.\n- Preserve useful line breaks when the subtitle has multiple lines.\n- Do not add explanations, labels, quotation marks, romanization, or notes.\n- Return only the Sinhala subtitle text.\n\nTITLE: ${title || "Unknown"}\nPREVIOUS DIALOGUE FOR CONTEXT:\n${cleanContext || "(none)"}\n\nCURRENT SUBTITLE:\n${text}`;

    const result = await callGemini(apiKey, prompt, false);
    if (!result.ok) {
      console.error("Gemini subtitle translation failed", result.status, result.detail);
      return reply(result.status === 429 ? 429 : 502, {
        error: result.status === 429 ? "rate_limited" : "translation_failed",
      });
    }
    if (!likelySinhala(text, result.text)) {
      return reply(502, { error: "non_sinhala_translation" });
    }
    return reply(200, { translation: result.text.trim() });
  } catch (error) {
    console.error("AI subtitle function error", error);
    return reply(502, { error: "translation_unavailable" });
  }
});
