import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
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

  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const cleanContext = (Array.isArray(payload.context) ? payload.context : [])
    .filter((value): value is string => typeof value === "string")
    .map((value) => value.trim())
    .filter(Boolean)
    .slice(-6)
    .join("\n");

  if (!text || text.length > 1200) return reply(400, { error: "invalid_text" });

  const prompt = `You are the Sinhala subtitle translator for Orvix, a movie and TV player used in Sri Lanka.\n\nTranslate ONLY the CURRENT SUBTITLE into natural, concise Sri Lankan Sinhala suitable for on-screen subtitles.\n\nRules:\n- Preserve meaning, emotion, slang, jokes, profanity level, and character tone.\n- Prefer natural spoken Sinhala over literal or formal textbook Sinhala.\n- Do not translate proper names unless Sinhala audiences normally do so.\n- Keep the result short enough to read comfortably on screen.\n- Preserve useful line breaks when the subtitle has multiple lines.\n- Do not add explanations, labels, quotation marks, romanization, or notes.\n- Return only the Sinhala subtitle text.\n\nTITLE: ${title || "Unknown"}\nPREVIOUS DIALOGUE FOR CONTEXT:\n${cleanContext || "(none)"}\n\nCURRENT SUBTITLE:\n${text}`;

  try {
    const gemini = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=${encodeURIComponent(apiKey)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: { temperature: 0.2, topP: 0.9, maxOutputTokens: 180 },
        }),
      },
    );

    if (!gemini.ok) {
      const detail = await gemini.text();
      console.error("Gemini subtitle translation failed", gemini.status, detail);
      return reply(gemini.status === 429 ? 429 : 502, {
        error: gemini.status === 429 ? "rate_limited" : "translation_failed",
      });
    }

    const data = await gemini.json();
    const translated = data?.candidates?.[0]?.content?.parts
      ?.map((part: { text?: string }) => part?.text ?? "")
      .join("")
      .trim();

    if (!translated) return reply(502, { error: "empty_translation" });
    return reply(200, { translation: translated });
  } catch (error) {
    console.error("AI subtitle function error", error);
    return reply(502, { error: "translation_unavailable" });
  }
});
