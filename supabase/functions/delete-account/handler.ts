// Request handling for the delete-account Edge Function (see README.md).
// Supabase access is injected so the rules here can be tested without a
// project; index.ts wires in the real clients.

/** How recently the caller's session must have confirmed the password. */
export const PASSWORD_CONFIRMATION_MAX_AGE_SECONDS = 10 * 60;

/** Allowed clock difference for a confirmation time slightly in the future. */
const CLOCK_SKEW_SECONDS = 60;

export type CallerLookup =
  | { kind: "user"; id: string }
  | { kind: "invalid" }
  | { kind: "not_found" };

export interface DeleteAccountDeps {
  /** Validates the access token with Supabase Auth. Throws when Auth cannot be reached. */
  lookupCaller(accessToken: string): Promise<CallerLookup>;
  /** Removes the user's Orvix cloud rows (public.delete_orvix_account_data). */
  deleteAccountData(userId: string): Promise<void>;
  /** Permanently deletes the Auth user; "not_found" when it is already gone. */
  deleteAuthUser(userId: string): Promise<"deleted" | "not_found">;
  nowSeconds(): number;
  /** Receives fixed messages only, never tokens, ids or request data. */
  log(message: string): void;
}

const reply = (status: number, body: Record<string, unknown>) =>
  Response.json(body, { status, headers: { "cache-control": "no-store" } });

export function bearerToken(req: Request): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec((req.headers.get("authorization") ?? "").trim());
  return match ? match[1] : null;
}

/** The claims of an access token that Supabase Auth has already validated. */
export function tokenClaims(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    const claims = JSON.parse(new TextDecoder().decode(bytes));
    return claims && typeof claims === "object" && !Array.isArray(claims) ? claims : null;
  } catch {
    return null;
  }
}

/** When the token's session last confirmed the password (its "amr" claim). */
export function passwordConfirmedAt(claims: Record<string, unknown>): number | null {
  const amr = claims.amr;
  if (!Array.isArray(amr)) return null;
  let latest: number | null = null;
  for (const entry of amr) {
    if (
      entry && typeof entry === "object" &&
      (entry as Record<string, unknown>).method === "password"
    ) {
      const timestamp = (entry as Record<string, unknown>).timestamp;
      if (typeof timestamp === "number" && (latest === null || timestamp > latest)) {
        latest = timestamp;
      }
    }
  }
  return latest;
}

/**
 * Deletes the account of the access token's user, and only that account.
 * The request body is never read, so a client cannot name another account.
 */
export async function handleDeleteAccount(
  req: Request,
  deps: DeleteAccountDeps,
): Promise<Response> {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  const token = bearerToken(req);
  if (!token) return reply(401, { error: "not_authenticated" });

  let caller: CallerLookup;
  try {
    caller = await deps.lookupCaller(token);
  } catch {
    deps.log("delete-account: Supabase Auth could not be reached");
    return reply(503, { error: "auth_unavailable" });
  }
  // A retry after a deletion whose response was lost.
  if (caller.kind === "not_found") return reply(410, { error: "account_not_found" });
  if (caller.kind !== "user") return reply(401, { error: "not_authenticated" });

  const claims = tokenClaims(token);
  if (!claims || claims.sub !== caller.id) return reply(401, { error: "not_authenticated" });

  // Deleting needs a session that confirmed the password moments ago; an old
  // or refreshed session, or one that never used a password, is not enough.
  const confirmedAt = passwordConfirmedAt(claims);
  const now = deps.nowSeconds();
  if (
    confirmedAt === null ||
    now - confirmedAt > PASSWORD_CONFIRMATION_MAX_AGE_SECONDS ||
    confirmedAt - now > CLOCK_SKEW_SECONDS
  ) {
    return reply(401, { error: "reauthentication_required" });
  }

  try {
    await deps.deleteAccountData(caller.id);
  } catch {
    deps.log("delete-account: cloud data cleanup failed");
    return reply(500, { error: "cleanup_failed" });
  }

  try {
    await deps.deleteAuthUser(caller.id);
  } catch {
    deps.log("delete-account: Auth user deletion failed");
    return reply(500, { error: "delete_failed" });
  }

  return reply(200, { deleted: true });
}
