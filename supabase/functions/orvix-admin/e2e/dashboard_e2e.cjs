// Browser test for the self-hosted Control Center page (web/). It runs the
// real page and the vendored supabase-js in Chromium; only the network is
// faked: Supabase Auth and the orvix-admin function are answered locally,
// and every other host is refused and fails the test.
//
//   node supabase/functions/orvix-admin/e2e/dashboard_e2e.cjs
//
// Needs Node, Deno (to build the payload with the real buildDashboard) and
// Playwright with Chromium (PLAYWRIGHT_MODULE points at the playwright
// package if it is not resolvable; CHROMIUM_PATH at a Chromium binary).
"use strict";

const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");

const here = __dirname;
const webDir = path.join(here, "..", "web");
const origin = "https://orvix-cc.test";
const base = `${origin}/orvix/console/`;
const project = "https://kpjuisxofwqxhbnnsyzf.supabase.co";
const storageKey = "sb-kpjuisxofwqxhbnnsyzf-auth-token";

const payload = execFileSync(
  process.env.DENO || "deno",
  ["run", "--allow-read", "--no-remote", path.join(here, "payload.ts")],
  { encoding: "utf8" },
);

const types = { ".html": "text/html", ".js": "application/javascript" };

function fakeJwt() {
  const part = (v) => Buffer.from(JSON.stringify(v)).toString("base64url");
  const exp = Math.floor(Date.now() / 1000) + 3600;
  return `${part({ alg: "HS256", typ: "JWT" })}.${part({ sub: "u1", role: "authenticated", exp })}.sig`;
}

function session() {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  return {
    access_token: fakeJwt(),
    token_type: "bearer",
    expires_in: 3600,
    expires_at: exp,
    refresh_token: "refresh-token",
    user: { id: "u1", aud: "authenticated", role: "authenticated", email: "owner@example.com" },
  };
}

// Per-test switches for the fake backend.
function backend() {
  return {
    login: "ok", // ok | invalid | network
    dashboard: "ok", // ok | forbidden | error
    vendor: "ok", // ok | missing
    calls: [],
    foreign: [],
  };
}

async function open(browser, state, context) {
  context = context ?? await browser.newContext();
  const page = await context.newPage();
  const problems = [];
  page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    const text = m.text();
    if (/Content Security Policy|Refused to/i.test(text)) problems.push(`csp: ${text}`);
  });
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    if (url.origin === origin && url.pathname.startsWith("/orvix/console/")) {
      let rel = url.pathname.slice("/orvix/console/".length) || "index.html";
      if (state.vendor === "missing" && rel.startsWith("vendor/")) return route.fulfill({ status: 404, body: "" });
      const file = path.join(webDir, rel);
      if (!file.startsWith(webDir) || !fs.existsSync(file)) return route.fulfill({ status: 404, body: "" });
      return route.fulfill({
        status: 200,
        contentType: types[path.extname(file)] ?? "text/plain",
        body: fs.readFileSync(file),
      });
    }
    if (url.origin === project) {
      state.calls.push(`${request.method()} ${url.pathname}${url.search}`);
      const headers = { "access-control-allow-origin": "*", "access-control-allow-headers": "*" };
      if (request.method() === "OPTIONS") return route.fulfill({ status: 200, headers });
      if (url.pathname === "/auth/v1/token") {
        if (state.login === "network") return route.abort("failed");
        if (state.login === "invalid") {
          return route.fulfill({
            status: 400, headers, contentType: "application/json",
            body: JSON.stringify({ code: 400, error_code: "invalid_credentials", msg: "Invalid login credentials" }),
          });
        }
        return route.fulfill({ status: 200, headers, contentType: "application/json", body: JSON.stringify(session()) });
      }
      if (url.pathname === "/auth/v1/logout") return route.fulfill({ status: 204, headers });
      if (url.pathname === "/functions/v1/orvix-admin") {
        const auth = request.headers()["authorization"] ?? "";
        assert.match(auth, /^Bearer ey/, "dashboard request carries the session token");
        assert.equal(request.headers()["apikey"], "sb_publishable_HmqvNavX_iovenN3YRgpmA_cgxQdG9y");
        assert.deepEqual(JSON.parse(request.postData() ?? "{}"), { action: "dashboard" });
        if (state.dashboard === "forbidden") {
          return route.fulfill({ status: 403, headers, contentType: "application/json", body: JSON.stringify({ error: "Not authorized for Orvix Control Center" }) });
        }
        if (state.dashboard === "error") {
          return route.fulfill({ status: 500, headers, contentType: "application/json", body: JSON.stringify({ error: "Dashboard data unavailable" }) });
        }
        return route.fulfill({ status: 200, headers, contentType: "application/json", body: payload });
      }
      return route.fulfill({ status: 404, headers, body: "" });
    }
    state.foreign.push(url.href);
    return route.abort("blockedbyclient");
  });
  await page.goto(base);
  return { page, context, problems };
}

