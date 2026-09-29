import { createServerFn } from "@tanstack/react-start";
import { getAuth } from "@workos/authkit-tanstack-react-start";
import { env } from "cloudflare:workers";
import { Autumn, currentSubscription, type Customer } from "../../shared/autumn";
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

async function requireUser() {
  const { user } = await getAuth();
  if (!user) throw new Error("Not signed in.");
  return user;
}

/** Drops Macs connected with a revoked token. The token is already gone, so a failure only delays it. */
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
  const stale = online.filter((host) => !connected[host.space_id]?.includes(host.name));
  for (const host of stale) await recordHostOffline(env.DB, host.space_id, host.name);
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
  const client = autumn();
  if (!client) throw new Error("Billing is not set up.");
  await client.customer(user.id, user.email);
  return { url: await client.attach(user.id, PRO_PLAN.id, `${siteOrigin()}/dashboard?upgraded=1`) };
});

/** Stripe's billing portal: invoices, payment method, cancelling. */
export const openBillingPortal = createServerFn({ method: "POST" }).handler(async () => {
  const user = await requireUser();
  const client = autumn();
  if (!client) throw new Error("Billing is not set up.");
  return { url: await client.portal(user.id, `${siteOrigin()}/dashboard`) };
});

export const createToken = createServerFn({ method: "POST" })
  .validator((data: { name: string }) => ({ name: String(data?.name ?? "").slice(0, 60) }))
  .handler(async ({ data }) => {
    const user = await requireUser();
    await upsertAccount(env.DB, user.id, user.email);
    const { row, token } = await createAccessToken(env.DB, user.id, data.name);
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

export const deleteAccount = createServerFn({ method: "POST" }).handler(async () => {
  const user = await requireUser();
  const client = autumn();
  if (client) {
    // A running subscription would keep charging an account that no longer exists.
    const billing = billingData(await client.customer(user.id, user.email));
    if (billing.plan.priceUsd > 0 && billing.endsAt === null) {
      throw new Error(`Cancel ${billing.plan.name} under “Manage billing” first, then delete your account.`);
    }
  }
  const tokens = await listAccessTokens(env.DB, user.id);
  for (const token of tokens) await disconnect(token.id, await deleteAccessToken(env.DB, user.id, token.id));
  await env.DB.batch([
    env.DB.prepare("DELETE FROM hosts WHERE account_id = ?1").bind(user.id),
    env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(user.id),
  ]);
  if (client) {
    try {
      await client.deleteCustomer(user.id); // Stripe keeps its invoices; tax law requires them.
    } catch (error) {
      console.warn("could not delete the Autumn customer", error);
    }
  }
  return { ok: true };
});
