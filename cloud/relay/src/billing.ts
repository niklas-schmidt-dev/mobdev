import { Autumn, type Balance, type Customer } from "../../shared/autumn";
import { FEATURES } from "../../shared/plans";
import { DASHBOARD_URL } from "./protocol";

/**
 * What an account may still use in the current period, as Autumn last reported it. The relay
 * subtracts what it counted since. Null means unlimited.
 */
export interface Quota {
  requests: number | null;
  seconds: number | null;
  /** When the allowance renews. After that the relay lets requests through until Autumn answers again. */
  resetsAt: number | null;
  checkedAt: number;
}

export function autumnFor(env: { AUTUMN_SECRET_KEY?: string }): Autumn | null {
  return env.AUTUMN_SECRET_KEY ? new Autumn(env.AUTUMN_SECRET_KEY) : null;
}

/** A missing balance means the plan does not include the feature. */
function remaining(balance: Balance | undefined): number | null {
  if (!balance) return 0;
  return balance.unlimited ? null : Math.max(0, balance.remaining);
}

export function quotaFromCustomer(customer: Customer, now = Date.now()): Quota {
  const requests = customer.balances[FEATURES.requests];
  const seconds = customer.balances[FEATURES.activeSeconds];
  const resets = [requests?.next_reset_at, seconds?.next_reset_at].filter((at): at is number => typeof at === "number");
  return {
    requests: remaining(requests),
    seconds: remaining(seconds),
    resetsAt: resets.length ? Math.min(...resets) : null,
    checkedAt: now,
  };
}

/** The quota after Autumn reported one feature's balance, e.g. in answer to tracking usage. */
export function withBalance(quota: Quota | null, balance: Balance, now = Date.now()): Quota | null {
  if (!quota) return null; // Unknown until the whole account has been read once.
  const next = { ...quota, checkedAt: now };
  if (balance.feature_id === FEATURES.requests) next.requests = remaining(balance);
  else if (balance.feature_id === FEATURES.activeSeconds) next.seconds = remaining(balance);
  else return quota;
  if (balance.next_reset_at) next.resetsAt = balance.next_reset_at;
  return next;
}

/**
 * Whether Autumn has one of the relay's plans for the customer. Every customer gets Free
 * automatically, so a customer without one means the plans were never pushed to this Autumn
 * environment. The relay then treats Autumn like unreachable instead of locking everyone out.
 */
export function hasRelayPlan(customer: Customer): boolean {
  return customer.balances[FEATURES.macs] !== undefined || customer.balances[FEATURES.requests] !== undefined;
}

/** How many Macs the plan lets the account connect at once. */
export function macsAllowed(customer: Customer): number {
  const balance = customer.balances[FEATURES.macs];
  if (!balance) return 0;
  return balance.unlimited ? Number.POSITIVE_INFINITY : balance.granted;
}

/**
 * Why a request has to wait for the next period, or null if the allowance has room for it.
 * `used` is what the relay counted but Autumn has not yet confirmed.
 */
export function exhausted(
  quota: Quota | null,
  used: { requests: number; seconds: number },
  now = Date.now(),
): { message: string; retryAfter: number } | null {
  if (!quota) return null;
  if (quota.resetsAt !== null && now >= quota.resetsAt) return null;
  let what: string | null = null;
  if (quota.requests !== null && quota.requests - used.requests <= 0) what = "requests";
  else if (quota.seconds !== null && quota.seconds - used.seconds <= 0) what = "active time";
  if (!what) return null;
  const until = quota.resetsAt ? ` until ${new Date(quota.resetsAt).toISOString().slice(0, 10)}` : "";
  return {
    message: `this account used up its hosted relay ${what}${until}. Upgrade at ${DASHBOARD_URL}. Mobdev on the Mac itself has no limits.`,
    retryAfter: quota.resetsAt ? Math.max(1, Math.ceil((quota.resetsAt - now) / 1000)) : 3600,
  };
}
