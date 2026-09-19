// node --experimental-strip-types --test lib/moments/first-contact.test.ts
// Pure-logic coverage for docs/ARCA-FIRST-CONTACT.md §3–§6 — no database,
// no model key, same contract as lib/brain/logic.test.ts.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildFirstContactMoment,
  deriveCommitment,
  pickHook,
  renderFirstMessage,
  sanitizeSignals,
  scoreSignal,
  shouldDeliverFirstContact,
  type PublicSignal,
} from "./first-contact.ts";

const NOW = new Date("2026-09-19T02:00:00Z");

const bookTalk: PublicSignal = {
  kind: "event",
  title: "9월 서울 북토크",
  url: "https://example.com/newsletter-sept",
  snippet: "9월 30일 강남에서 북토크를 엽니다.",
  publishedAt: "2026-09-10T00:00:00Z",
  eventAt: "2026-09-30T10:00:00Z",
};

const essay: PublicSignal = {
  kind: "writing",
  title: "AI를 인터페이스로 봐야 하는 이유",
  url: "https://example.com/p/ai-interface",
  publishedAt: "2026-09-17T00:00:00Z",
};

const linkedin: PublicSignal = {
  kind: "social",
  title: "LinkedIn 프로필",
  url: "https://www.linkedin.com/in/example",
};

const profile: PublicSignal = {
  kind: "profile",
  title: "회사 소개 페이지",
  url: "https://example.com/about",
};

describe("scoreSignal", () => {
  it("ranks an upcoming dated event above recent writing, and writing above social/profile", () => {
    const scores = [bookTalk, essay, linkedin, profile].map((s) => scoreSignal(s, NOW));
    assert.ok(scores[0] > scores[1], "event should beat writing");
    assert.ok(scores[1] > scores[2], "writing should beat social");
    assert.ok(scores[2] > scores[3], "social should beat profile");
  });

  it("demotes events that already happened", () => {
    const past = { ...bookTalk, eventAt: "2026-09-01T10:00:00Z" };
    assert.ok(scoreSignal(past, NOW) < scoreSignal(profile, NOW));
  });

  it("cools off as the event recedes", () => {
    const soon = scoreSignal({ ...bookTalk, eventAt: "2026-09-20T10:00:00Z" }, NOW);
    const later = scoreSignal({ ...bookTalk, eventAt: "2026-10-30T10:00:00Z" }, NOW);
    assert.ok(soon > later);
  });
});

describe("pickHook", () => {
  it("leads with the strongest signal and carries one supporting signal of another kind", () => {
    const hook = pickHook([linkedin, essay, bookTalk], NOW);
    assert.equal(hook?.primary.url, bookTalk.url);
    assert.equal(hook?.secondary?.url, essay.url);
  });

  it("returns null on an empty footprint instead of forcing a hook", () => {
    assert.equal(pickHook([], NOW), null);
    assert.equal(pickHook([profile], NOW), null);
  });
});

describe("deriveCommitment", () => {
  it("proposes an event commitment with evidence and days remaining", () => {
    const hook = pickHook([bookTalk, essay], NOW)!;
    const c = deriveCommitment(hook, NOW, "ko");
    assert.equal(c?.state, "proposed");
    assert.equal(c?.title, bookTalk.title);
    assert.deepEqual(c?.evidence, [bookTalk.url]);
    assert.match(c?.whyNow ?? "", /11일/);
    assert.ok((c?.suggestedActions.length ?? 0) > 0);
  });

  it("never invents a commitment from a bare profile or social account", () => {
    const hook = { primary: linkedin, secondary: profile };
    assert.equal(deriveCommitment(hook, NOW), null);
  });
});

