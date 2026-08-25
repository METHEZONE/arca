/**
 * Plan limits for the published $0 / $19 / $99 tiers.
 *
 * The marketing page (app/arca/page.tsx TIERS) only publishes feature lists,
 * not hard numbers, except "50 delegations / month" on the free tier and
 * "unlimited" on the two paid tiers. These limits are this task's own
 * reasonable-default assumption where the real number isn't published —
 * flagged in the final report so it can be corrected with the actual
 * intended numbers:
 *
 *  - free ("Companion", $0): 50 requests/month, matching the one published
 *    number on the pricing page.
 *  - pro ("Second Self", $19): marketed as unlimited delegation, but a
 *    metered backend still needs a ceiling so a compromised or runaway
 *    account can't produce unbounded provider spend. 2,000/month is a
 *    generous "effectively unlimited" cap for a single user.
 *  - team ("ZONE for Teams", $99/seat): 5,000/month, scaled up for
 *    plausible team-wide usage on top of the same per-seat pricing.
 *
 * Rate limits (independent of the monthly quota) exist purely to blunt a
 * single runaway client hammering the API within a short window.
 */

export type Plan = "free" | "pro" | "team";

export interface PlanLimits {
  /** Combined chat + transcribe requests allowed per calendar month. */
  monthlyRequests: number;
  /** Combined chat + transcribe requests allowed per rolling minute. */
  requestsPerMinute: number;
}

export const PLAN_LIMITS: Record<Plan, PlanLimits> = {
  free: { monthlyRequests: 50, requestsPerMinute: 10 },
  pro: { monthlyRequests: 2000, requestsPerMinute: 30 },
  team: { monthlyRequests: 5000, requestsPerMinute: 60 },
};

export function limitsFor(plan: Plan): PlanLimits {
  return PLAN_LIMITS[plan];
}
