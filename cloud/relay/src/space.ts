import { DurableObject } from "cloudflare:workers";
import type { Autumn, Balance } from "../../shared/autumn";
import { recordHostDevices, recordHostOffline, recordHostOnline } from "../../shared/db";
import { devicesFromFrame, type Device, type MacDevices } from "../../shared/devices";
import { randomHex } from "../../shared/keys";
import { FEATURES } from "../../shared/plans";
import { autumnFor, exhausted, hasRelayPlan, quotaFromCustomer, withBalance, type Quota } from "./billing";
import {
  CLOSE_REPLACED,
  CLOSE_REVOKED,
  MAX_HOSTS_PER_SPACE,
  MAX_IN_FLIGHT_PER_MAC,
  QUOTA_REFRESH_MS,
  REQUEST_TIMEOUT_MS,
  USAGE_FLUSH_MS,
  USAGE_RETRY_MS,
  errorResponse,
  jsonError,
  type RelayRequest,
  type RelayResponse,
} from "./protocol";
import type { RelayEnv } from "./env";

/**
 * What one connection used that Autumn has not confirmed yet: agent requests, and milliseconds
 * with at least one request in flight. `batch` is on its way to Autumn while the counters go on.
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
  connectedAt: number;
  /** Null when the relay does not bill (no Autumn key). */
  meter: Meter | null;
  /** The account's allowance; null until Autumn could be read, and requests pass meanwhile. */
  quota: Quota | null;
}

const METER_PREFIX = "meter:";

function unconfirmed(meter: Meter): { requests: number; seconds: number } {
  return {
    requests: meter.requests + (meter.batch?.requests ?? 0),
    seconds: Math.floor(meter.activeMs / 1000) + (meter.batch?.seconds ?? 0),
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
  private flushScheduled = false;

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /**
   * Accepts a Mac's WebSocket. Only the relay worker calls this, after authenticating it and, when
   * the relay bills, reading the account's allowance from Autumn (X-Mobdev-Billing).
   */
  async fetch(request: Request): Promise<Response> {
    const accountId = request.headers.get("X-Mobdev-Account") ?? "";
    const billing = request.headers.get("X-Mobdev-Billing");
    const attachment: Attachment = {
      name: request.headers.get("X-Mobdev-Name") ?? "mac",
      spaceId: request.headers.get("X-Mobdev-Space") ?? "",
      accountId,
      tokenId: request.headers.get("X-Mobdev-Token") ?? "",
      connectedAt: Date.now(),
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
    }
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [attachment.name]);
    server.serializeAttachment(attachment);
    await this.pruneDevices(); // Macs dropped by a restart never reported a close.
    await recordHostOnline(this.env.DB, attachment);
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
      const attachment = socket.deserializeAttachment() as Attachment | null;
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
    if (this.inFlight(socket) >= MAX_IN_FLIGHT_PER_MAC) {
      return errorResponse(
        429,
        `the Mac "${name}" is already handling ${MAX_IN_FLIGHT_PER_MAC} requests; send more when one finishes`,
        { "Retry-After": "1" },
      );
    }
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (attachment?.meter) {
      const limit = exhausted(attachment.quota, unconfirmed(attachment.meter));
      if (limit) {
        await this.scheduleFlush(); // Asks Autumn again, so an upgrade takes effect.
        return errorResponse(429, limit.message, { "Retry-After": String(limit.retryAfter) });
      }
      attachment.meter.requests++;
      socket.serializeAttachment(attachment);
    }
    if (!this.busySince.has(socket)) this.busySince.set(socket, Date.now());

    const id = crypto.randomUUID().replaceAll("-", "");
    const answer = new Promise<RelayResponse>((resolve) => {
      const timer = setTimeout(
        () => this.settle(id, errorResponse(504, "the Mac did not answer in time")),
        REQUEST_TIMEOUT_MS,
      );
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
    let data: {
      type?: unknown;
      id?: string;
      status?: number;
      headers?: Record<string, string>;
      body?: string;
      devices?: unknown;
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
    await this.disconnected(socket);
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    await this.disconnected(socket);
  }

  /** Sends what the Macs used to Autumn, and asks again for allowances that are unknown or used up. */
  async alarm(): Promise<void> {
    this.flushScheduled = false;
    const autumn = autumnFor(this.env);
    if (!autumn) return;
    let failed = false;
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.readyState !== WebSocket.OPEN || this.retired.has(socket)) continue;
      if (!(await this.flushConnection(autumn, socket))) failed = true;
    }
    for (const [key, meter] of await this.ctx.storage.list<Meter>({ prefix: METER_PREFIX })) {
      try {
        if (takeBatch(meter)) {
          await this.ctx.storage.put(key, meter); // A retry after a crash sends the same batch.
          await this.send(autumn, meter);
        }
        await this.ctx.storage.delete(key);
      } catch (error) {
        console.warn("could not send usage to Autumn", error);
        failed = true;
      }
    }
    if (failed) await this.scheduleFlush(USAGE_RETRY_MS);
  }

  /** Sends one connected Mac's usage. Agent requests keep running while Autumn answers. */
  private async flushConnection(autumn: Autumn, socket: WebSocket): Promise<boolean> {
    const before = socket.deserializeAttachment() as Attachment | null;
    if (!before?.meter) return true;
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

  /** Adds the time a Mac just spent on requests to its meter once the last one finished. */
  private finished(socket: WebSocket): void {
    if (this.inFlight(socket) > 0) return;
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
    await this.pruneDevices();
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    const others = this.ctx
      .getWebSockets(attachment.name)
      .filter((ws) => ws !== socket && ws.readyState === WebSocket.OPEN);
    if (others.length === 0) await recordHostOffline(this.env.DB, attachment.spaceId, attachment.name);
  }

  /** Keeps a Mac's latest device list here and in D1, where the account endpoint reads it. */
  private async storeDevices(socket: WebSocket, devices: Device[]): Promise<void> {
    // A replaced or revoked connection no longer speaks for its Mac.
    if (socket.readyState !== WebSocket.OPEN) return;
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
      const attachment = socket.deserializeAttachment() as Attachment | null;
      if (attachment) names.add(attachment.name);
    }
    return [...names].sort();
  }
}