describe("renderFirstMessage", () => {
  it("answers 'how did you know' inside the message and asks permission before any action", () => {
    const hook = pickHook([bookTalk, essay], NOW)!;
    const c = deriveCommitment(hook, NOW, "ko");
    const msg = renderFirstMessage({ name: "이안", hook, commitment: c, lang: "ko", now: NOW });
    assert.match(msg, /이안님/);
    assert.match(msg, /연결 설정은 하지 않으셔도/); // zero-setup is said out loud
    assert.ok(msg.includes(bookTalk.url), "provenance is inline");
    assert.match(msg, /동의하시기 전까지는 아무것도 실행하지 않습니다/);
    assert.match(msg, /맡기시겠어요\?/);
  });

  it("falls back to a plain hello when there is no public footprint", () => {
    const msg = renderFirstMessage({ hook: null, commitment: null, lang: "ko" });
    assert.match(msg, /대화하면서 맥락을 쌓는/);
    assert.doesNotMatch(msg, /undefined/);
  });

  it("renders English with the same rules", () => {
    const hook = pickHook([bookTalk], NOW)!;
    const c = deriveCommitment(hook, NOW, "en");
    const msg = renderFirstMessage({ name: "Ian", hook, commitment: c, lang: "en", now: NOW });
    assert.match(msg, /Ian, hello/);
    assert.ok(msg.includes(bookTalk.url));
    assert.match(msg, /Nothing runs until you say yes/);
  });
});

describe("buildFirstContactMoment", () => {
  it("every claim traces to the sources footer", () => {
    const moment = buildFirstContactMoment({ name: "이안", signals: [bookTalk, essay, linkedin], now: NOW });
    assert.ok(moment.sources.length >= 1);
    for (const s of moment.sources) {
      // Every source chip traces to the message — by URL (inline provenance
      // or commitment evidence) or by being named in the "also found" line.
      assert.ok(
        moment.message.includes(s.url) ||
          moment.commitment?.evidence.includes(s.url) ||
          moment.message.includes(s.title),
        `untraced source: ${s.url}`,
      );
    }
    assert.equal(moment.commitment?.state, "proposed");
  });
});

describe("sanitizeSignals", () => {
  it("drops entries without a kind, title, or http(s) url, and caps the list", () => {
    const junk = [
      { kind: "event", title: "ok", url: "https://example.com/a" },
      { kind: "event", title: "", url: "https://example.com/b" },
      { kind: "event", title: "no url", url: "" },
      { kind: "event", title: "js url", url: "javascript:alert(1)" },
      { kind: "mystery", title: "bad kind", url: "https://example.com/c" },
      "not an object",
      ...Array.from({ length: 30 }, (_, i) => ({
        kind: "social",
        title: `s${i}`,
        url: `https://example.com/${i}`,
      })),
    ];
    const { signals, errors } = sanitizeSignals(junk);
    assert.equal(signals.length, 20); // capped
    assert.equal(signals[0].url, "https://example.com/a");
    assert.ok(errors.length >= 5);
    assert.ok(signals.every((s) => /^https?:\/\//.test(s.url)));
  });

  it("drops unparseable dates instead of poisoning scoring", () => {
    const { signals } = sanitizeSignals([
      { kind: "event", title: "t", url: "https://example.com/a", eventAt: "next friday" },
    ]);
    assert.equal(signals[0].eventAt, undefined);
  });
});

describe("shouldDeliverFirstContact", () => {
  it("is a one-shot", () => {
    assert.deepEqual(shouldDeliverFirstContact({ localHour: 14, alreadyDelivered: true }), {
      ok: false,
      reason: "already_delivered",
    });
  });

  it("respects quiet hours across midnight", () => {
    assert.equal(shouldDeliverFirstContact({ localHour: 23, alreadyDelivered: false }).ok, false);
    assert.equal(shouldDeliverFirstContact({ localHour: 3, alreadyDelivered: false }).ok, false);
    assert.equal(shouldDeliverFirstContact({ localHour: 8, alreadyDelivered: false }).ok, true);
    assert.equal(shouldDeliverFirstContact({ localHour: 14, alreadyDelivered: false }).ok, true);
  });
});
