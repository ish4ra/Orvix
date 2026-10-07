// The tv-login-link page and its response headers (index.ts serves them).
// The password typed on the page goes only to Supabase Auth.

const escapeHtml = (value: string) =>
  value.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export function linkCode(requestUrl: string): string | null {
  const code = (new URL(requestUrl).searchParams.get("code") ?? "")
    .replace(/[^a-zA-Z0-9]/g, "")
    .toUpperCase();
  return code.length === 6 ? code : null;
}

export function linkPage(url: string, anon: string, code: string, nonce: string): string {
  const shown = escapeHtml(`${code.slice(0, 3)}-${code.slice(3)}`);
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark">
<title>Link Orvix TV</title><style nonce="${nonce}">
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
<p class="muted">Sign in on this phone to approve the Orvix TV showing this code. Only continue if this code is on your own TV.</p><div class="code">${shown}</div>
<form id="f"><input id="e" type="email" autocomplete="email" placeholder="Email" required>
<input id="p" type="password" autocomplete="current-password" placeholder="Password" minlength="6" required>
<button id="b">Approve TV</button></form><div id="m" class="msg" role="status"></div>
<p class="muted">Your password is sent directly to Orvix's Supabase Auth service and is not stored by the TV-link page.</p></main>
<script type="module" nonce="${nonce}">
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
const s=createClient(${JSON.stringify(url)},${JSON.stringify(anon)},{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
const code=${JSON.stringify(code)};
const f=document.querySelector('#f'),b=document.querySelector('#b'),m=document.querySelector('#m');
const signInMessage=(e)=>{const c=e&&e.code;if(c==='invalid_credentials')return 'Email or password is incorrect.';
if(c==='email_not_confirmed')return 'Confirm your email address first, then try again.';
if(e&&e.status===429)return 'Too many attempts. Wait a minute and try again.';return 'Could not sign in. Check your connection and try again.';};
f.addEventListener('submit',async(e)=>{e.preventDefault();b.disabled=true;m.textContent='Signing in…';
const email=document.querySelector('#e').value.trim(),password=document.querySelector('#p').value;
const {error:a}=await s.auth.signInWithPassword({email,password});
if(a){m.textContent=signInMessage(a);b.disabled=false;return;}
m.textContent='Approving TV…';
let text='Could not approve the TV. Check your connection and try again.',done=false;
try{const {data,error}=await s.rpc('approve_tv_login_session',{p_user_code:code});
if(error){if(error.hint==='tv_login_rate_limited')text='Too many TV code attempts. Try again later.';}
else if(data===true){text='TV linked. You can return to Orvix.';done=true;}
else{text='This code expired or was already used. Refresh the code on your TV and scan it again.';}
}catch(_){}
try{await s.auth.signOut({scope:'local'});}catch(_){}
m.textContent=text;if(done){f.style.display='none';}else{b.disabled=false;}});
</script></body></html>`;
}

export function securityHeaders(url: string, nonce: string): Record<string, string> {
  return {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "x-frame-options": "DENY",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "content-security-policy": [
      "default-src 'none'",
      `script-src 'nonce-${nonce}' https://esm.sh`,
      `style-src 'nonce-${nonce}'`,
      `connect-src ${new URL(url).origin}`,
      "img-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join("; "),
  };
}
