// The hosted relay's plans in Autumn. Preview with `bunx atmn push`, apply with `bunx atmn push --yes`
// (add `--prod` for production). Prices are in the organization's default currency, USD.
import { atmn, feature, plan, type Plan } from "atmn";
import { FEATURES, FREE_PLAN, PRO_PLAN, type Plan as RelayPlan } from "./shared/plans";

export const relayRequests = feature({
  featureId: FEATURES.requests,
  name: "Relay requests",
  type: "metered",
  consumable: true,
});

export const relayActiveSeconds = feature({
  featureId: FEATURES.activeSeconds,
  name: "Relay active seconds",
  type: "metered",
  consumable: true,
});

export const macs = feature({
  featureId: FEATURES.macs,
  name: "Connected Macs",
  type: "metered",
  consumable: false,
});

function items(limits: RelayPlan): NonNullable<Plan["items"]> {
  return [
    { featureId: FEATURES.requests, included: limits.requests, reset: { interval: "month" } },
    { featureId: FEATURES.activeSeconds, included: limits.activeHours * 3600, reset: { interval: "month" } },
    { featureId: FEATURES.macs, included: limits.macs },
  ];
}

// Changing a plan's items means a new version: a new versionSlug, active on it and off on the old one.
export const free = plan({
  planId: FREE_PLAN.id,
  versionSlug: "v1",
  name: FREE_PLAN.name,
  group: "relay",
  active: true,
  autoEnable: true,
  items: items(FREE_PLAN),
});

export const pro = plan({
  planId: PRO_PLAN.id,
  versionSlug: "v1",
  name: PRO_PLAN.name,
  group: "relay",
  active: true,
  price: { amount: PRO_PLAN.priceUsd, interval: "month" },
  items: items(PRO_PLAN),
});

// Before pushing to production, configure Stripe Tax with active registrations and tax-exclusive prices.
export default atmn({
  features: [relayRequests, relayActiveSeconds, macs],
  plans: [free, pro],
  settings: { automaticTax: true },
});
