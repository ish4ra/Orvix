// deno test --allow-read supabase/functions/orvix-admin/
// Guards the self-hosted Control Center page: no CDN scripts, a pinned and
// integrity-checked supabase-js copy, and a CSP that keeps it that way.
import { assert, assertEquals } from "./test_assert.ts";

const web = new URL("./web/", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, web));
const bytes = async (path: string): Promise<BufferSource> =>
  new Uint8Array(await Deno.readFile(new URL(path, web))).buffer;

async function digest(algorithm: "SHA-256" | "SHA-384", data: BufferSource) {
  return new Uint8Array(await crypto.subtle.digest(algorithm, data));
}
const hex = (data: Uint8Array) => [...data].map((b) => b.toString(16).padStart(2, "0")).join("");
const base64 = (data: Uint8Array) => btoa(String.fromCharCode(...data));

const html = await read("index.html");
const app = await read("app.js");
const vendorScript = await Deno.readTextFile(
  new URL("../../../tools/vendor_supabase_js.sh", import.meta.url),
);
const version = /^VERSION="([^"]+)"$/m.exec(vendorScript)?.[1] ?? "";

Deno.test("the page loads scripts only from its own origin", () => {
  const sources = [...html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map((m) => m[1]);
  assertEquals(sources, [`vendor/supabase-js/${version}/supabase.js`, "app.js"]);
  assertEquals(html.match(/<script\b[^>]*>\s*[^<\s]/g), null, "no inline script bodies");
  for (const text of [html, app]) {
    for (const host of ["esm.sh", "unpkg.com", "jsdelivr", "cdnjs", "skypack"]) {
      assert(!text.includes(host), `no ${host} reference`);
    }
    assert(!/\bimport\s*\(|^\s*import\s/m.test(text), "no ES module imports");
  }
});

Deno.test("the CSP forbids inline and third-party scripts", () => {
  const csp = /http-equiv="Content-Security-Policy" content="([^"]+)"/.exec(html)?.[1] ?? "";
  const directives = Object.fromEntries(
    csp.split(";").map((d) => d.trim().split(/\s+/)).map(([k, ...v]) => [k, v]),
  );
  assertEquals(directives["script-src"], ["'self'"]);
  assertEquals(directives["default-src"], ["'none'"]);
  assertEquals(directives["connect-src"], ["https://kpjuisxofwqxhbnnsyzf.supabase.co"]);
  assertEquals(directives["base-uri"], ["'none'"]);
});

Deno.test("the vendored supabase-js matches its checksums and the page's SRI", async () => {
  assert(/^\d+\.\d+\.\d+$/.test(version), `pinned version ${version}`);
  const dir = `vendor/supabase-js/${version}/`;
  const sums = (await read(dir + "SHA256SUMS")).trim().split("\n").map((line) => line.split(/\s+/));
  assertEquals(sums.map(([, file]) => file), ["supabase.js", "591.supabase.js", "LICENSE"]);
  for (const [sum, file] of sums) {
    assertEquals(hex(await digest("SHA-256", await bytes(dir + file))), sum, file);
  }
  const sri = `sha384-${base64(await digest("SHA-384", await bytes(dir + "supabase.js")))}`;
  assert(
    html.includes(`src="${dir}supabase.js" integrity="${sri}"`),
    `index.html must pin ${sri}`,
  );
  assert((await read(dir + "LICENSE")).includes("MIT License"), "MIT licence kept");
});

Deno.test("only the publishable key is embedded in the page", () => {
  for (const text of [html, app]) {
    assert(!/service_role|sb_secret_|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(text), "no secret keys or JWTs");
  }
  assert(app.includes('"sb_publishable_'), "publishable key present");
});
