// deno test --allow-read supabase/functions/orvix-telemetry/
import { chooseCountry, shouldRefreshCountry } from "./country.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

Deno.test("session_start always refreshes the country", () => {
  assertEquals(shouldRefreshCountry("session_start", "LK"), true);
  assertEquals(shouldRefreshCountry("session_start", null), true);
});

Deno.test("a known country is kept on later messages", () => {
  for (const type of ["heartbeat", "event", "error", "session_end"]) {
    assertEquals(shouldRefreshCountry(type, "LK"), false, type);
  }
});

Deno.test("a missing country is retried on non-heartbeat messages only", () => {
  for (const type of ["event", "error", "session_end"]) {
    assertEquals(shouldRefreshCountry(type, null), true, type);
    assertEquals(shouldRefreshCountry(type, ""), true, type);
  }
  assertEquals(shouldRefreshCountry("heartbeat", null), false);
  assertEquals(shouldRefreshCountry("heartbeat", undefined), false);
});

Deno.test("a failed lookup preserves the stored country", () => {
  assertEquals(chooseCountry(null, "LK"), "LK");
  assertEquals(chooseCountry("US", "LK"), "US");
  assertEquals(chooseCountry(null, null), null);
  assertEquals(chooseCountry(undefined, undefined), null);
});
