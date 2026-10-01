import { createServerFn } from "@tanstack/react-start";
import { getAuth } from "@workos/authkit-tanstack-react-start";
import { env } from "cloudflare:workers";
import { getGT } from "gt-tanstack-start";
import { carryOverUsage, removeAccount } from "../../shared/accounts";
import { Autumn, currentSubscription, type Customer } from "../../shared/autumn";
import { UserError } from "../../shared/errors";
import { FEATURES, FREE_PLAN, PLANS, PRO_PLAN, planById, type Plan } from "../../shared/plans";
import { hasRelayPlan } from "../../relay/src/billing";
import { authConfigured } from "./auth-config";
import {
  createAccessToken,
  deleteAccessToken,
  forgetHost,
  listAccessTokens,
  listHosts,
  recordHostOffline,
  upsertAccount,
  type AccessTokenRow,
  type HostRow,
} from "../../shared/db";

interface RelayAdmin {
  connected(spaceIds: string[]): Promise<Record<string, string[]>>;
  disconnectToken(tokenId: string, spaceIds: string[]): Promise<number>;
}

const relay = () => env.RELAY as unknown as RelayAdmin;

// Errors a server function throws for the dashboard to show are in the language of the request,
// which General Translation resolves from its cookie; errors only logged stay English.

/** An error from shared/, which only speaks English, in the language of the request. */
async function translated(error: unknown): Promise<unknown> {
  if (!(error instanceof UserError)) return error;
  const gt = await getGT();
  switch (error.reason) {
    case "billing-unreachable":
      return new Error(gt("Billing could not be reached, so nothing was deleted. Try again in a moment."));
    case "billing-record":
      return new Error(gt("Your billing record could not be deleted, so nothing was deleted. Try again in a moment."));
    case "paid-plan":
      return new Error(gt("Cancel {plan} under “Manage billing” first, then delete your account.", { plan: String(error.value) }));
    case "token-limit":
      return new Error(gt("You can have at most {count} access tokens.", { count: Number(error.value) }));
  }
}

async function requireUser() {
  const { user } = await getAuth();
  if (!user) {
    const gt = await getGT();
    throw new Error(gt("Not signed in."));
  }
  return user;
}

/**
 * Drops Macs connected with a revoked token. The token is already gone, so a failure only delays
 * it: the relay also drops a connection whose token is gone at its next request (TOKEN_RECHECK_MS).
 */
async function disconnect(tokenId: string, spaceIds: string[]): Promise<void> {
  if (spaceIds.length === 0) return;
  try {
    await relay().disconnectToken(tokenId, spaceIds);
  } catch (error) {
    console.warn("could not reach the relay to disconnect Macs", error);
  }
}

/** Marks Macs offline that D1 still lists as online but the relay no longer holds. */
async function reconcile(hosts: HostRow[]): Promise<HostRow[]> {
  const online = hosts.filter((host) => host.online === 1);
  if (online.length === 0) return hosts;
  let connected: Record<string, string[]>;
  try {
    connected = await relay().connected([...new Set(online.map((host) => host.space_id))]);
  } catch {
    return hosts; // Relay unreachable: show what D1 knows.
  }
  const gone = online.filter((host) => !connected[host.space_id]?.includes(host.name));
  // Only the connection seen here: a Mac that reconnected meanwhile has another connected_at.
  const stale: HostRow[] = [];
  for (const host of gone) {
    if (await recordHostOffline(env.DB, host.space_id, host.name, host.connected_at)) stale.push(host);
  }
  return hosts.map((host) => (stale.includes(host) ? { ...host, online: 0, disconnected_at: Date.now() } : host));
}

/** Autumn holds plans and usage. Without its key the hosted relay is not billed. */
function autumn(): Autumn | null {
  return env.AUTUMN_SECRET_KEY ? new Autumn(env.AUTUMN_SECRET_KEY) : null;
}

/** The site's public origin. The WorkOS redirect URI is set per environment, so it has the right one. */
function siteOrigin(): string {
  return new URL(env.WORKOS_REDIRECT_URI).origin;
}

export interface Allowance {
  used: number;
  granted: number;
  unlimited: boolean;
}

export interface BillingData {
  plan: Plan;
  /** When a canceled paid plan ends, or null. */
  endsAt: number | null;
  pastDue: boolean;
  /** When the monthly allowance renews. */
  resetsAt: number | null;
  requests: Allowance;
  activeSeconds: Allowance;
  macs: number;
}

function allowance(customer: Customer, feature: string): Allowance {
  const balance = customer.balances[feature];
  return { used: balance?.usage ?? 0, granted: balance?.granted ?? 0, unlimited: balance?.unlimited ?? false };
}

