import { DurableObject } from "cloudflare:workers";
import type { Autumn, Balance } from "../../shared/autumn";
import { accessTokenExists, recordHostDevices, recordHostOffline, recordHostOnline } from "../../shared/db";
import { devicesFromFrame, type Device, type MacDevices } from "../../shared/devices";
import { randomHex, sha256Hex } from "../../shared/keys";
import {
  LIVE_CLOSE,
  LIVE_MAX_FPS,
  LIVE_MAX_FRAME_BYTES,
  LIVE_MAX_INPUTS_PER_SECOND,
  LIVE_MAX_TICKETS,
  LIVE_MAX_UNACKED,
  LIVE_MAX_VIEWERS_PER_MAC,
  LIVE_RENEW_MS,
  LIVE_SUBPROTOCOL,
  LIVE_TICKET_MS,
  LIVE_VIEWER_IDLE_MS,
  closeReason,
  normalizeLiveInput,
  ticketSecret,
  type LiveGrant,
  type LiveMode,
  type LiveViewer,
} from "../../shared/live";
import { FEATURES } from "../../shared/plans";
import { existingShares } from "../../shared/shares";
import { autumnFor, exhausted, hasRelayPlan, quotaFromCustomer, withBalance, type Quota } from "./billing";
import {
  CLOSE_REPLACED,
  CLOSE_REVOKED,
  DASHBOARD_URL,
  MAX_HOSTS_PER_SPACE,
  MAX_IN_FLIGHT_PER_MAC,
  MAX_ONLINE_HOSTS_PER_ACCOUNT,
  QUOTA_REFRESH_MS,
  REQUEST_TIMEOUT_MS,
  TOKEN_RECHECK_MS,
  USAGE_FLUSH_MS,
  USAGE_RETRY_MS,
  errorResponse,
  jsonError,
  macLimitError,
  type RelayRequest,
  type RelayResponse,
} from "./protocol";
import type { RelayEnv } from "./env";

/**
 * What one connection used that Autumn has not confirmed yet: agent requests and live view inputs,
 * and milliseconds with at least one request in flight or someone watching the Mac live (busy).
 * `batch` is on its way to Autumn while the counters go on.
 * The meter lives in the socket's attachment, so it survives hibernation, and moves to storage
 * when the Mac disconnects, until Autumn confirms it.
 */
interface Meter {
  /** With `seq`, the idempotency key for Autumn, so a retried batch never counts twice. */
  id: string;
  accountId: string;
  requests: number;
  activeMs: number;
  seq: number;
  batch: { requests: number; seconds: number } | null;
}

interface Attachment {
  name: string;
  spaceId: string;
  accountId: string;
  tokenId: string;
  /** Also `hosts.connected_at` in D1, so a disconnect only marks this connection offline. */
  connectedAt: number;
  /** When D1 last confirmed that the access token exists; see TOKEN_RECHECK_MS. */
  tokenCheckedAt: number;
  /** Null when the relay does not bill (no Autumn key). */
  meter: Meter | null;
  /** The account's allowance; null until Autumn could be read, and requests pass meanwhile. */
  quota: Quota | null;
}

/**
 * A live view's socket (shared/live.ts). Viewers are hibernatable WebSockets of the same space,
 * tagged "viewer" and "viewer:<mac>", so getWebSockets(<mac name>) still finds only Macs.
 */
interface ViewerAttachment {
  viewer: true;
  mac: string;
  /** The Mac connection it watches; a new connection of the same Mac starts over. */
  macConnectedAt: number;
  device: string;
  /** The stream it shares with the other viewers of the device; the Mac's frames carry its id. */
  stream: string;
  fps: number;
  mode: LiveMode;
  who: LiveViewer;
  shareId: string | null;
  endsAt: number | null;
  joinedAt: number;
}

/** What the relay worker asks for when a viewer connects (X-Mobdev-Live). */
export interface LiveConnect {
  /** The Mac, from /h/<mac>/ or X-Mobdev-Host; null for the only one. Tickets name their own. */
  name: string | null;
  device: string;
  fps: number;
  ticket: string | null;
  /** The viewer offered the live subprotocol (browsers), which the answer must then name. */
  protocol: boolean;
}

/** An unused ticket under `ticket:<sha256 of its secret>`. */
interface StoredTicket {
  grant: LiveGrant;
  expiresAt: number;
}

const TICKET_PREFIX = "ticket:";
const viewerTag = (mac: string) => `viewer:${mac}`;

function macOf(socket: WebSocket): Attachment | null {
  const attachment = socket.deserializeAttachment() as Attachment | ViewerAttachment | null;
  return attachment && !("viewer" in attachment) ? attachment : null;
}

function viewerOf(socket: WebSocket): ViewerAttachment | null {
  const attachment = socket.deserializeAttachment() as Attachment | ViewerAttachment | null;
  return attachment && "viewer" in attachment ? attachment : null;
}

