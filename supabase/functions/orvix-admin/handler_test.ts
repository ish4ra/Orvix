// deno test --allow-read supabase/functions/orvix-admin/
import { type AdminDeps, DASHBOARD_REDIRECT, handleAdminRequest } from "./handler.ts";
import { assertEquals } from "./test_assert.ts";

class FakeDeps implements AdminDeps {
  tokens: string[] = [];
  loads = 0;
  owner: boolean | Error = true;
  dashboard: unknown | Error = { schema_version: 2 };
  logs: string[] = [];

  isOwner(token: string) {
    this.tokens.push(token);
    return this.owner instanceof Error ? Promise.reject(this.owner) : Promise.resolve(this.owner);
  }
  loadDashboard() {
    this.loads++;
    return this.dashboard instanceof Error ? Promise.reject(this.dashboard) : Promise.resolve(this.dashboard);
  }
  log(message: string) {
    this.logs.push(message);
  }
}

const post = (headers: Record<string, string>, body = '{"action":"dashboard"}') =>
  new Request("https://example.test/functions/v1/orvix-admin", { method: "POST", headers, body });

Deno.test("no token, malformed header and non-owner are refused before any data is read", async () => {
  const cases: Record<string, string>[] = [{}, { authorization: "Basic abc" }, { authorization: "Bearer " }];
  for (const headers of cases) {
    const deps = new FakeDeps();
    const response = await handleAdminRequest(post(headers), deps);
    assertEquals(response.status, 403);
    assertEquals(deps.tokens.length, 0);
    assertEquals(deps.loads, 0);
  }
  const deps = new FakeDeps();
  deps.owner = false;
  const response = await handleAdminRequest(post({ authorization: "Bearer someone-else" }), deps);
  assertEquals(response.status, 403);
  assertEquals(await response.json(), { error: "Not authorized for Orvix Control Center" });
  assertEquals(deps.loads, 0);
});

Deno.test("an auth backend failure is refused, not allowed", async () => {
  const deps = new FakeDeps();
  deps.owner = new Error("auth down");
  const response = await handleAdminRequest(post({ authorization: "Bearer t" }), deps);
  assertEquals(response.status, 403);
  assertEquals(deps.loads, 0);
});

Deno.test("the owner gets the dashboard with no-store caching", async () => {
  const deps = new FakeDeps();
  const response = await handleAdminRequest(post({ authorization: "Bearer owner-token" }), deps);
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "no-store");
  assertEquals(await response.json(), { schema_version: 2 });
  assertEquals(deps.tokens, ["owner-token"]);
});

Deno.test("bad body, unknown action and loader failure", async () => {
  const deps = new FakeDeps();
  assertEquals((await handleAdminRequest(post({ authorization: "Bearer t" }, "{"), deps)).status, 400);
  assertEquals((await handleAdminRequest(post({ authorization: "Bearer t" }, '{"action":"drop"}'), deps)).status, 400);
  deps.dashboard = new Error("db exploded with secret detail");
  const failed = await handleAdminRequest(post({ authorization: "Bearer t" }), deps);
  assertEquals(failed.status, 500);
  assertEquals(await failed.json(), { error: "Dashboard data unavailable" });
});

Deno.test("GET redirects, OPTIONS answers CORS, other methods are refused", async () => {
  const deps = new FakeDeps();
  const get = await handleAdminRequest(new Request("https://example.test/", { method: "GET" }), deps);
  assertEquals([get.status, get.headers.get("location")], [302, DASHBOARD_REDIRECT]);
  const options = await handleAdminRequest(new Request("https://example.test/", { method: "OPTIONS" }), deps);
  assertEquals(options.status, 200);
  const del = await handleAdminRequest(new Request("https://example.test/", { method: "DELETE" }), deps);
  assertEquals(del.status, 405);
  assertEquals(deps.loads, 0);
});
