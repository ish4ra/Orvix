import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const enc=new TextEncoder();
function hex(b:Uint8Array){return Array.from(b).map(x=>x.toString(16).padStart(2,"0")).join("")}
function eq(a:string,b:string){if(a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0}
async function sig(s:string,v:string){const k=await crypto.subtle.importKey("raw",enc.encode(s),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return "sha256="+hex(new Uint8Array(await crypto.subtle.sign("HMAC",k,enc.encode(v))))}
Deno.serve(async(req)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const secret=Deno.env.get("GITHUB_SPONSORS_WEBHOOK_SECRET");if(!secret)return new Response("Webhook secret not configured",{status:503});
 const raw=await req.text(),supplied=req.headers.get("x-hub-signature-256")??"",expected=await sig(secret,raw);
 if(!eq(supplied,expected))return new Response("Invalid signature",{status:401});
 const event=req.headers.get("x-github-event")??"";if(event==="ping")return Response.json({ok:true,event:"ping"});if(event!=="sponsorship")return Response.json({ok:true,ignored:event});
 let body:any;try{body=JSON.parse(raw)}catch{return new Response("Invalid JSON",{status:400})}
 const sponsorship=body.sponsorship??{},sponsor=sponsorship.sponsor;if(!sponsor?.id)return Response.json({ok:true,ignored:"private sponsor"});
 const action=String(body.action??"").toLowerCase(),inactive=action==="cancelled"||action==="canceled";
 const now=new Date().toISOString(),client=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
 const {error}=await client.from("supporters").upsert({provider:"github",provider_user_id:String(sponsor.id),display_name:sponsor.name??sponsor.login??"GitHub supporter",avatar_url:sponsor.avatar_url??null,profile_url:sponsor.html_url??null,support_type:sponsorship.is_one_time_payment?"One-time sponsor":"Sponsor",tier:sponsorship.tier?.name??null,supporter_since:sponsorship.created_at??now,last_supported_at:now,is_recurring:!sponsorship.is_one_time_payment,is_active:!inactive,is_public:!inactive,updated_at:now},{onConflict:"provider,provider_user_id"});
 if(error)return new Response("Database error",{status:500});return Response.json({ok:true});
});