/** Flow control of one viewer, in memory: a viewer that outlives a hibernation starts afresh. */
interface Flow {
  /** Frames sent and not acknowledged, by seq. */
  sent: number[];
  /** When its last inputs arrived, for LIVE_MAX_INPUTS_PER_SECOND. */
  inputs: number[];
  /** When it last sent anything; "ping" shows in getWebSocketAutoResponseTimestamp instead. */
  seen: number;
}

const METER_PREFIX = "meter:";

/** What Autumn has not confirmed yet, plus `busyMs` of requests still in flight. */
function unconfirmed(meter: Meter, busyMs = 0): { requests: number; seconds: number } {
  return {
    requests: meter.requests + (meter.batch?.requests ?? 0),
    seconds: Math.floor((meter.activeMs + busyMs) / 1000) + (meter.batch?.seconds ?? 0),
  };
}

/** Moves the counters into a batch unless one is already waiting. False when there is nothing to send. */
function takeBatch(meter: Meter): boolean {
  if (meter.batch) return true;
  const seconds = Math.floor(meter.activeMs / 1000);
  if (meter.requests === 0 && seconds === 0) return false;
  meter.batch = { requests: meter.requests, seconds };
  meter.requests = 0;
  meter.activeMs -= seconds * 1000;
  return true;
}

interface Pending {
  resolve: (response: RelayResponse) => void;
  timer: ReturnType<typeof setTimeout>;
  socket: WebSocket;
}

/**
 * The latest device list of a connected Mac, in storage under `devices:<name>` so it survives
 * hibernation. Dropped when the Mac disconnects; D1 keeps the last list for the dashboard and
 * /v1/account/devices, and deleting the Mac there deletes it for good.
 */
interface StoredDevices {
  devices: Device[];
  updatedAt: number;
}

const DEVICES_PREFIX = "devices:";
const devicesKey = (name: string) => DEVICES_PREFIX + name;

/**
 * One space: the Macs that share a host secret and the agents that hold its client key.
 * Macs connect with hibernatable WebSockets, so an idle space costs nothing. The runtime
 * answers the Mac's keepalive "ping" with "pong" without waking the object.
 */
export class RelaySpace extends DurableObject<RelayEnv> {
  private pending = new Map<string, Pending>();
  /** Since when each Mac has had a request in flight. */
  private busySince = new Map<WebSocket, number>();
  /** Closed connections whose meter already moved to storage. */
  private retired = new WeakSet<WebSocket>();
  private flows = new Map<WebSocket, Flow>();
  /** Viewers already let go, so a close the relay started is not handled twice. */
  private left = new WeakSet<WebSocket>();
  private flushScheduled = false;
  /** How long an agent waits for the Mac's answer. Tests shorten it. */
  requestTimeoutMs = REQUEST_TIMEOUT_MS;

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /**
   * Accepts a Mac's WebSocket. Only the relay worker calls this, after authenticating it, reading
   * how many Macs the account may connect (X-Mobdev-Macs) and, when the relay bills, its allowance
   * from Autumn (X-Mobdev-Billing).
   */
  async fetch(request: Request): Promise<Response> {
    const live = request.headers.get("X-Mobdev-Live");
    if (live) return this.acceptViewer(JSON.parse(live) as LiveConnect);
    const accountId = request.headers.get("X-Mobdev-Account") ?? "";
    const billing = request.headers.get("X-Mobdev-Billing");
    const macs = Math.min(Number(request.headers.get("X-Mobdev-Macs")), MAX_ONLINE_HOSTS_PER_ACCOUNT);
    const connectedAt = Date.now();
    const attachment: Attachment = {
      name: request.headers.get("X-Mobdev-Name") ?? "mac",
      spaceId: request.headers.get("X-Mobdev-Space") ?? "",
      accountId,
      tokenId: request.headers.get("X-Mobdev-Token") ?? "",
      connectedAt,
      tokenCheckedAt: connectedAt,
      meter: billing ? { id: randomHex(8), accountId, requests: 0, activeMs: 0, seq: 0, batch: null } : null,
      quota: billing ? ((JSON.parse(billing) as { quota: Quota | null }).quota ?? null) : null,
    };
    const existing = this.ctx.getWebSockets(attachment.name);
    if (existing.length === 0 && this.names().length >= MAX_HOSTS_PER_SPACE) {
      return jsonError(429, "too many Macs share this key");
    }
    for (const socket of existing) {
      await this.retire(socket);
      socket.close(CLOSE_REPLACED, "another connection with this key and name took over");
      this.endViewersOf(socket, LIVE_CLOSE.macGone, "mac_offline", "the Mac reconnected");
    }
    // The access token may be revoked while this runs. Revoking deletes it and lists the spaces
    // of its Macs in one D1 batch (deleteAccessToken), then asks those spaces to close them. So:
    // record the Mac, accept its socket with no await in between, then check the token again. A
    // revocation that ran after the D1 write lists this space, and its call finds the accepted
    // socket; one that ran before it fails the check below. Either way no socket survives.
    if (!(await recordHostOnline(this.env.DB, attachment, macs))) return macLimitError(macs);
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [attachment.name]);
    server.serializeAttachment(attachment);
    if (!(await accessTokenExists(this.env.DB, attachment.tokenId))) {
      server.close(CLOSE_REVOKED, "access token revoked");
      await this.disconnected(server);
      return jsonError(403, `this relay needs an access token from ${DASHBOARD_URL}`);
    }
    await this.pruneDevices(); // Macs dropped by a restart never reported a close.
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Names of the connected Macs. */
  async hosts(): Promise<string[]> {
    return this.names();
  }

