import { createServerFn } from "@tanstack/react-start";
import { getAuth } from "@workos/authkit-tanstack-react-start";
import { env } from "cloudflare:workers";
import {
  createAccessToken,
  deleteAccessToken,
  forgetHost,
  listAccessTokens,
  listHosts,
  upsertAccount,
  type AccessTokenRow,
  type HostRow,
} from "../../shared/db";

interface RelayAdmin {
  disconnectToken(tokenId: string, spaceIds: string[]): Promise<number>;
}

async function requireUser() {
  const { user } = await getAuth();
  if (!user) throw new Error("Not signed in.");
  return user;
}

/** Drops Macs connected with a revoked token. The token is already gone, so a failure only delays it. */
async function disconnect(tokenId: string, spaceIds: string[]): Promise<void> {
  if (spaceIds.length === 0) return;
  try {
    await (env.RELAY as unknown as RelayAdmin).disconnectToken(tokenId, spaceIds);
  } catch (error) {
    console.warn("could not reach the relay to disconnect Macs", error);
  }
}

export interface DashboardData {
  user: { email: string; firstName: string | null };
  tokens: AccessTokenRow[];
  hosts: HostRow[];
  relayUrl: string;
}

export const loadDashboard = createServerFn({ method: "GET" }).handler(async (): Promise<DashboardData | null> => {
  const { user } = await getAuth();
  if (!user) return null;
  await upsertAccount(env.DB, user.id, user.email);
  const [tokens, hosts] = await Promise.all([listAccessTokens(env.DB, user.id), listHosts(env.DB, user.id)]);
  return { user: { email: user.email, firstName: user.firstName ?? null }, tokens, hosts, relayUrl: env.RELAY_URL };
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
  const tokens = await listAccessTokens(env.DB, user.id);
  for (const token of tokens) await disconnect(token.id, await deleteAccessToken(env.DB, user.id, token.id));
  await env.DB.batch([
    env.DB.prepare("DELETE FROM hosts WHERE account_id = ?1").bind(user.id),
    env.DB.prepare("DELETE FROM accounts WHERE id = ?1").bind(user.id),
  ]);
  return { ok: true };
});