const visible = (page, id) => page.locator(`#${id}`).isVisible();

async function signIn(page) {
  await page.fill("#email", "owner@example.com");
  await page.fill("#password", "secret");
  await page.click("#loginBtn");
}

const tests = {
  async "signed out: login view, no CDN, no CSP violations"(browser) {
    const state = backend();
    const { page, problems } = await open(browser, state);
    await page.waitForSelector("#login:not(.hidden)");
    assert.equal(await visible(page, "app"), false);
    assert.equal(await page.evaluate(() => typeof window.supabase?.createClient), "function");
    return { state, problems };
  },

  async "wrong password shows the error and re-enables the button"(browser) {
    const state = backend();
    state.login = "invalid";
    const { page, problems } = await open(browser, state);
    await signIn(page);
    await page.waitForFunction(() => document.getElementById("loginError").textContent.length > 0);
    assert.match(await page.textContent("#loginError"), /Invalid login credentials/);
    assert.equal(await page.isEnabled("#loginBtn"), true);
    assert.equal(await visible(page, "app"), false);
    return { state, problems };
  },

  async "network failure during sign-in is reported"(browser) {
    const state = backend();
    state.login = "network";
    const { page, problems } = await open(browser, state);
    await signIn(page);
    await page.waitForFunction(() => document.getElementById("loginError").textContent.length > 0, null, { timeout: 30000 });
    assert.equal(await page.isEnabled("#loginBtn"), true);
    assert.equal(await visible(page, "app"), false);
    return { state, problems };
  },

  async "sign-in renders the dashboard, reload restores the session, sign-out clears it"(browser) {
    const state = backend();
    const { page, context, problems } = await open(browser, state);
    await signIn(page);
    await page.waitForSelector("#activityTiles .tile");
    assert.equal(await visible(page, "login"), false);
    assert.equal(await page.locator("#activityTiles .tile").count(), 8);
    assert.match(await page.textContent("#generated"), /Updated/);
    assert.match(await page.textContent("#downloadStatus"), /GitHub data fetched/);
    assert.ok(await page.locator("#releasesBody tr").count() > 0);
    assert.match(await page.textContent("#liveBody"), /Owner/);
    assert.ok(await page.evaluate((k) => localStorage.getItem(k) !== null, storageKey));

    // Session restoration: a fresh page in the same browser profile.
    await page.close();
    const restored = await open(browser, state, context);
    await restored.page.waitForSelector("#activityTiles .tile");
    assert.equal(await visible(restored.page, "login"), false);
    problems.push(...restored.problems);

    await restored.page.click("#logoutBtn");
    await restored.page.waitForSelector("#login:not(.hidden)");
    assert.equal(await restored.page.evaluate((k) => localStorage.getItem(k), storageKey), null);
    assert.ok(state.calls.some((c) => c.startsWith("POST /auth/v1/logout")), "logout reaches Supabase Auth");
    return { state, problems };
  },

  async "backend 500 keeps the owner signed in and shows the failure"(browser) {
    const state = backend();
    state.dashboard = "error";
    const { page, problems } = await open(browser, state);
    await signIn(page);
    await page.waitForSelector(".banner.error");
    assert.match(await page.textContent("#banners"), /Dashboard data unavailable \(HTTP 500\)/);
    assert.equal(await visible(page, "app"), true);
    return { state, problems };
  },

  async "403 from the function signs out and returns to login"(browser) {
    const state = backend();
    state.dashboard = "forbidden";
    const { page, problems } = await open(browser, state);
    await signIn(page);
    await page.waitForSelector("#login:not(.hidden)");
    assert.match(await page.textContent("#loginError"), /Not authorized for Orvix Control Center/);
    assert.equal(await page.evaluate((k) => localStorage.getItem(k), storageKey), null);
    return { state, problems };
  },

  async "missing vendor files are reported instead of failing silently"(browser) {
    const state = backend();
    state.vendor = "missing";
    const { page } = await open(browser, state);
    await page.waitForFunction(() => document.getElementById("loginError").textContent.length > 0);
    assert.match(await page.textContent("#loginError"), /Supabase client did not load/);
    // The 404 for the vendor file is the expected failure here.
    return { state, problems: [] };
  },
};

(async () => {
  const browser = await chromium.launch(
    process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {},
  );
  let failed = 0;
  for (const [name, run] of Object.entries(tests)) {
    try {
      const { state, problems } = await run(browser);
      assert.deepEqual(state.foreign, [], "no request leaves the page origin and Supabase");
      assert.deepEqual(problems, [], "no page errors or CSP violations");
      console.log(`ok   ${name}`);
    } catch (error) {
      failed++;
      console.log(`FAIL ${name}\n     ${error.stack?.split("\n").slice(0, 3).join("\n     ")}`);
    }
  }
  await browser.close();
  console.log(failed ? `${failed} failed` : `${Object.keys(tests).length} passed`);
  process.exit(failed ? 1 : 0);
})();
