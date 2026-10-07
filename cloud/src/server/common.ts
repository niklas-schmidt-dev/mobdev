import { getAuth } from "@workos/authkit-tanstack-react-start";
import { env } from "cloudflare:workers";
import { getGT } from "gt-tanstack-start";
import { UserError } from "../../shared/errors";
import type { LiveGrant } from "../../shared/live";

// Helpers for the server functions in dashboard.ts and live.ts. Only their handlers may use these:
// the build drops handlers, and with them these imports, from the browser's bundle.

/** The relay worker's RelayAdmin entrypoint (relay/src/index.ts), reached over a service binding. */
interface RelayAdmin {
  connected(spaceIds: string[]): Promise<Record<string, string[]>>;
  disconnectToken(tokenId: string, spaceIds: string[]): Promise<number>;
  liveTicket(spaceId: string, grant: LiveGrant): Promise<{ ticket: string } | { error: "offline" | "busy" }>;
  endShare(spaceId: string, shareId: string): Promise<number>;
}

export const relay = () => env.RELAY as unknown as RelayAdmin;

// Errors a server function throws for the dashboard to show are in the language of the request,
// which General Translation resolves from its cookie; errors only logged stay English.

/** An error from shared/, which only speaks English, in the language of the request. */
export async function translated(error: unknown): Promise<unknown> {
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
    case "share-limit":
      return new Error(gt("You can have at most {count} share links. Revoke one first.", { count: Number(error.value) }));
  }
}

export async function requireUser() {
  const { user } = await getAuth();
  if (!user) {
    const gt = await getGT();
    throw new Error(gt("Not signed in."));
  }
  return user;
}

/** The site's public origin. The WorkOS redirect URI is set per environment, so it has the right one. */
export function siteOrigin(): string {
  return new URL(env.WORKOS_REDIRECT_URI).origin;
}
