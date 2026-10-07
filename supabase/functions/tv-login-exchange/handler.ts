// Request handling for the tv-login-exchange Edge Function (see README.md).
// Supabase access is injected so the rules here can be tested without a
// project; index.ts wires in the real clients.

export type ExchangeLease =
  | { state: "leased"; userId: string; exchangeToken: string }
  | { state: "busy" }
  | { state: "unavailable" };

export interface CreatedSession {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
}

export interface TvLoginExchangeDeps {
  /** public.begin_tv_login_exchange. Throws when the database fails. */
  beginExchange(deviceCode: string, deviceNonce: string): Promise<ExchangeLease>;
  /** Creates a session for the user; "user_unavailable" when it cannot. Throws on failure. */
  createSession(userId: string): Promise<CreatedSession | "user_unavailable">;
  /** public.complete_tv_login_exchange. Throws when the database fails. */
  completeExchange(deviceCode: string, exchangeToken: string): Promise<boolean>;
  /** public.release_tv_login_exchange. Throws when the database fails. */
  releaseExchange(deviceCode: string, exchangeToken: string): Promise<void>;
  /** Signs out a session created by a lease that could not be completed. */
  revokeSession(accessToken: string): Promise<void>;
  /** Receives fixed messages only, never codes, tokens, ids or request data. */
  log(message: string): void;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const reply = (status: number, body: Record<string, unknown>) =>
  Response.json(body, { status, headers: { "cache-control": "no-store" } });

async function quietly(deps: TvLoginExchangeDeps, message: string, action: () => Promise<unknown>) {
  try {
    await action();
  } catch {
    deps.log(message);
  }
}

/**
 * Exchanges an approved TV login for a session, at most once.
 *
 * The login is leased first, the session is created, and only then is the
 * login marked used. A failure in between releases the lease so the TV can
 * retry; a lease that cannot be completed revokes the session it created.
 */
export async function handleTvLoginExchange(
  req: Request,
  deps: TvLoginExchangeDeps,
): Promise<Response> {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "invalid_request" });
  }
  const fields = body && typeof body === "object" ? body as Record<string, unknown> : {};
  const deviceCode = typeof fields.device_code === "string" ? fields.device_code.trim() : "";
  const deviceNonce = typeof fields.device_nonce === "string" ? fields.device_nonce.trim() : "";
  if (!UUID.test(deviceCode) || !UUID.test(deviceNonce)) {
    return reply(400, { error: "invalid_request" });
  }

  let lease: ExchangeLease;
  try {
    lease = await deps.beginExchange(deviceCode, deviceNonce);
  } catch {
    deps.log("tv-login-exchange: could not lease the login");
    return reply(503, { error: "temporarily_unavailable" });
  }
  if (lease.state === "busy") return reply(409, { error: "exchange_in_progress" });
  if (lease.state !== "leased") return reply(409, { error: "not_approved_or_expired" });

  let session: CreatedSession | "user_unavailable";
  try {
    session = await deps.createSession(lease.userId);
  } catch {
    deps.log("tv-login-exchange: session creation failed");
    await quietly(deps, "tv-login-exchange: could not release the lease", () =>
      deps.releaseExchange(deviceCode, lease.exchangeToken));
    return reply(503, { error: "session_generation_failed" });
  }
  if (session === "user_unavailable") {
    await quietly(deps, "tv-login-exchange: could not release the lease", () =>
      deps.releaseExchange(deviceCode, lease.exchangeToken));
    return reply(409, { error: "not_approved_or_expired" });
  }

  let completed: boolean;
  try {
    completed = await deps.completeExchange(deviceCode, lease.exchangeToken);
  } catch {
    deps.log("tv-login-exchange: could not complete the exchange");
    await quietly(deps, "tv-login-exchange: could not revoke the session", () =>
      deps.revokeSession(session.access_token));
    await quietly(deps, "tv-login-exchange: could not release the lease", () =>
      deps.releaseExchange(deviceCode, lease.exchangeToken));
    return reply(503, { error: "temporarily_unavailable" });
  }
  if (!completed) {
    // The lease ran out and another exchange took over, or the login ended.
    await quietly(deps, "tv-login-exchange: could not revoke the session", () =>
      deps.revokeSession(session.access_token));
    return reply(409, { error: "not_approved_or_expired" });
  }

  return reply(200, {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    token_type: session.token_type,
    expires_in: session.expires_in,
  });
}
