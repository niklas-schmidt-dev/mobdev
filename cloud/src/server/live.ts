import { createServerFn } from "@tanstack/react-start";
import { getAuth } from "@workos/authkit-tanstack-react-start";
import { env } from "cloudflare:workers";
import { getGT } from "gt-tanstack-start";
import { listHosts } from "../../shared/db";
import type { Device } from "../../shared/devices";
import type { LiveGrant, LiveMode } from "../../shared/live";
import { createShare, deleteShare, listShares, openShare, type ShareRow } from "../../shared/shares";
import { authConfigured } from "./auth-config";
import { relay, requireUser, siteOrigin, translated } from "./common";

// Live view in the browser. The page asks one of these for a ticket before each connection; the
// relay mints it (RelayAdmin.liveTicket) for exactly the Mac, device and mode decided here, and the
// browser hands it to the relay as a WebSocket subprotocol (components/live.tsx).

/** A ticket and where to use it, or why there is none. */
export type TicketResult =
  | { relayUrl: string; ticket: string }
  | { error: "offline" | "busy" | "expired" | "invalid" | "unreachable" };

async function mint(spaceId: string, grant: LiveGrant): Promise<TicketResult> {
  try {
    const result = await relay().liveTicket(spaceId, grant);
    return "error" in result ? { error: result.error } : { relayUrl: env.RELAY_URL, ticket: result.ticket };
  } catch (error) {
    console.warn("could not reach the relay for a live view ticket", error);
    return { error: "unreachable" };
  }
}

interface Target {
  spaceId: string;
  mac: string;
  device: string;
}

function target(data: Partial<Target> | undefined): Target {
  return {
    spaceId: String(data?.spaceId ?? "").slice(0, 64),
    mac: String(data?.mac ?? "").slice(0, 64),
    device: String(data?.device ?? "").slice(0, 200),
  };
}

export type LivePageState =
  | { state: "unconfigured" }
  | { state: "signed-out" }
  | { state: "unknown" }
  | {
      state: "ready";
      spaceId: string;
      mac: string;
      online: boolean;
      deviceId: string;
      /** As the Mac last reported it; null when it did not. */
      device: Device | null;
      /** The links to this Mac. */
      shares: ShareRow[];
      loadedAt: number;
    };

/** The owner's live page of one of their Macs' devices. */
export const loadLive = createServerFn({ method: "GET" })
  .validator(target)
  .handler(async ({ data }): Promise<LivePageState> => {
    if (!authConfigured()) return { state: "unconfigured" };
    const { user } = await getAuth();
    if (!user) return { state: "signed-out" };
    const host = (await listHosts(env.DB, user.id)).find((row) => row.space_id === data.spaceId && row.name === data.mac);
    if (!host) return { state: "unknown" };
    const shares = (await listShares(env.DB, user.id)).filter(
      (share) => share.space_id === host.space_id && share.mac === host.name,
    );
    return {
      state: "ready",
      spaceId: host.space_id,
      mac: host.name,
      online: host.online === 1,
      deviceId: data.device,
      device: host.devices.find((device) => device.id === data.device) ?? null,
      shares,
      loadedAt: Date.now(),
    };
  });

/** A ticket for the signed-in owner, who may watch and control any device of their Macs. */
export const ownerTicket = createServerFn({ method: "POST" })
  .validator(target)
  .handler(async ({ data }): Promise<TicketResult> => {
    const user = await requireUser();
    const owned = await env.DB.prepare("SELECT 1 FROM hosts WHERE account_id = ?1 AND space_id = ?2 AND name = ?3")
      .bind(user.id, data.spaceId, data.mac)
      .first();
    if (!owned) return { error: "invalid" };
    return mint(data.spaceId, {
      mac: data.mac,
      device: data.device,
      mode: "control",
      viewer: { kind: "owner", label: null },
      shareId: null,
      endsAt: null,
    });
  });

export const createShareLink = createServerFn({ method: "POST" })
  .validator(
    (data: Target & { wholeMac: boolean; mode: LiveMode; label: string; hours: number }) => ({
      ...target(data),
      wholeMac: data?.wholeMac === true,
      mode: data?.mode === "control" ? ("control" as const) : ("view" as const),
      label: String(data?.label ?? "").slice(0, 60),
      hours: Number(data?.hours) || 24,
    }),
  )
  .handler(async ({ data }) => {
    const user = await requireUser();
    const gt = await getGT();
    const created = await createShare(env.DB, user.id, {
      spaceId: data.spaceId,
      mac: data.mac,
      device: data.wholeMac ? null : data.device,
      mode: data.mode,
      label: data.label || gt("Shared view"),
      hours: data.hours,
    }).catch(async (error: unknown) => {
      throw await translated(error);
    });
    if (!created) throw new Error(gt("This Mac is not in your account."));
    return { share: created.row, url: `${siteOrigin()}/live/${created.token}` };
  });

/** Deletes a link and ends the views opened with it. */
export const revokeShareLink = createServerFn({ method: "POST" })
  .validator((data: { id: string }) => ({ id: String(data?.id ?? "").slice(0, 40) }))
  .handler(async ({ data }) => {
    const user = await requireUser();
    const share = await deleteShare(env.DB, user.id, data.id);
    if (share) {
      // The relay also finds the link gone at its next check, within LIVE_RENEW_MS.
      await relay()
        .endShare(share.space_id, share.id)
        .catch((error: unknown) => console.warn("could not reach the relay to end a share link's views", error));
    }
    return { ok: true };
  });

export type SharePageState =
  | { state: "invalid" }
  | { state: "expired" }
  | {
      state: "ready";
      mac: string;
      label: string;
      mode: LiveMode;
      expiresAt: number;
      online: boolean;
      devices: Device[];
      loadedAt: number;
    };

const shareToken = (data: { token: string }) => ({ token: String(data?.token ?? "").slice(0, 80) });

/** What a share link shows; no account needed. */
export const loadShare = createServerFn({ method: "GET" })
  .validator(shareToken)
  .handler(async ({ data }): Promise<SharePageState> => {
    const opened = await openShare(env.DB, data.token);
    if (!opened) return { state: "invalid" };
    const { share, online, devices } = opened;
    const now = Date.now();
    if (share.expires_at <= now) return { state: "expired" };
    return { state: "ready", mac: share.mac, label: share.label, mode: share.mode, expiresAt: share.expires_at, online, devices, loadedAt: now };
  });

/** A ticket for one device a share link shows, in the link's mode and until it expires. */
export const shareTicket = createServerFn({ method: "POST" })
  .validator((data: { token: string; device: string }) => ({
    ...shareToken(data),
    device: String(data?.device ?? "").slice(0, 200),
  }))
  .handler(async ({ data }): Promise<TicketResult> => {
    const opened = await openShare(env.DB, data.token);
    if (!opened) return { error: "invalid" };
    const { share, devices } = opened;
    if (share.expires_at <= Date.now()) return { error: "expired" };
    if (share.device !== null && share.device !== data.device) return { error: "invalid" };
    if (!devices.some((device) => device.id === data.device)) return { error: "offline" };
    return mint(share.space_id, {
      mac: share.mac,
      device: data.device,
      mode: share.mode,
      viewer: { kind: "share", label: share.label },
      shareId: share.id,
      endsAt: share.expires_at,
    });
  });
