import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const html = (url: string, anon: string, code: string) => `<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark">
<title>Link Orvix TV</title><style>
:root{font-family:Inter,system-ui,sans-serif;color:#f5f7f2;background:#050806}*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at 20% 0,#172416 0,transparent 35%),#050806}
.card{width:min(440px,100%);background:#0b0f0c;border:1px solid #263627;border-radius:24px;padding:28px}
.brand{color:#b9ff45;font-weight:900;letter-spacing:.4px}.muted{color:#9ba69c;line-height:1.5}
.code{font-size:32px;font-weight:900;letter-spacing:6px;color:#cbff75;margin:18px 0}
input,button{width:100%;height:52px;border-radius:14px;margin-top:12px;font:inherit}
input{background:#0f1510;color:#fff;border:1px solid #263627;padding:0 15px;outline:none}
input:focus{border-color:#b9ff45}button{border:0;background:#b9ff45;color:#081006;font-weight:900;cursor:pointer}
button:disabled{opacity:.55}.msg{min-height:22px;margin-top:14px;color:#cbff75}
</style></head><body><main class="card"><div class="brand">ORVIX</div><h1>Link your TV</h1>
<p class="muted">Sign in on this phone to approve the Orvix TV showing this code.</p><div class="code">${code.slice(0,3)}-${code.slice(3)}</div>
<form id="f"><input id="e" type="email" autocomplete="email" placeholder="Email" required>
<input id="p" type="password" autocomplete="current-password" placeholder="Password" minlength="6" required>
<button id="b">Approve TV</button></form><div id="m" class="msg"></div>
<p class="muted">Your password is sent directly to Orvix's Supabase Auth service and is not stored by the TV-link page.</p></main>
<script type="module">
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const s=createClient(${JSON.stringify(url)},${JSON.stringify(anon)});
const f=document.querySelector('#f'),b=document.querySelector('#b'),m=document.querySelector('#m');
f.addEventListener('submit',async(e)=>{e.preventDefault();b.disabled=true;m.textContent='Signing in…';
try{const email=document.querySelector('#e').value.trim(),password=document.querySelector('#p').value;
const {error:a}=await s.auth.signInWithPassword({email,password});if(a)throw a;
m.textContent='Approving TV…';const {data,error}=await s.rpc('approve_tv_login_session',{p_user_code:${JSON.stringify(code)}});if(error)throw error;
if(!data)throw new Error('This code expired or was already used.');
m.textContent='TV linked. You can return to Orvix.';f.style.display='none';
}catch(err){m.textContent=err?.message||'Could not link TV.';b.disabled=false;}});
</script></body></html>`;

Deno.serve(async (req) => {
  if (req.method !== "GET") return new Response("Method not allowed", { status: 405 });
  const code = (new URL(req.url).searchParams.get("code") ?? "").replace(/[^a-zA-Z0-9]/g, "").toUpperCase().slice(0, 6);
  if (code.length !== 6) return new Response("Invalid link code", { status: 400 });
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!url || !anon) return new Response("Server configuration error", { status: 503 });
  return new Response(html(url, anon, code), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-frame-options": "DENY", "referrer-policy": "no-referrer" } });
});
