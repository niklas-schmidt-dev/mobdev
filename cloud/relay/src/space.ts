import { DurableObject } from "cloudflare:workers";
import { recordHostDevices, recordHostOffline, recordHostOnline } from "../../shared/db";
import { devicesFromFrame, type Device, type MacDevices } from "../../shared/devices";
import {
  CLOSE_REPLACED,
  CLOSE_REVOKED,
  MAX_HOSTS_PER_SPACE,
  REQUEST_TIMEOUT_MS,
  errorResponse,
  jsonError,
  type RelayRequest,
  type RelayResponse,
} from "./protocol";
import type { RelayEnv } from "./env";

interface Attachment {
  name: string;
  spaceId: string;
  accountId: string;
  tokenId: string;
  connectedAt: number;
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

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** Accepts a Mac's WebSocket. Only the relay worker calls this, after authenticating it. */
  async fetch(request: Request): Promise<Response> {
    const attachment: Attachment = {
      name: request.headers.get("X-Mobdev-Name") ?? "mac",
      spaceId: request.headers.get("X-Mobdev-Space") ?? "",
      accountId: request.headers.get("X-Mobdev-Account") ?? "",
      tokenId: request.headers.get("X-Mobdev-Token") ?? "",
      connectedAt: Date.now(),
    };
    const existing = this.ctx.getWebSockets(attachment.name);
    if (existing.length === 0 && this.names().length >= MAX_HOSTS_PER_SPACE) {
      return jsonError(429, "too many Macs share this key");
    }
    for (const socket of existing) {
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

    const id = crypto.randomUUID().replaceAll("-", "");
    const answer = new Promise<RelayResponse>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve(errorResponse(504, "the Mac did not answer in time"));
      }, REQUEST_TIMEOUT_MS);
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

  private async disconnected(socket: WebSocket): Promise<void> {
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
