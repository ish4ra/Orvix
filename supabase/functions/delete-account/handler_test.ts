// deno test supabase/functions/delete-account/handler_test.ts
import {
  type CallerLookup,
  type DeleteAccountDeps,
  handleDeleteAccount,
  PASSWORD_CONFIRMATION_MAX_AGE_SECONDS,
} from "./handler.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

const NOW = 1_800_000_000;
const CALLER = "00000000-0000-4000-8000-00000000000a";
const OTHER = "00000000-0000-4000-8000-00000000000b";

const base64url = (value: unknown) =>
  btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function token(claims: Record<string, unknown>): string {
  return `${base64url({ alg: "HS256", typ: "JWT" })}.${base64url(claims)}.signature`;
}

const freshToken = token({
  sub: CALLER,
  role: "authenticated",
  amr: [{ method: "password", timestamp: NOW - 5 }],
});

class FakeDeps implements DeleteAccountDeps {
  calls: string[] = [];
  logs: string[] = [];
  caller: CallerLookup | Error = { kind: "user", id: CALLER };
  cleanupError: Error | null = null;
  deleteResult: "deleted" | "not_found" | Error = "deleted";

  lookupCaller(accessToken: string): Promise<CallerLookup> {
    this.calls.push(`lookup:${accessToken === freshToken ? "fresh" : "other"}`);
    return this.caller instanceof Error ? Promise.reject(this.caller) : Promise.resolve(this.caller);
  }
  deleteAccountData(userId: string): Promise<void> {
    this.calls.push(`cleanup:${userId}`);
    return this.cleanupError ? Promise.reject(this.cleanupError) : Promise.resolve();
  }
  deleteAuthUser(userId: string): Promise<"deleted" | "not_found"> {
    this.calls.push(`deleteUser:${userId}`);
    return this.deleteResult instanceof Error
      ? Promise.reject(this.deleteResult)
      : Promise.resolve(this.deleteResult);
  }
  nowSeconds() {
    return NOW;
  }
  log(message: string) {
    this.logs.push(message);
  }
}

