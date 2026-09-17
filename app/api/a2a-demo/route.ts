import { act, snapshot } from "@/lib/a2a-demo/store";
export const runtime="nodejs"; export const dynamic="force-dynamic";
const response=(fn:()=>unknown|Promise<unknown>)=>Promise.resolve().then(fn).then(data=>Response.json(data,{headers:{"Cache-Control":"no-store"}})).catch(e=>Response.json({error:e instanceof Error?e.message:"failed"},{status:e instanceof Error&&e.message==="not found"?404:400}));
export async function GET(){return response(snapshot)}
export async function POST(req:Request){return response(async()=>{let body:{action?:unknown};try{body=await req.json()}catch{return Promise.reject(new Error("invalid json"))}return act(typeof body.action==="string"?body.action:"")})}
