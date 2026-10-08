// deno test --allow-read supabase/functions/orvix-telemetry/redact_test.ts
import { redactProperties, redactText } from "./redact.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

// Shared with test/telemetry_redaction_test.dart (the app's copy of the rules).
const cases: { name: string; input: string; expected: string }[] = JSON.parse(
  await Deno.readTextFile(new URL("./redaction_cases.json", import.meta.url)),
);

for (const c of cases) {
  Deno.test(`redaction: ${c.name}`, () => {
    assertEquals(redactText(c.input), c.expected, c.name);
  });
}

Deno.test("redaction is stable when applied twice", () => {
  for (const c of cases) {
    const once = redactText(c.input);
    assertEquals(redactText(once), once, c.name);
  }
});

Deno.test("event properties: secret keys are dropped, strings redacted", () => {
  assertEquals(
    redactProperties({
      provider_token: "fake-token",
      apiKey: 12345,
      source: "https://addon.example.test/torbox=fakeKey/manifest.json",
      count: 3,
      ok: true,
    }),
    {
      provider_token: "[redacted]",
      apiKey: "[redacted]",
      source: "https://addon.example.test/[redacted]",
      count: 3,
      ok: true,
    },
  );
});
