// deno test supabase/functions/tv-login-link/page_test.ts
import { linkCode, linkPage, securityHeaders } from "./page.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

const URL_BASE = "https://project.supabase.co/functions/v1/tv-login-link";

Deno.test("codes are normalized and anything else is rejected", () => {
  assert(linkCode(`${URL_BASE}?code=abc123`) === "ABC123", "lower case");
  assert(linkCode(`${URL_BASE}?code=ABC-123`) === "ABC123", "separator");
  assert(linkCode(`${URL_BASE}?code=AB`) === null, "too short");
  assert(linkCode(`${URL_BASE}?code=ABC1234`) === null, "too long");
  assert(linkCode(URL_BASE) === null, "missing");
  assert(linkCode(`${URL_BASE}?code=%3Cscript%3E`) === "SCRIPT", "markup characters are stripped");
});

Deno.test("the page contains only the sanitized code and nonce-bound scripts", () => {
  const code = linkCode(`${URL_BASE}?code=<AB"C>1'23`);
  assert(code === "ABC123", `unexpected code ${code}`);
  const page = linkPage("https://project.supabase.co", "publishable", code!, "n0nce");
  assert(!page.includes('AB"C') && !page.includes("1'23"), "markup was echoed");
  assert(page.includes("ABC-123"), "the code is not shown");
  assert(page.includes('<script type="module" nonce="n0nce">'), "script without nonce");
  assert(page.includes('<style nonce="n0nce">'), "style without nonce");
  assert(page.includes("persistSession:false"), "the browser session must not persist");
  assert(page.includes("signOut({scope:'local'})"), "the page must end its session");
  assert(!page.includes("err?.message") && !page.includes("error.message"), "raw backend errors shown");
});

Deno.test("responses are not cacheable, frameable or sniffable", () => {
  const headers = securityHeaders("https://project.supabase.co", "n0nce");
  assert(headers["cache-control"] === "no-store", "cache-control");
  assert(headers["x-frame-options"] === "DENY", "x-frame-options");
  assert(headers["referrer-policy"] === "no-referrer", "referrer-policy");
  assert(headers["x-content-type-options"] === "nosniff", "nosniff");
  const csp = headers["content-security-policy"];
  assert(csp.includes("default-src 'none'"), "default-src");
  assert(csp.includes("script-src 'nonce-n0nce' https://esm.sh"), "script-src");
  assert(csp.includes("connect-src https://project.supabase.co"), "connect-src");
  assert(csp.includes("frame-ancestors 'none'"), "frame-ancestors");
});
