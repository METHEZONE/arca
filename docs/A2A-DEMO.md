# ARCA A2A promise demo

A default-off, isolated vertical slice proving one thing end to end: two personal ARCA endpoints establish a trusted connection, privately compute one availability intersection, exchange signed least-privilege envelopes and a Promise Packet, collect both approvals, create an event through an idempotent demo adapter, and close only after evidence exists.

## Run

```bash
ARCA_A2A_DEMO=on ARCA_A2A_DEMO_SIGNING_KEY='local-dev-value' npm run dev
# open http://localhost:4174/a2a-demo
npm run test:a2a
```

No model key or real calendar credential is required. Data is process-memory only and separate from production tables. The route returns 404 unless `ARCA_A2A_DEMO=on`.

## Threat model and invariants

- Identity confusion: endpoint IDs are bound into peer-specific derived signing keys.
- Tampering: canonical HMAC signatures cover packets and permission envelopes; verification uses timing-safe comparison.
- Over-disclosure: the public snapshot exposes window counts and the chosen intersection, never raw calendars.
- Overreach: envelopes allow only `intersection-only` disclosure and `create-demo-calendar-event`.
- Wrong peer, expiry, replay: recipient bindings and 15-minute expiries are verified before each transition; nonces are consumed before adapter execution.
- Premature action: both exact-slot approvals are required before execution.
- Duplicate effects: adapter calls use a stable idempotency key and return the original evidence on retries.
- False completion: missing/invalid evidence or adapter exceptions move the promise to `failed`, never `verified`.

The bundled key fallback is intentionally labeled local-demo-only. Shared demos must set a separate demo secret. This is not a production identity or key-management design.

## Staged roadmap, not implemented

1. Persist trusted connections, nonces, packets, approvals, evidence, and an audit log in dedicated Postgres tables with transactional uniqueness constraints.
2. Replace HMAC endpoint derivation with device-held asymmetric keys, rotation, revocation, and portable trust attestations.
3. Add real Google/Microsoft calendar adapters through existing account auth, with read-back and compensation paths.
4. Use secure multi-party availability protocols or policy-filtered broker queries for larger groups.
5. Add durable workflow retries/timeouts and more evidence adapters. Keep models behind existing provider abstractions; none is needed for this deterministic safety path.
6. Score κ-A2A across recall, intervention, authorization, action, verification, latency, disclosure, and failure recovery.
