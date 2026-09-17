import { createHash } from "node:crypto";
import { A2ADemoEngine, type DemoCommitment, type PromisePacket } from "./core";

const enabled = () => process.env.ARCA_A2A_DEMO === "on";
const engine = new A2ADemoEngine(process.env.ARCA_A2A_DEMO_SIGNING_KEY || "local-demo-only-not-production");
let commitment: DemoCommitment | null = null;
const availability = {
  alice:[{start:"2026-09-22T09:00:00.000Z",end:"2026-09-22T12:00:00.000Z"},{start:"2026-09-24T08:00:00.000Z",end:"2026-09-24T11:00:00.000Z"}],
  bob:[{start:"2026-09-22T10:00:00.000Z",end:"2026-09-22T13:00:00.000Z"},{start:"2026-09-23T08:00:00.000Z",end:"2026-09-23T10:00:00.000Z"}],
};
const calendar = async (p:PromisePacket,key:string) => ({adapter:"demo-calendar" as const,externalId:`demo-event-${createHash("sha256").update(key).digest("hex").slice(0,12)}`,observedAt:new Date().toISOString(),digest:createHash("sha256").update(`${p.id}:${p.slot.start}:${p.slot.end}`).digest("base64url")});
export function snapshot(){ if(!enabled()) throw new Error("not found"); return { commitment, endpoints:[{id:"arca:demo:alice",label:"Alice ARCA",availabilityCount:availability.alice.length},{id:"arca:demo:bob",label:"Bob ARCA",availabilityCount:availability.bob.length}], rawCalendarsDisclosed:false }; }
export async function act(action:string){ if(!enabled()) throw new Error("not found"); if(action==="reset"){commitment=null;return snapshot();} if(action==="connect-match"){const c=engine.connect("arca:demo:alice","arca:demo:bob"); commitment=engine.propose(c.id,availability.alice,availability.bob);return snapshot();} if(!commitment) throw new Error("start the demo first"); if(action==="agree") commitment=engine.agree(commitment); else if(action==="approve-alice") commitment=engine.approve(commitment,"arca:demo:alice"); else if(action==="approve-bob") commitment=engine.approve(commitment,"arca:demo:bob"); else if(action==="execute") commitment=await engine.execute(commitment,calendar); else throw new Error("unknown action"); return snapshot(); }
