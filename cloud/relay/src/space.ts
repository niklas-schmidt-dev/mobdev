import { DurableObject } from "cloudflare:workers";
import { recordHostOffline, recordHostOnline } from "../../shared/db";
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
    await recordHostOnline(this.env.DB, attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Names of the connected Macs. */
  async hosts(): Promise<string[]> {
    return this.names();
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
    return closed;
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    let data: { type?: string; id?: string; status?: number; headers?: Record<string, string>; body?: string };
    try {
      data = JSON.parse(message);
    } catch {
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
    const attachment = socket.deserializeAttachment() as Attachment | null;
    if (!attachment) return;
    const others = this.ctx
      .getWebSockets(attachment.name)
      .filter((ws) => ws !== socket && ws.readyState === WebSocket.OPEN);
    if (others.length === 0) await recordHostOffline(this.env.DB, attachment.spaceId, attachment.name);
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