function billingData(customer: Customer): BillingData {
  const subscription = currentSubscription(customer, PLANS.map((plan) => plan.id));
  return {
    plan: planById(subscription?.plan_id) ?? FREE_PLAN,
    endsAt: subscription?.canceled_at ? subscription.current_period_end : null,
    pastDue: subscription?.past_due ?? false,
    resetsAt: customer.balances[FEATURES.requests]?.next_reset_at ?? null,
    requests: allowance(customer, FEATURES.requests),
    activeSeconds: allowance(customer, FEATURES.activeSeconds),
    macs: customer.balances[FEATURES.macs]?.granted ?? 0,
  };
}

export interface DashboardData {
  user: { email: string; firstName: string | null };
  tokens: AccessTokenRow[];
  hosts: HostRow[];
  relayUrl: string;
  /** "off" when the relay is not billed, "unavailable" when Autumn could not be read. */
  billing: BillingData | "off" | "unavailable";
}

export type DashboardState = { state: "unconfigured" } | { state: "signed-out" } | ({ state: "ready" } & DashboardData);

async function loadBilling(user: { id: string; email: string }): Promise<DashboardData["billing"]> {
  const client = autumn();
  if (!client) return "off";
  try {
    // So the usage shown includes a deleted account's; createToken insists on it.
    await carryOverUsage(env.DB, client, user).catch((error: unknown) =>
      console.warn("could not carry over the usage of a deleted account", error),
    );
    const customer = await client.customer(user.id, user.email);
    if (!hasRelayPlan(customer)) {
      console.warn("Autumn has no relay plan for this account; push autumn.config.ts");
      return "unavailable";
    }
    return billingData(customer);
  } catch (error) {
    console.warn("could not read the plan from Autumn", error);
    return "unavailable";
  }
}

export const loadDashboard = createServerFn({ method: "GET" }).handler(async (): Promise<DashboardState> => {
  if (!authConfigured()) return { state: "unconfigured" };
  const { user } = await getAuth();
  if (!user) return { state: "signed-out" };
  await upsertAccount(env.DB, user.id, user.email);
  const [tokens, hosts, billing] = await Promise.all([
    listAccessTokens(env.DB, user.id),
    listHosts(env.DB, user.id),
    loadBilling(user),
  ]);
  return {
    state: "ready",
    user: { email: user.email, firstName: user.firstName ?? null },
    tokens,
    hosts: await reconcile(hosts),
    relayUrl: env.RELAY_URL,
    billing,
  };
});

/** Starts the upgrade to Pro. Returns Stripe Checkout's URL, or null if nothing was left to pay. */
export const upgradePlan = createServerFn({ method: "POST" }).handler(async () => {
  const user = await requireUser();
  const gt = await getGT();
  const client = autumn();
  if (!client) throw new Error(gt("Billing is not set up."));
  await client.customer(user.id, user.email);
  return { url: await client.attach(user.id, PRO_PLAN.id, `${siteOrigin()}/dashboard?upgraded=1`) };
});

/** Stripe's billing portal: invoices, payment method, cancelling. */
export const openBillingPortal = createServerFn({ method: "POST" }).handler(async () => {
  const user = await requireUser();
  const gt = await getGT();
  const client = autumn();
  if (!client) throw new Error(gt("Billing is not set up."));
  return { url: await client.portal(user.id, `${siteOrigin()}/dashboard`) };
});

export const createToken = createServerFn({ method: "POST" })
  .validator((data: { name: string }) => ({ name: String(data?.name ?? "").slice(0, 60) }))
  .handler(async ({ data }) => {
    const user = await requireUser();
    const gt = await getGT();
    await upsertAccount(env.DB, user.id, user.email);
    const client = autumn();
    if (client) {
      // A deleted account's usage counts before the new one can use the relay.
      try {
        await carryOverUsage(env.DB, client, user);
      } catch (error) {
        console.warn("could not carry over the usage of a deleted account", error);
        throw new Error(gt("Billing could not be reached, so no token was created. Try again in a moment."));
      }
    }
    const { row, token } = await createAccessToken(env.DB, user.id, data.name).catch(async (error: unknown) => {
      throw await translated(error);
    });
    return { id: row.id, name: row.name, token };
  });

export const revokeToken = createServerFn({ method: "POST" })
  .validator((data: { id: string }) => ({ id: String(data?.id ?? "") }))
  .handler(async ({ data }) => {
    const user = await requireUser();
    await disconnect(data.id, await deleteAccessToken(env.DB, user.id, data.id));
    return { ok: true };
  });

export const forgetMac = createServerFn({ method: "POST" })
  .validator((data: { spaceId: string; name: string }) => ({
    spaceId: String(data?.spaceId ?? ""),
    name: String(data?.name ?? ""),
  }))
  .handler(async ({ data }) => {
    const user = await requireUser();
    await forgetHost(env.DB, user.id, data.spaceId, data.name);
    return { ok: true };
  });

/** Deletes the account everywhere; see removeAccount for the order. Signing out is up to the page. */
export const deleteAccount = createServerFn({ method: "POST" }).handler(async () => {
  const user = await requireUser();
  await removeAccount(env.DB, autumn(), user, disconnect).catch(async (error: unknown) => {
    throw await translated(error);
  });
  return { ok: true };
});