  /** The connected Macs with the devices they reported, newest connection first. */
  async devices(): Promise<MacDevices[]> {
    const connected = new Map<string, number>();
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      const attachment = macOf(socket);
      if (attachment) connected.set(attachment.name, Math.max(connected.get(attachment.name) ?? 0, attachment.connectedAt));
    }
    const names = [...connected.keys()];
    const stored = await this.ctx.storage.get<StoredDevices>(names.map(devicesKey));
    return names
      .map((name) => ({
        name,
        online: true,
        connected_at: connected.get(name) ?? null,
        disconnected_at: null,
        devices: stored.get(devicesKey(name))?.devices ?? [],
      }))
      .sort((a, b) => (b.connected_at ?? 0) - (a.connected_at ?? 0) || a.name.localeCompare(b.name));
  }

  /** Sends an agent request to a Mac and waits for its answer. */
  async forward(request: RelayRequest): Promise<RelayResponse> {
    const names = this.names();
    let name = request.name;
    if (!name) {
      if (names.length === 0) return errorResponse(503, "no Mac is connected with this key");
      if (names.length > 1) {
        return errorResponse(409, `several Macs are connected; use /h/<name>/... with one of: ${names.join(", ")}`);
      }
      name = names[0]!;
    }
    const socket = this.ctx.getWebSockets(name).find((ws) => ws.readyState === WebSocket.OPEN);
    if (!socket) return errorResponse(503, `the Mac "${name}" is not connected`);
    if (await this.revoked(socket)) return errorResponse(503, `the access token of the Mac "${name}" was revoked`);
    if (this.inFlight(socket) >= MAX_IN_FLIGHT_PER_MAC) {
      return errorResponse(
        429,
        `the Mac "${name}" is already handling ${MAX_IN_FLIGHT_PER_MAC} requests; send more when one finishes`,
        { "Retry-After": "1" },
      );
    }
    const attachment = socket.deserializeAttachment() as Attachment | null;
    const busySince = this.busySince.get(socket);
    if (attachment?.meter) {
      // Requests still in flight count too, or overlapping ones would never show as used time.
      const busyMs = busySince === undefined ? 0 : Date.now() - busySince;
      const limit = exhausted(attachment.quota, unconfirmed(attachment.meter, busyMs));
      if (limit) {
        await this.scheduleFlush(); // Asks Autumn again, so an upgrade takes effect.
        return errorResponse(429, limit.message, { "Retry-After": String(limit.retryAfter) });
      }
      attachment.meter.requests++;
      socket.serializeAttachment(attachment);
    }
    if (busySince === undefined) {
      this.busySince.set(socket, Date.now());
      // Sends the busy time while it lasts, not only once the Mac is idle again.
      if (attachment?.meter) this.ctx.waitUntil(this.scheduleFlush());
    }

    const id = crypto.randomUUID().replaceAll("-", "");
    const answer = new Promise<RelayResponse>((resolve) => {
      const timer = setTimeout(() => {
        // The agent gets its answer; the Mac may stop working on the request.
        try {
          socket.send(JSON.stringify({ type: "cancel", id }));
        } catch {
          // Closed meanwhile; nothing left to cancel.
        }
        this.settle(id, errorResponse(504, "the Mac did not answer in time"));
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve, timer, socket });
    });
    try {
      socket.send(
        JSON.stringify({
          type: "request",
          id,
          method: request.method,
          path: request.path,
          query: request.query,
          headers: request.headers,
          body: request.body,
        }),
      );
    } catch {
      this.settle(id, errorResponse(502, "the Mac disconnected"));
    }
    return answer;
  }

  /** Disconnects every Mac that connected with a revoked access token. */
  async revokeToken(tokenId: string): Promise<number> {
    let closed = 0;
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment() as Attachment | null;
      if (attachment?.tokenId === tokenId) {
        socket.close(CLOSE_REVOKED, "access token revoked");
        await this.disconnected(socket);
        closed++;
      }
    }
    await this.pruneDevices();
    return closed;
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    if (viewerOf(socket)) return this.viewerMessage(socket, message);
    let data: {
      type?: unknown;
      id?: string;
      status?: number;
      headers?: Record<string, string>;
      body?: string;
      devices?: unknown;
      seq?: unknown;
      code?: unknown;
      reason?: unknown;
    } | null;
    try {
      data = JSON.parse(message);
    } catch {
      return;
    }
    if (typeof data !== "object" || data === null) return;
    if (data.type === "devices") {
      const devices = devicesFromFrame(message, data);
      if (devices) await this.storeDevices(socket, devices);
      return;
    }
    if (data.type === "live_frame" && typeof data.id === "string") {
      this.liveFrame(socket, message, data.id, typeof data.seq === "number" ? data.seq : 0);
      return;
    }
    if (data.type === "live_end" && typeof data.id === "string") {
      const code = typeof data.code === "string" ? data.code : "ended";
      const reason = typeof data.reason === "string" ? data.reason : "";
      this.liveEnd(socket, data.id, code, reason);
      return;
    }
    if (data.type !== "response" || !data.id) return;
    const pending = this.pending.get(data.id);
    if (!pending || pending.socket !== socket) return;
    this.settle(data.id, {
      status: typeof data.status === "number" ? data.status : 502,
      headers: data.headers ?? {},
      body: data.body ?? "",
    });
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    if (viewerOf(socket)) this.viewerLeft(socket);
    else await this.disconnected(socket);
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    if (viewerOf(socket)) this.viewerLeft(socket);
    else await this.disconnected(socket);
  }

  /**
   * Looks after live views (renews their streams on the Macs, ends expired, revoked and silent
   * ones), sends what the Macs used to Autumn, and asks again for allowances that are unknown or
   * used up.
   */
  async alarm(): Promise<void> {
    this.flushScheduled = false;
    const nextLive = await this.liveHousekeeping();
    const autumn = autumnFor(this.env);
    let failed = false;
    if (autumn) {
      for (const socket of this.ctx.getWebSockets()) {
        if (socket.readyState !== WebSocket.OPEN || this.retired.has(socket) || !macOf(socket)) continue;
        if (!(await this.flushConnection(autumn, socket))) failed = true;
      }
      for (const [key, meter] of await this.ctx.storage.list<Meter>({ prefix: METER_PREFIX })) {
        try {
          // A stored meter can hold a batch and newer counts; both go before it is deleted.
          while (takeBatch(meter)) {
            await this.ctx.storage.put(key, meter); // A retry after a crash sends the same batch.
            await this.send(autumn, meter);
            meter.batch = null;
            meter.seq++;
            await this.ctx.storage.put(key, meter);
          }
          await this.ctx.storage.delete(key);
        } catch (error) {
          console.warn("could not send usage to Autumn", error);
          failed = true;
        }
      }
    }
    if (failed) await this.scheduleFlush(USAGE_RETRY_MS);
    else if (this.busySince.size > 0) await this.scheduleFlush(); // Macs still busy keep being counted.
    if (nextLive !== null) await this.scheduleAlarmAt(nextLive);
  }

  /** Sends one connected Mac's usage. Agent requests keep running while Autumn answers. */
  private async flushConnection(autumn: Autumn, socket: WebSocket): Promise<boolean> {
    const before = socket.deserializeAttachment() as Attachment | null;
    if (!before?.meter) return true;
    const since = this.busySince.get(socket);
    if (since !== undefined) {
      // Counts the time of requests still in flight up to now; finished() adds the rest.
      const now = Date.now();
      before.meter.activeMs += now - since;
      this.busySince.set(socket, now);
      socket.serializeAttachment(before);
    }
    try {
      if (takeBatch(before.meter)) {
        socket.serializeAttachment(before);
        const seq = before.meter.seq;
        const balances = await this.send(autumn, before.meter);
        const after = socket.deserializeAttachment() as Attachment;
        if (after.meter?.seq === seq) {
          after.meter.batch = null;
          after.meter.seq++;
        }
        for (const balance of balances) after.quota = withBalance(after.quota, balance);
        socket.serializeAttachment(after);
      }
      const current = socket.deserializeAttachment() as Attachment;
      const stale = !current.quota || Date.now() - current.quota.checkedAt >= QUOTA_REFRESH_MS;
      if (current.meter && stale && (!current.quota || exhausted(current.quota, unconfirmed(current.meter)))) {
        const customer = await autumn.customer(current.accountId);
        const latest = socket.deserializeAttachment() as Attachment;
        latest.quota = hasRelayPlan(customer) ? quotaFromCustomer(customer) : null;
        socket.serializeAttachment(latest);
      }
      return true;
    } catch (error) {
      console.warn("could not send usage to Autumn", error);
      return false;
    }
  }

  /** Tracks a meter's batch in Autumn and returns the balances it reported. */
  private async send(autumn: Autumn, meter: Meter): Promise<Balance[]> {
    const batch = meter.batch;
    if (!batch) return [];
    const balances: Balance[] = [];
    const key = `${meter.id}-${meter.seq}`;
    if (batch.requests > 0) {
      const balance = await autumn.track(meter.accountId, FEATURES.requests, batch.requests, `${key}-requests`);
      if (balance) balances.push(balance);
    }
    if (batch.seconds > 0) {
      const balance = await autumn.track(meter.accountId, FEATURES.activeSeconds, batch.seconds, `${key}-seconds`);
      if (balance) balances.push(balance);
    }
    return balances;
  }

  private async scheduleFlush(delay = USAGE_FLUSH_MS): Promise<void> {
    if (this.flushScheduled || !this.env.AUTUMN_SECRET_KEY) return;
    this.flushScheduled = true;
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + delay);
  }

  private inFlight(socket: WebSocket): number {
    let count = 0;
    for (const pending of this.pending.values()) if (pending.socket === socket) count++;
    return count;
  }

  /**
   * Adds the time a Mac was busy to its meter once it is idle again: its last request finished and
   * nobody watches it live.
   */
  private finished(socket: WebSocket): void {
    if (this.inFlight(socket) > 0 || this.watchers(socket).length > 0) return;
    const since = this.busySince.get(socket);
    this.busySince.delete(socket);
    if (since === undefined || this.retired.has(socket)) return;
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment?.meter) return;
    attachment.meter.activeMs += Date.now() - since;
    socket.serializeAttachment(attachment);
    this.ctx.waitUntil(this.scheduleFlush());
  }

  /** Moves a closing connection's unconfirmed usage to storage, where the next flush finds it. */
  private async retire(socket: WebSocket): Promise<void> {
    if (this.retired.has(socket)) return;
    this.retired.add(socket);
    const meter = (socket.deserializeAttachment() as Attachment | null)?.meter;
    const since = this.busySince.get(socket);
    this.busySince.delete(socket);
    if (!meter) return;
    if (since !== undefined) meter.activeMs += Date.now() - since;
    if (!meter.batch && meter.requests === 0 && meter.activeMs < 1000) return;
    await this.ctx.storage.put(METER_PREFIX + meter.id, meter);
    await this.scheduleFlush();
  }

  private async disconnected(socket: WebSocket): Promise<void> {
    await this.retire(socket);
    for (const [id, pending] of this.pending) {
      if (pending.socket === socket) this.settle(id, errorResponse(502, "the Mac disconnected"));
    }
    this.endViewersOf(socket, LIVE_CLOSE.macGone, "mac_offline", "the Mac disconnected");
    await this.pruneDevices();
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    const others = this.ctx
      .getWebSockets(attachment.name)
      .filter((ws) => ws !== socket && ws.readyState === WebSocket.OPEN);
    if (others.length === 0) {
      await recordHostOffline(this.env.DB, attachment.spaceId, attachment.name, attachment.connectedAt);
    }
  }

  /**
   * Whether the connection's access token was revoked, asking D1 at most every TOKEN_RECHECK_MS,
   * and closes the connection if so. Revoking also closes it right away (revokeToken), but that
   * call can fail; this bounds how long a revoked connection keeps working.
   */
  private async revoked(socket: WebSocket): Promise<boolean> {
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment || Date.now() - attachment.tokenCheckedAt < TOKEN_RECHECK_MS) return false;
    let exists: boolean;
    try {
      exists = await accessTokenExists(this.env.DB, attachment.tokenId);
    } catch (error) {
      console.warn("could not check the access token; trying again with the next request", error);
      return false;
    }
    if (exists) {
      const latest = socket.deserializeAttachment() as Attachment; // Requests may have counted meanwhile.
      latest.tokenCheckedAt = Date.now();
      socket.serializeAttachment(latest);
      return false;
    }
    if (socket.readyState === WebSocket.OPEN) socket.close(CLOSE_REVOKED, "access token revoked");
    await this.disconnected(socket);
    return true;
  }

  /** Keeps a Mac's latest device list here and in D1, where the account endpoint reads it. */
  private async storeDevices(socket: WebSocket, devices: Device[]): Promise<void> {
    // A replaced or revoked connection no longer speaks for its Mac.
    if (socket.readyState !== WebSocket.OPEN || (await this.revoked(socket))) return;
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    const stored: StoredDevices = { devices, updatedAt: Date.now() };
    await this.ctx.storage.put(devicesKey(attachment.name), stored);
    await recordHostDevices(this.env.DB, attachment.spaceId, attachment.name, devices, stored.updatedAt);
  }

  /** Drops the stored lists of Macs that are no longer connected. */
  private async pruneDevices(): Promise<void> {
    const connected = new Set(this.names());
    const keys = await this.ctx.storage.list({ prefix: DEVICES_PREFIX, limit: 128 });
    const stale = [...keys.keys()].filter((key) => !connected.has(key.slice(DEVICES_PREFIX.length)));
    if (stale.length > 0) await this.ctx.storage.delete(stale);
  }

  private settle(id: string, response: RelayResponse): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    clearTimeout(pending.timer);
    pending.resolve(response);
    this.finished(pending.socket);
  }

  private names(): string[] {
    const names = new Set<string>();
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      const attachment = macOf(socket);
      if (attachment) names.add(attachment.name);
    }
    return [...names].sort();
  }

  // MARK: Live view (shared/live.ts)

  /** Creates a one-time ticket for the dashboard to hand to a browser; see RelayAdmin.liveTicket. */
  async createTicket(spaceId: string, grant: LiveGrant): Promise<{ ticket: string } | { error: "offline" | "busy" }> {
    if (!this.macSocket(grant.mac)) return { error: "offline" };
    const now = Date.now();
    const stored = await this.ctx.storage.list<StoredTicket>({ prefix: TICKET_PREFIX, limit: LIVE_MAX_TICKETS * 2 });
    const stale = [...stored].filter(([, ticket]) => ticket.expiresAt <= now).map(([key]) => key);
    if (stale.length > 0) await this.ctx.storage.delete(stale);
    if (stored.size - stale.length >= LIVE_MAX_TICKETS) return { error: "busy" };
    const secret = randomHex(16);
    await this.ctx.storage.put<StoredTicket>(TICKET_PREFIX + (await sha256Hex(secret)), {
      grant,
      expiresAt: now + LIVE_TICKET_MS,
    });
    return { ticket: `mdv_${spaceId}${secret}` };
  }

  /** Ends the views of a revoked share link; see RelayAdmin.endShare. */
  async endShare(shareId: string): Promise<number> {
    const viewers = this.ctx
      .getWebSockets("viewer")
      .filter((socket) => socket.readyState === WebSocket.OPEN && viewerOf(socket)?.shareId === shareId);
    for (const viewer of viewers) this.endViewer(viewer, LIVE_CLOSE.revoked, "revoked", "the share link was revoked");
    return viewers.length;
  }

  private async redeemTicket(ticket: string): Promise<LiveGrant | null> {
    const key = TICKET_PREFIX + (await sha256Hex(ticketSecret(ticket)));
    const stored = await this.ctx.storage.get<StoredTicket>(key);
    if (!stored) return null;
    await this.ctx.storage.delete(key);
    return stored.expiresAt > Date.now() ? stored.grant : null;
  }

  /** Accepts a viewer's WebSocket and starts or joins the stream of its device. */
  private async acceptViewer(connect: LiveConnect): Promise<Response> {
    let grant: LiveGrant;
    if (connect.ticket) {
      const redeemed = await this.redeemTicket(connect.ticket);
      if (!redeemed) return jsonError(401, "this live view ticket is unknown, used or expired; open the live view again");
      grant = redeemed;
    } else {
      grant = { mac: connect.name ?? "", device: connect.device, mode: "control", viewer: { kind: "key", label: null }, shareId: null, endsAt: null };
    }
    const now = Date.now();
    if (grant.endsAt !== null && grant.endsAt <= now) return jsonError(403, "this share link expired");
    let name = grant.mac;
    if (!name) {
      const names = this.names();
      if (names.length === 0) return jsonError(503, "no Mac is connected with this key");
      if (names.length > 1) {
        return jsonError(409, `several Macs are connected; use /h/<name>/v1/live with one of: ${names.join(", ")}`);
      }
      name = names[0]!;
    }
    const mac = this.macSocket(name);
    if (!mac) return jsonError(503, `the Mac "${name}" is not connected`);
    if (await this.revoked(mac)) return jsonError(503, `the access token of the Mac "${name}" was revoked`);
    const macAttachment = macOf(mac)!;
    const watchers = this.watchers(mac);
    if (watchers.length >= LIVE_MAX_VIEWERS_PER_MAC) {
      return jsonError(429, `the Mac "${name}" already has ${LIVE_MAX_VIEWERS_PER_MAC} viewers`, { "Retry-After": "10" });
    }
    if (macAttachment.meter) {
      const since = this.busySince.get(mac);
      const limit = exhausted(macAttachment.quota, unconfirmed(macAttachment.meter, since === undefined ? 0 : now - since));
      if (limit) return jsonError(429, limit.message, { "Retry-After": String(limit.retryAfter) });
    }

    const joined = watchers.map(viewerOf).find((viewer) => viewer?.device === grant.device);
    const attachment: ViewerAttachment = {
      viewer: true,
      mac: name,
      macConnectedAt: macAttachment.connectedAt,
      device: grant.device,
      stream: joined?.stream ?? randomHex(16),
      fps: Math.min(Math.max(connect.fps, 1), LIVE_MAX_FPS),
      mode: grant.mode,
      who: grant.viewer,
      shareId: grant.shareId,
      endsAt: grant.endsAt,
      joinedAt: now,
    };
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, ["viewer", viewerTag(name)]);
    server.serializeAttachment(attachment);
    this.flows.set(server, { sent: [], inputs: [], seen: now });
    server.send(JSON.stringify({ type: "live", mac: name, device: grant.device, mode: grant.mode, fps: attachment.fps }));
    this.sendStart(mac, attachment.stream);
    // Watching keeps the Mac busy, which counts as active time like a request in flight.
    if (!this.busySince.has(mac)) {
      this.busySince.set(mac, now);
      if (macAttachment.meter) await this.scheduleFlush();
    }
    await this.scheduleAlarmAt(Math.min(now + LIVE_RENEW_MS, attachment.endsAt ?? Number.POSITIVE_INFINITY));
    const headers: HeadersInit = connect.protocol ? { "Sec-WebSocket-Protocol": LIVE_SUBPROTOCOL } : {};
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  private macSocket(name: string): WebSocket | undefined {
    return this.ctx.getWebSockets(name).find((socket) => socket.readyState === WebSocket.OPEN && macOf(socket));
  }

  /** The open viewers of a Mac connection. */
  private watchers(mac: WebSocket): WebSocket[] {
    const attachment = macOf(mac);
    if (!attachment) return [];
    return this.ctx.getWebSockets(viewerTag(attachment.name)).filter((socket) => {
      if (socket.readyState !== WebSocket.OPEN || this.left.has(socket)) return false;
      return viewerOf(socket)?.macConnectedAt === attachment.connectedAt;
    });
  }

  private flowOf(viewer: WebSocket): Flow {
    let flow = this.flows.get(viewer);
    if (!flow) {
      flow = { sent: [], inputs: [], seen: Date.now() };
      this.flows.set(viewer, flow);
    }
    return flow;
  }

  /** Tells the Mac who watches a stream now (live_start), or live_stop when nobody does. */
  private sendStart(mac: WebSocket, stream: string): void {
    const viewers = this.watchers(mac)
      .map(viewerOf)
      .filter((viewer): viewer is ViewerAttachment => viewer?.stream === stream);
    const frame =
      viewers.length === 0
        ? { type: "live_stop", id: stream }
        : {
            type: "live_start",
            id: stream,
            device: viewers[0]!.device,
            fps: Math.max(...viewers.map((viewer) => viewer.fps)),
            viewers: viewers.map((viewer) => ({
              kind: viewer.who.kind,
              ...(viewer.who.label ? { label: viewer.who.label } : {}),
              control: viewer.mode === "control",
            })),
          };
    try {
      mac.send(JSON.stringify(frame));
    } catch {
      // The Mac is gone; its close ends the viewers.
    }
  }

  /** Passes a frame from the Mac to the viewers of its stream that are not behind. */
  private liveFrame(mac: WebSocket, message: string, stream: string, seq: number): void {
    if (message.length > LIVE_MAX_FRAME_BYTES) return;
    const viewers = this.watchers(mac).filter((viewer) => viewerOf(viewer)?.stream === stream);
    for (const viewer of viewers) {
      const flow = this.flowOf(viewer);
      if (flow.sent.length >= LIVE_MAX_UNACKED) continue;
      try {
        viewer.send(message);
        flow.sent.push(seq);
      } catch {
        // Closing; its close event lets it go.
      }
    }
    // After a hibernation the busy time starts again with the next frame.
    if (viewers.length > 0 && !this.busySince.has(mac)) {
      this.busySince.set(mac, Date.now());
      if (macOf(mac)?.meter) this.ctx.waitUntil(this.scheduleFlush());
    }
  }

  /** The Mac ended a stream: its viewers hear why and are closed. */
  private liveEnd(mac: WebSocket, stream: string, code: string, reason: string): void {
    for (const viewer of this.watchers(mac)) {
      if (viewerOf(viewer)?.stream === stream) this.endViewer(viewer, LIVE_CLOSE.ended, code, reason, false);
    }
    this.finished(mac);
  }

  private async viewerMessage(viewer: WebSocket, message: string): Promise<void> {
    const flow = this.flowOf(viewer);
    flow.seen = Date.now();
    let data: { type?: unknown; seq?: unknown } | null;
    try {
      data = JSON.parse(message);
    } catch {
      return;
    }
    if (typeof data !== "object" || data === null) return;
    if (data.type === "ack" && typeof data.seq === "number") {
      const seq = data.seq;
      flow.sent = flow.sent.filter((sent) => sent > seq);
    } else if (data.type === "input") {
      const problem = await this.viewerInput(viewer, data, flow);
      if (problem) viewer.send(JSON.stringify({ type: "live_error", message: problem }));
    }
  }

  /** Checks a viewer's input and sends it to the Mac; returns why it was refused. */
  private async viewerInput(viewer: WebSocket, data: object, flow: Flow): Promise<string | null> {
    const attachment = viewerOf(viewer);
    if (!attachment) return null;
    if (attachment.mode !== "control") return "this live view is view only";
    const normalized = normalizeLiveInput(data);
    if ("error" in normalized) return normalized.error;
    const now = Date.now();
    flow.inputs = flow.inputs.filter((at) => now - at < 1000);
    if (flow.inputs.length >= LIVE_MAX_INPUTS_PER_SECOND) {
      return `too many inputs; at most ${LIVE_MAX_INPUTS_PER_SECOND} a second`;
    }
    flow.inputs.push(now);
    const mac = this.macSocket(attachment.mac);
    if (!mac || macOf(mac)?.connectedAt !== attachment.macConnectedAt) return null; // Its close follows.
    if (await this.revoked(mac)) return null;
    const macAttachment = macOf(mac)!;
    if (macAttachment.meter) {
      // An input is a request, like an agent's tool call.
      const since = this.busySince.get(mac);
      const limit = exhausted(macAttachment.quota, unconfirmed(macAttachment.meter, since === undefined ? 0 : now - since));
      if (limit) return limit.message;
      macAttachment.meter.requests++;
      mac.serializeAttachment(macAttachment);
    }
    mac.send(JSON.stringify({ type: "live_input", id: attachment.stream, input: normalized.input }));
    return null;
  }

  /** A viewer left or was closed: the Mac hears who still watches, or stops the stream. */
  private viewerLeft(viewer: WebSocket): void {
    if (this.left.has(viewer)) return;
    this.left.add(viewer);
    this.flows.delete(viewer);
    const attachment = viewerOf(viewer);
    if (!attachment) return;
    const mac = this.macSocket(attachment.mac);
    if (!mac || macOf(mac)?.connectedAt !== attachment.macConnectedAt) return;
    this.sendStart(mac, attachment.stream);
    this.finished(mac);
  }

  /**
   * Tells a viewer why its view ends and closes it. `notify` lets the Mac know who still watches;
   * a stream the Mac ended itself needs no word back.
   */
  private endViewer(viewer: WebSocket, code: number, reasonCode: string, reason: string, notify = true): void {
    try {
      viewer.send(JSON.stringify({ type: "live_end", code: reasonCode, reason }));
      viewer.close(code, closeReason(reason));
    } catch {
      // Already closed.
    }
    if (notify) {
      this.viewerLeft(viewer);
    } else {
      this.left.add(viewer);
      this.flows.delete(viewer);
    }
  }

  /** Ends the views of a Mac connection that went away. */
  private endViewersOf(mac: WebSocket, code: number, reasonCode: string, reason: string): void {
    for (const viewer of this.watchers(mac)) this.endViewer(viewer, code, reasonCode, reason, false);
  }

  /**
   * Every LIVE_RENEW_MS while someone watches: repeats live_start for each stream, so the Mac keeps
   * it, and ends views whose Mac is gone, whose share link expired or was revoked, whose viewer
   * went silent or whose account used up its allowance. Returns when to look again, or null when
   * nobody watches any more.
   */
  private async liveHousekeeping(): Promise<number | null> {
    const viewers = this.ctx.getWebSockets("viewer").filter((socket) => socket.readyState === WebSocket.OPEN && !this.left.has(socket));
    if (viewers.length === 0) return null;
    const now = Date.now();
    const shareIds = [...new Set(viewers.map((viewer) => viewerOf(viewer)?.shareId).filter((id): id is string => !!id))];
    let revoked = new Set<string>();
    try {
      const existing = await existingShares(this.env.DB, shareIds);
      revoked = new Set(shareIds.filter((id) => !existing.has(id)));
    } catch (error) {
      console.warn("could not check share links; trying again later", error);
    }
    const streams = new Map<string, WebSocket>();
    let next = now + LIVE_RENEW_MS;
    for (const viewer of viewers) {
      const attachment = viewerOf(viewer)!;
      const mac = this.macSocket(attachment.mac);
      const macAttachment = mac ? macOf(mac) : null;
      const seen = Math.max(
        this.flows.get(viewer)?.seen ?? 0,
        this.ctx.getWebSocketAutoResponseTimestamp(viewer)?.getTime() ?? 0,
        attachment.joinedAt,
      );
      const since = mac ? this.busySince.get(mac) : undefined;
      const limit =
        macAttachment?.meter && mac
          ? exhausted(macAttachment.quota, unconfirmed(macAttachment.meter, since === undefined ? 0 : now - since))
          : null;
      if (!mac || macAttachment?.connectedAt !== attachment.macConnectedAt) {
        this.endViewer(viewer, LIVE_CLOSE.macGone, "mac_offline", "the Mac disconnected", false);
      } else if (attachment.endsAt !== null && now >= attachment.endsAt) {
        this.endViewer(viewer, LIVE_CLOSE.expired, "expired", "the share link expired");
      } else if (attachment.shareId && revoked.has(attachment.shareId)) {
        this.endViewer(viewer, LIVE_CLOSE.revoked, "revoked", "the share link was revoked");
      } else if (now - seen > LIVE_VIEWER_IDLE_MS) {
        this.endViewer(viewer, LIVE_CLOSE.timeout, "timeout", "the viewer sent nothing in time");
      } else if (limit) {
        this.endViewer(viewer, LIVE_CLOSE.allowance, "allowance", limit.message);
      } else {
        streams.set(attachment.stream, mac);
        if (!this.busySince.has(mac)) this.busySince.set(mac, now); // Woke from hibernation.
        if (attachment.endsAt !== null) next = Math.min(next, attachment.endsAt);
      }
    }
    for (const [stream, mac] of streams) this.sendStart(mac, stream);
    return streams.size > 0 ? next : null;
  }

  /** Sets the alarm to `at` unless it already goes off earlier. */
  private async scheduleAlarmAt(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at) await this.ctx.storage.setAlarm(at);
  }
}
