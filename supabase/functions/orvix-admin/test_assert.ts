// Minimal assertions so the tests run with `deno test --no-remote`.
export function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

export function assert(condition: unknown, message = "assertion failed") {
  if (!condition) throw new Error(message);
}
