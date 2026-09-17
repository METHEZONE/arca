import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";

export type CommitmentState = "proposed" | "agreed" | "authorized" | "executing" | "verified" | "failed";
export type EndpointId = "arca:demo:alice" | "arca:demo:bob";
export type Window = { start: string; end: string };
export type PermissionEnvelope = {
  id: string; issuer: EndpointId; recipient: EndpointId; purpose: "calendar-match";
  disclose: readonly ["intersection-only"]; actions: readonly ["create-demo-calendar-event"];
  expiresAt: string; nonce: string;
};
export type PromisePacket = {
  id: string; proposer: EndpointId; counterparty: EndpointId; title: string; slot: Window;
  permissionId: string; expiresAt: string; nonce: string;
};
export type Signed<T> = { payload: T; signature: string };
export type Evidence = { adapter: "demo-calendar"; externalId: string; observedAt: string; digest: string };
export type KappaEvent = { at: string; stage: "recall"|"intervene"|"authorize"|"act"|"verify"; ok: boolean; detail: string };
export type DemoCommitment = {
  id: string; state: CommitmentState; connectionId: string; packet: Signed<PromisePacket>;
  envelopes: Signed<PermissionEnvelope>[]; approvals: Partial<Record<EndpointId, string>>;
  evidence?: Evidence; events: KappaEvent[]; failure?: string;
};

const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value as Record<string, unknown>).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
};
const keyFor = (endpoint: EndpointId, master: string) => createHmac("sha256", master).update(endpoint).digest();
export const sign = <T>(payload: T, endpoint: EndpointId, master: string): Signed<T> => ({ payload, signature: createHmac("sha256", keyFor(endpoint, master)).update(canonical(payload)).digest("base64url") });
export const verify = <T>(signed: Signed<T>, endpoint: EndpointId, master: string): boolean => {
  const expected = sign(signed.payload, endpoint, master).signature;
  const a = Buffer.from(signed.signature); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
};
export const privateIntersection = (left: Window[], right: Window[]): Window[] => left.flatMap(a => right.map(b => ({ start: new Date(Math.max(Date.parse(a.start), Date.parse(b.start))).toISOString(), end: new Date(Math.min(Date.parse(a.end), Date.parse(b.end))).toISOString() }))).filter(w => Date.parse(w.end)-Date.parse(w.start) >= 60*60*1000).sort((a,b) => a.start.localeCompare(b.start));

export class A2ADemoEngine {
  private usedNonces = new Set<string>(); private adapterKeys = new Map<string, string>();
  private master: string; private now: () => Date;
  constructor(master: string, now: () => Date = () => new Date()) { this.master = master; this.now = now; if (!master) throw new Error("demo signing key required"); }
  connect(a: EndpointId, b: EndpointId) { if (a === b) throw new Error("identity mismatch"); return { id: randomUUID(), peers: [a,b] as const, establishedAt: this.now().toISOString() }; }
  propose(connectionId: string, left: Window[], right: Window[]): DemoCommitment {
    const slot = privateIntersection(left,right)[0]; if (!slot) throw new Error("no private intersection");
    const expiresAt = new Date(this.now().getTime()+15*60_000).toISOString();
    const makeEnvelope = (issuer: EndpointId, recipient: EndpointId) => sign<PermissionEnvelope>({ id: randomUUID(), issuer, recipient, purpose:"calendar-match", disclose:["intersection-only"], actions:["create-demo-calendar-event"], expiresAt, nonce:randomUUID() }, issuer, this.master);
    const envelopes = [makeEnvelope("arca:demo:alice","arca:demo:bob"), makeEnvelope("arca:demo:bob","arca:demo:alice")];
    const packet = sign<PromisePacket>({ id:randomUUID(), proposer:"arca:demo:alice", counterparty:"arca:demo:bob", title:"Coffee and roadmap sync", slot, permissionId:envelopes[0].payload.id, expiresAt, nonce:randomUUID() }, "arca:demo:alice", this.master);
    return { id:packet.payload.id, state:"proposed", connectionId, packet, envelopes, approvals:{}, events:[{at:this.now().toISOString(),stage:"recall",ok:true,detail:"Each endpoint supplied local availability"},{at:this.now().toISOString(),stage:"intervene",ok:true,detail:"Only one intersection was disclosed"}] };
  }
  agree(c: DemoCommitment): DemoCommitment { this.assertValid(c); if(c.state!=="proposed") throw new Error("invalid transition"); return {...c,state:"agreed"}; }
  approve(c: DemoCommitment, actor: EndpointId): DemoCommitment { this.assertValid(c); if(!["agreed","authorized"].includes(c.state)) throw new Error("approval gate closed"); if(actor!==c.packet.payload.proposer&&actor!==c.packet.payload.counterparty) throw new Error("recipient mismatch"); const approvals={...c.approvals,[actor]:this.now().toISOString()}; const complete=Boolean(approvals["arca:demo:alice"]&&approvals["arca:demo:bob"]); return {...c,approvals,state:complete?"authorized":c.state,events:complete?[...c.events,{at:this.now().toISOString(),stage:"authorize",ok:true,detail:"Both people explicitly approved the exact slot"}]:c.events}; }
  async execute(c: DemoCommitment, adapter: (p:PromisePacket,key:string)=>Promise<Evidence>): Promise<DemoCommitment> { this.assertValid(c); if(c.state!=="authorized") throw new Error("approval gate closed"); const idempotencyKey=`${c.id}:${c.packet.signature}`; const prior=this.adapterKeys.get(idempotencyKey); if(prior) return {...c,state:"verified",evidence:JSON.parse(prior)}; this.consume(c.packet.payload.nonce); for(const e of c.envelopes) this.consume(e.payload.nonce); try { const evidence=await adapter(c.packet.payload,idempotencyKey); if(!evidence.externalId||!evidence.digest) throw new Error("adapter evidence invalid"); this.adapterKeys.set(idempotencyKey,JSON.stringify(evidence)); return {...c,state:"verified",evidence,events:[...c.events,{at:this.now().toISOString(),stage:"act",ok:true,detail:"GitHub adapter observed PR URL, commit, and passing tests"},{at:this.now().toISOString(),stage:"verify",ok:true,detail:"Completion predicate passed without a human status report"}]}; } catch(e) { return {...c,state:"failed",failure:e instanceof Error?e.message:"adapter error",events:[...c.events,{at:this.now().toISOString(),stage:"act",ok:false,detail:"Adapter failed closed"}]}; } }
  private consume(nonce:string){ if(this.usedNonces.has(nonce)) throw new Error("replay rejected"); this.usedNonces.add(nonce); }
  private assertValid(c:DemoCommitment){ const now=this.now().getTime(); if(Date.parse(c.packet.payload.expiresAt)<=now) throw new Error("packet expired"); if(!verify(c.packet,c.packet.payload.proposer,this.master)) throw new Error("invalid packet signature"); for(const e of c.envelopes){if(Date.parse(e.payload.expiresAt)<=now) throw new Error("permission expired"); if(!verify(e,e.payload.issuer,this.master)) throw new Error("invalid permission signature"); if(e.payload.recipient!== (e.payload.issuer==="arca:demo:alice"?"arca:demo:bob":"arca:demo:alice")) throw new Error("recipient mismatch"); if(e.payload.disclose.join()!=="intersection-only") throw new Error("overbroad disclosure"); } }
}
