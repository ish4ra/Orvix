import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const enc=new TextEncoder();
function hex(b:Uint8Array){return Array.from(b).map(x=>x.toString(16).padStart(2,"0")).join("")}
function eq(a:string,b:string){a=a.toLowerCase().trim();b=b.toLowerCase().trim();if(a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0}
async function hmac(s:string,v:string){const k=await crypto.subtle.importKey("raw",enc.encode(s),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return hex(new Uint8Array(await crypto.subtle.sign("HMAC",k,enc.encode(v))))}
function iso(v:any){if(typeof v==="number")return new Date(v*1000).toISOString();if(typeof v==="string"&&v){const n=Number(v);if(Number.isFinite(n)&&/^\d+$/.test(v))return new Date(n*1000).toISOString();const d=new Date(v);if(!Number.isNaN(d.getTime()))return d.toISOString()}return new Date().toISOString()}
Deno.serve(async(req)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const secret=Deno.env.get("BMC_WEBHOOK_SIGNING_SECRET");if(!secret)return new Response("Webhook secret not configured",{status:503});
 const raw=await req.text(),sig=req.headers.get("x-signature-sha256")??"",expected=await hmac(secret,raw);
 if(!sig||!eq(expected,sig.replace(/^sha256=/i,"")))return new Response("Invalid signature",{status:401});
 let body:any;try{body=JSON.parse(raw)}catch{return new Response("Invalid JSON",{status:400})}
 const type=String(body.type??"").toLowerCase(),d=body.data??{},id=d.supporter_id;
 if(id===null||id===undefined)return Response.json({ok:true,ignored:"anonymous/no supporter_id"});
 const inactive=type.endsWith(".cancelled")||type.endsWith(".canceled")||type.endsWith(".paused")||type.endsWith(".refunded");
 const recurring=type.startsWith("membership.")||type.startsWith("monthly_support.")||type.startsWith("subscription.");
 const privateSupport=d.is_public===false||d.is_public==="false"||d.supporter_name_type==="private"||d.supporter_name_type==="anonymous";
 const visible=!inactive&&!privateSupport;
 const at=iso(d.created_at??body.created),now=new Date().toISOString();
 const client=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
 const {error}=await client.from("supporters").upsert({provider:"buymeacoffee",provider_user_id:String(id),display_name:visible?String(d.supporter_name??"BMC supporter"):"Private supporter",avatar_url:visible?(d.supporter_avatar??d.avatar_url??null):null,profile_url:visible?(d.supporter_page_url??d.profile_url??null):null,support_type:recurring?(type.startsWith("membership.")?"Member":"Monthly supporter"):String(d.support_type??"Supporter"),tier:d.membership_level_name??d.membership_name??d.tier_name??null,supporter_since:at,last_supported_at:at,is_recurring:recurring,is_active:!inactive,is_public:visible,updated_at:now},{onConflict:"provider,provider_user_id"});
 if(error)return new Response("Database error",{status:500});return Response.json({ok:true,event:type});
});