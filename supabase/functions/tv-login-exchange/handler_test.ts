// deno test supabase/functions/tv-login-exchange/handler_test.ts
import {
  type CreatedSession,
  type ExchangeLease,
  handleTvLoginExchange,
  type TvLoginExchangeDeps,
} from "./handler.ts";

function assertEquals(actual: unknown, expected: unknown, message = "") {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${message} expected ${e}, got ${a}`);
}

const DEVICE = "11111111-1111-4111-8111-111111111111";
const NONCE = "22222222-2222-4222-8222-222222222222";
const USER = "00000000-0000-4000-8000-00000000000a";
const LEASE = "33333333-3333-4333-8333-333333333333";

const SESSION: CreatedSession = {
  access_token: "access",
  refresh_token: "refresh",
  token_type: "bearer",
  expires_in: 3600,
};

/**
 * A fake of the database lease state: one approved login that can be leased,
 * released, completed once, and expires.
 */
class FakeDeps implements TvLoginExchangeDeps {
  calls: string[] = [];
  logs: string[] = [];
  status: "approved" | "consumed" | "expired" = "approved";
  leasedBy: string | null = null;
  leaseCount = 0;
  beginError = false;
  sessionResult: CreatedSession | "user_unavailable" | Error = SESSION;
  completeError = false;
  /** Simulates the lease expiring and being taken over before completion. */
  loseLeaseBeforeComplete = false;

  beginExchange(deviceCode: string, deviceNonce: string): Promise<ExchangeLease> {
    this.calls.push("begin");
    if (this.beginError) return Promise.reject(new Error("db"));
    if (deviceCode !== DEVICE || deviceNonce !== NONCE || this.status !== "approved") {
      return Promise.resolve({ state: "unavailable" });
    }
    if (this.leasedBy) return Promise.resolve({ state: "busy" });
    this.leaseCount++;
    this.leasedBy = `${LEASE.slice(0, -1)}${this.leaseCount}`;
    return Promise.resolve({ state: "leased", userId: USER, exchangeToken: this.leasedBy });
  }
  createSession(userId: string) {
    this.calls.push(`session:${userId === USER ? "user" : "other"}`);
    return this.sessionResult instanceof Error
      ? Promise.reject(this.sessionResult)
      : Promise.resolve(this.sessionResult);
  }
  completeExchange(_deviceCode: string, exchangeToken: string) {
    this.calls.push("complete");
    if (this.completeError) return Promise.reject(new Error("db"));
    if (this.loseLeaseBeforeComplete) this.leasedBy = "someone-else";
    if (this.status !== "approved" || this.leasedBy !== exchangeToken) return Promise.resolve(false);
    this.status = "consumed";
    this.leasedBy = null;
    return Promise.resolve(true);
  }
  releaseExchange(_deviceCode: string, exchangeToken: string) {
    this.calls.push("release");
    if (this.leasedBy === exchangeToken) this.leasedBy = null;
    return Promise.resolve();
  }
  revokeSession(accessToken: string) {
    this.calls.push(`revoke:${accessToken}`);
    return Promise.resolve();
  }
  log(message: string) {
    this.logs.push(message);
  }
}

const request = (body: unknown, method = "POST") =>
  new Request("https://example.test/functions/v1/tv-login-exchange", {
    method,
    headers: { "content-type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const exchange = (deps: FakeDeps, body: unknown = { device_code: DEVICE, device_nonce: NONCE }) =>
  handleTvLoginExchange(request(body), deps);

async function expectResponse(response: Response, status: number, body: Record<string, unknown>) {
  assertEquals(response.status, status, "status");
  assertEquals(await response.json(), body, "body");
  assertEquals(response.headers.get("cache-control"), "no-store", "cache-control");
}

Deno.test("an approved login is exchanged for a session once", async () => {
  const deps = new FakeDeps();
  await expectResponse(await exchange(deps), 200, SESSION as unknown as Record<string, unknown>);
  assertEquals(deps.calls, ["begin", "session:user", "complete"]);

  // Replay after success.
  await expectResponse(await exchange(deps), 409, { error: "not_approved_or_expired" });
  assertEquals(deps.calls.filter((c) => c.startsWith("session")).length, 1, "sessions created");
});

Deno.test("a wrong nonce or device code gets nothing", async () => {
  const deps = new FakeDeps();
  await expectResponse(
    await exchange(deps, { device_code: DEVICE, device_nonce: "44444444-4444-4444-8444-444444444444" }),
    409,
    { error: "not_approved_or_expired" },
  );
  assertEquals(deps.calls, ["begin"], "no session for a wrong nonce");
  assertEquals(deps.status, "approved", "a wrong nonce must not consume the login");
});

Deno.test("an expired login cannot be exchanged", async () => {
  const deps = new FakeDeps();
  deps.status = "expired";
  await expectResponse(await exchange(deps), 409, { error: "not_approved_or_expired" });
  assertEquals(deps.calls, ["begin"]);
});

Deno.test("malformed requests are rejected before the database", async () => {
  for (const body of [
    {},
    { device_code: DEVICE },
    { device_code: "ABC123", device_nonce: NONCE },
    { device_code: DEVICE, device_nonce: "x' or 1=1 --" },
    { device_code: 1, device_nonce: 2 },
    null,
  ]) {
    const deps = new FakeDeps();
    await expectResponse(await exchange(deps, body), 400, { error: "invalid_request" });
    assertEquals(deps.calls, [], "database touched for a malformed request");
  }
  const deps = new FakeDeps();
  const response = await handleTvLoginExchange(request(null, "GET"), deps);
  assertEquals(response.status, 405);
});

Deno.test("a temporary session failure keeps the approval for a retry", async () => {
  const deps = new FakeDeps();
  deps.sessionResult = new Error("auth down");
  await expectResponse(await exchange(deps), 503, { error: "session_generation_failed" });
  assertEquals(deps.calls, ["begin", "session:user", "release"]);
  assertEquals(deps.status, "approved", "the approval was destroyed");
  assertEquals(deps.leasedBy, null, "the lease was not released");

  deps.sessionResult = SESSION;
  await expectResponse(await exchange(deps), 200, SESSION as unknown as Record<string, unknown>);
  assertEquals(deps.status, "consumed");
});

Deno.test("a concurrent exchange cannot create a second session", async () => {
  const deps = new FakeDeps();
  let releaseFirst!: () => void;
  const gate = new Promise<void>((resolve) => (releaseFirst = resolve));
  const original = deps.createSession.bind(deps);
  deps.createSession = async (userId: string) => {
    await gate;
    return original(userId);
  };

  const first = exchange(deps);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await expectResponse(await exchange(deps), 409, { error: "exchange_in_progress" });
  releaseFirst();
  await expectResponse(await first, 200, SESSION as unknown as Record<string, unknown>);
  assertEquals(deps.calls.filter((c) => c.startsWith("session")).length, 1, "sessions created");
});

Deno.test("a lease taken over before completion revokes its session", async () => {
  const deps = new FakeDeps();
  deps.loseLeaseBeforeComplete = true;
  await expectResponse(await exchange(deps), 409, { error: "not_approved_or_expired" });
  assertEquals(deps.calls, ["begin", "session:user", "complete", "revoke:access"]);
});

Deno.test("a database failure while completing never returns the session", async () => {
  const deps = new FakeDeps();
  deps.completeError = true;
  await expectResponse(await exchange(deps), 503, { error: "temporarily_unavailable" });
  assertEquals(deps.calls, ["begin", "session:user", "complete", "revoke:access", "release"]);
});

Deno.test("a database failure while leasing is retryable", async () => {
  const deps = new FakeDeps();
  deps.beginError = true;
  await expectResponse(await exchange(deps), 503, { error: "temporarily_unavailable" });
});

Deno.test("a deleted or email-less user ends the exchange without a session", async () => {
  const deps = new FakeDeps();
  deps.sessionResult = "user_unavailable";
  await expectResponse(await exchange(deps), 409, { error: "not_approved_or_expired" });
  assertEquals(deps.calls, ["begin", "session:user", "release"]);
});

Deno.test("logs never contain codes, nonces or tokens", async () => {
  const deps = new FakeDeps();
  deps.completeError = true;
  await exchange(deps);
  const deps2 = new FakeDeps();
  deps2.sessionResult = new Error("auth down");
  await exchange(deps2);
  for (const line of [...deps.logs, ...deps2.logs]) {
    for (const secret of [DEVICE, NONCE, USER, "access", "refresh", LEASE.slice(0, 8)]) {
      if (line.includes(secret)) throw new Error(`log leaked a value: ${line}`);
    }
  }
});