function request(
  init: { method?: string; authorization?: string | null; body?: unknown } = {},
): Request {
  const headers = new Headers({ "content-type": "application/json" });
  const authorization = init.authorization === undefined ? `Bearer ${freshToken}` : init.authorization;
  if (authorization !== null) headers.set("authorization", authorization);
  return new Request("https://example.test/functions/v1/delete-account", {
    method: init.method ?? "POST",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}

async function call(deps: FakeDeps, req = request()) {
  const response = await handleDeleteAccount(req, deps);
  const text = await response.text();
  return { status: response.status, text, body: JSON.parse(text) };
}

Deno.test("deletes the caller's data, then the caller", async () => {
  const deps = new FakeDeps();
  const result = await call(deps);
  assertEquals(result.status, 200);
  assertEquals(result.body, { deleted: true });
  assertEquals(deps.calls, ["lookup:fresh", `cleanup:${CALLER}`, `deleteUser:${CALLER}`]);
  assertEquals(deps.logs, []);
});

Deno.test("a missing Authorization header is rejected", async () => {
  for (const authorization of [null, "", "Basic abc", "Bearer"]) {
    const deps = new FakeDeps();
    const result = await call(deps, request({ authorization }));
    assertEquals(result.status, 401, String(authorization));
    assertEquals(result.body, { error: "not_authenticated" });
    assertEquals(deps.calls, []);
  }
});

Deno.test("an invalid token is rejected without deleting anything", async () => {
  const deps = new FakeDeps();
  deps.caller = { kind: "invalid" };
  const result = await call(deps);
  assertEquals(result.status, 401);
  assertEquals(result.body, { error: "not_authenticated" });
  assertEquals(deps.calls, ["lookup:fresh"]);
});

Deno.test("a token whose subject is not the verified user is rejected", async () => {
  const deps = new FakeDeps();
  deps.caller = { kind: "user", id: OTHER };
  const result = await call(deps);
  assertEquals(result.status, 401);
  assertEquals(deps.calls, ["lookup:fresh"]);
});

Deno.test("a user id in the request body is ignored", async () => {
  for (const body of [{ user_id: OTHER }, { userId: OTHER, id: OTHER }, [OTHER]]) {
    const deps = new FakeDeps();
    const result = await call(deps, request({ body }));
    assertEquals(result.status, 200);
    assertEquals(deps.calls, ["lookup:fresh", `cleanup:${CALLER}`, `deleteUser:${CALLER}`]);
    if (deps.calls.some((c) => c.includes(OTHER))) throw new Error("another user was targeted");
  }
});

Deno.test("only POST is accepted", async () => {
  for (const method of ["GET", "DELETE", "PUT"]) {
    const deps = new FakeDeps();
    const result = await call(deps, request({ method }));
    assertEquals(result.status, 405, method);
    assertEquals(deps.calls, []);
  }
});

Deno.test("a session without a recent password confirmation is refused", async () => {
  const tokens = {
    "no amr": token({ sub: CALLER }),
    "otp only": token({ sub: CALLER, amr: [{ method: "otp", timestamp: NOW - 5 }] }),
    "old password": token({
      sub: CALLER,
      amr: [{ method: "password", timestamp: NOW - PASSWORD_CONFIRMATION_MAX_AGE_SECONDS - 1 }],
    }),
    "future password": token({ sub: CALLER, amr: [{ method: "password", timestamp: NOW + 3600 }] }),
    "malformed": "not-a-jwt",
  };
  for (const [name, value] of Object.entries(tokens)) {
    const deps = new FakeDeps();
    const result = await call(deps, request({ authorization: `Bearer ${value}` }));
    assertEquals(result.status, 401, name);
    assertEquals(
      result.body,
      { error: name === "malformed" ? "not_authenticated" : "reauthentication_required" },
      name,
    );
    assertEquals(deps.calls.filter((c) => !c.startsWith("lookup")), [], name);
  }
});

Deno.test("an already deleted caller gets account_not_found", async () => {
  const deps = new FakeDeps();
  deps.caller = { kind: "not_found" };
  const result = await call(deps);
  assertEquals(result.status, 410);
  assertEquals(result.body, { error: "account_not_found" });
  assertEquals(deps.calls, ["lookup:fresh"]);
});

Deno.test("Auth being unreachable fails before deleting anything", async () => {
  const deps = new FakeDeps();
  deps.caller = new Error(`network failure for ${freshToken}`);
  const result = await call(deps);
  assertEquals(result.status, 503);
  assertEquals(result.body, { error: "auth_unavailable" });
  assertEquals(deps.calls, ["lookup:fresh"]);
});

Deno.test("a cleanup failure keeps the Auth user", async () => {
  const deps = new FakeDeps();
  deps.cleanupError = new Error(`permission denied for ${CALLER}`);
  const result = await call(deps);
  assertEquals(result.status, 500);
  assertEquals(result.body, { error: "cleanup_failed" });
  assertEquals(deps.calls, ["lookup:fresh", `cleanup:${CALLER}`]);
});

Deno.test("an Auth deletion failure is reported", async () => {
  const deps = new FakeDeps();
  deps.deleteResult = new Error(`Database error deleting user ${CALLER}`);
  const result = await call(deps);
  assertEquals(result.status, 500);
  assertEquals(result.body, { error: "delete_failed" });
});

Deno.test("a user removed between the checks still counts as deleted", async () => {
  const deps = new FakeDeps();
  deps.deleteResult = "not_found";
  const result = await call(deps);
  assertEquals(result.status, 200);
  assertEquals(result.body, { deleted: true });
});

Deno.test("responses and logs never carry tokens, ids or error details", async () => {
  const scenarios: Array<(deps: FakeDeps) => void> = [
    () => {},
    (d) => (d.caller = new Error(`boom ${freshToken}`)),
    (d) => (d.cleanupError = new Error(`boom ${CALLER} encrypted-payload`)),
    (d) => (d.deleteResult = new Error(`boom ${CALLER}`)),
  ];
  for (const scenario of scenarios) {
    const deps = new FakeDeps();
    scenario(deps);
    const result = await call(deps, request({ body: { password: "hunter2" } }));
    const visible = result.text + deps.logs.join("\n");
    for (const secret of [freshToken, CALLER, "hunter2", "encrypted-payload", "boom"]) {
      if (visible.includes(secret)) throw new Error(`leaked ${secret}`);
    }
  }
});
