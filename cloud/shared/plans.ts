/**
 * Plans of the hosted relay. autumn.config.ts pushes them to Autumn, which enforces and bills
 * them; the website shows the same numbers. Local use and the self-hosted relay have no limits.
 */

/** Autumn feature IDs. */
export const FEATURES = {
  /** Agent requests forwarded to a Mac. Consumable, resets monthly. */
  requests: "relay_requests",
  /** Seconds in which a Mac had at least one request in flight. Consumable, resets monthly. */
  activeSeconds: "relay_active_seconds",
  /** Macs connected at the same time. Not tracked in Autumn; the relay counts them. */
  macs: "macs",
} as const;

export interface Plan {
  id: "free" | "pro";
  name: string;
  /** Monthly price in US dollars; 0 for free. */
  priceUsd: number;
  macs: number;
  requests: number;
  activeHours: number;
}

export const FREE_PLAN: Plan = { id: "free", name: "Free", priceUsd: 0, macs: 1, requests: 20_000, activeHours: 10 };
export const PRO_PLAN: Plan = { id: "pro", name: "Pro", priceUsd: 9, macs: 3, requests: 1_000_000, activeHours: 300 };
export const PLANS = [FREE_PLAN, PRO_PLAN] as const;

export function planById(id: string | null | undefined): Plan | null {
  return PLANS.find((plan) => plan.id === id) ?? null;
}
