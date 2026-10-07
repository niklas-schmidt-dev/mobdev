// Live view: watch a device's screen through the relay and, if allowed, tap and type on it. The
// protocol is the Go relay's (relay/live.go); the Mac side is LiveStreams.swift.
//
// Viewer ⇄ relay, WebSocket at /v1/live?device=<id>&fps=<1-10> (or /h/<mac>/v1/live):
//   credential  "Authorization: Bearer mdc_…" or, from browsers, the subprotocols "mobdev-live" and
//               "mobdev-auth.<credential>"; the relay answers with "mobdev-live". The hosted relay
//               also takes one-time tickets (mdv_…) that the dashboard gets through RelayAdmin.
//   relay →     {"type":"live","mac","device","mode":"control"|"view","fps"} once, then the Mac's
//               {"type":"live_frame","id","seq","width","height","jpeg"} unchanged,
//               {"type":"live_error","message"} for refused input and {"type":"live_end","code",
//               "reason"} before the relay closes the view (close codes in LIVE_CLOSE).
//   viewer →    {"type":"ack","seq"} for each frame shown, {"type":"input","action",…} and "ping"
//               every 20 s (answered "pong"). A viewer with LIVE_MAX_UNACKED frames unacknowledged
//               gets none until it catches up, so slow viewers skip frames instead of queueing them.
// Relay ⇄ Mac, on the Mac's WebSocket:
//   relay →     {"type":"live_start","id","device","fps","viewers":[{"kind","label","control"}]}
//               when a stream starts, its viewers change and every LIVE_RENEW_MS;
//               {"type":"live_stop","id"} after the last viewer; {"type":"live_input","id","input"}.
//   Mac →       {"type":"live_frame",…} and {"type":"live_end","id","code","reason"} when it ends a
//               stream itself (code "disabled": live view is off on that Mac; "no_device";
//               "stopped": stopped in the app; "timeout": not renewed for 75 s).

export const LIVE_SUBPROTOCOL = "mobdev-live";
export const LIVE_AUTH_PREFIX = "mobdev-auth.";
export const LIVE_DEFAULT_FPS = 5;
export const LIVE_MAX_FPS = 10;
/** Frames a viewer may have unacknowledged; newer ones skip it. */
export const LIVE_MAX_UNACKED = 2;
/** Viewers per Mac, across its devices. */
export const LIVE_MAX_VIEWERS_PER_MAC = 10;
/** Inputs per viewer and second; more are refused. */
export const LIVE_MAX_INPUTS_PER_SECOND = 10;
/** Larger frames from a Mac are dropped instead of passed to browsers. */
export const LIVE_MAX_FRAME_BYTES = 2 * 1024 * 1024;
export const LIVE_MAX_TEXT = 1000;
export const LIVE_MAX_DEVICE = 200;
const LIVE_MAX_KEY = 16;
/** How often the relay repeats live_start; the Mac ends a stream not renewed for 75 s. */
export const LIVE_RENEW_MS = 30_000;
/** A viewer that sent nothing, not even "ping", for this long has gone. */
export const LIVE_VIEWER_IDLE_MS = 75_000;
/** How long a dashboard ticket is good for; each is used once. */
export const LIVE_TICKET_MS = 60_000;
/** Unused tickets one space keeps at most. */
export const LIVE_MAX_TICKETS = 50;

/** Close codes for viewers; the Go relay uses the same where it has the case. */
export const LIVE_CLOSE = {
  /** The Mac disconnected. */
  macGone: 4002,
  /** The Mac ended the stream; the live_end before says why. */
  ended: 4003,
  /** The share link expired. */
  expired: 4004,
  /** The share link was revoked. */
  revoked: 4005,
  /** The viewer sent nothing in time. */
  timeout: 4008,
  /** The account's hosted relay allowance is used up. */
  allowance: 4029,
} as const;

export type LiveMode = "view" | "control";

/** Who watches, as the Mac shows it: an agent with the client key, the account owner, or a share link. */
export interface LiveViewer {
  kind: "key" | "owner" | "share";
  label: string | null;
}

/** What a ticket lets its holder watch, decided by the dashboard. */
export interface LiveGrant {
  mac: string;
  device: string;
  mode: LiveMode;
  viewer: LiveViewer;
  /** The share link it came from, so revoking the link ends the view. */
  shareId: string | null;
  /** When the view ends at the latest (a share link's expiry). */
  endsAt: number | null;
}

const ticketPattern = /^mdv_[0-9a-f]{64}[0-9a-f]{32}$/;

/** A ticket is "mdv_" + the space it is for + a secret; the space keeps the secret's hash. */
export function isLiveTicket(value: string | null): value is string {
  return value !== null && ticketPattern.test(value);
}

export function ticketSpace(ticket: string): string {
  return ticket.slice(4, 68);
}

export function ticketSecret(ticket: string): string {
  return ticket.slice(68);
}

/** The viewer's credential: Authorization, else the "mobdev-auth.<credential>" subprotocol. */
export function liveCredential(request: Request): string | null {
  const authorization = request.headers.get("Authorization");
  if (authorization && /^bearer /i.test(authorization)) return authorization.slice(7).trim();
  for (const token of (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",")) {
    const trimmed = token.trim();
    if (trimmed.startsWith(LIVE_AUTH_PREFIX)) return trimmed.slice(LIVE_AUTH_PREFIX.length);
  }
  return null;
}

/** Whether the viewer offered the live subprotocol, which the relay must then answer with. */
export function offersLiveSubprotocol(request: Request): boolean {
  return (request.headers.get("Sec-WebSocket-Protocol") ?? "")
    .split(",")
    .some((token) => token.trim() === LIVE_SUBPROTOCOL);
}

/** The fps a viewer asks for: 5 without one, 1 to 10, null when it is not a number. */
export function liveFps(text: string | null): number | null {
  if (text === null || text === "") return LIVE_DEFAULT_FPS;
  if (!/^-?\d+$/.test(text)) return null;
  return Math.min(Math.max(Number(text), 1), LIVE_MAX_FPS);
}

/** A device id or name: at most 200 characters, no control characters. */
export function isLiveDevice(value: string): boolean {
  // eslint-disable-next-line no-control-regex
  return Array.from(value).length <= LIVE_MAX_DEVICE && !/[\u0000-\u001f\u007f-\u009f]/.test(value);
}

type Input = Record<string, unknown>;

/**
 * Checks a viewer's input and keeps only the fields of its action, as the Go relay does. Points are
 * fractions of the screen from its top-left corner, 0 to 1.
 */
export function normalizeLiveInput(value: unknown): { input: Input } | { error: string } {
  if (typeof value !== "object" || value === null) return { error: "input must be a JSON object with an action" };
  const raw = value as Record<string, unknown>;
  const fraction = (key: string): number | null => {
    const v = raw[key];
    return typeof v === "number" && v >= 0 && v <= 1 ? v : null;
  };
  const clamp = (key: string, fallback: number, low: number, high: number): number => {
    const v = raw[key];
    return typeof v === "number" && Number.isFinite(v) ? Math.min(Math.max(v, low), high) : fallback;
  };
  const pointProblem = { error: "points are fractions of the screen from 0 to 1" };
  switch (raw.action) {
    case "tap":
    case "long_press": {
      const x = fraction("x");
      const y = fraction("y");
      if (x === null || y === null) return pointProblem;
      if (raw.action === "tap") return { input: { action: "tap", x, y } };
      return { input: { action: "long_press", seconds: clamp("seconds", 1, 0.3, 5), x, y } };
    }
    case "swipe": {
      const [fromX, fromY, toX, toY] = ["from_x", "from_y", "to_x", "to_y"].map(fraction);
      if (fromX == null || fromY == null || toX == null || toY == null) return pointProblem;
      return {
        input: { action: "swipe", duration: clamp("duration", 0.3, 0.1, 2), from_x: fromX, from_y: fromY, to_x: toX, to_y: toY },
      };
    }
    case "scroll": {
      let x = 0.5;
      let y = 0.5;
      if (raw.x !== undefined || raw.y !== undefined) {
        const fx = fraction("x");
        const fy = fraction("y");
        if (fx === null || fy === null) return pointProblem;
        x = fx;
        y = fy;
      }
      if (!["up", "down", "left", "right"].includes(raw.direction as string)) {
        return { error: "direction must be up, down, left or right" };
      }
      return { input: { action: "scroll", amount: Math.round(clamp("amount", 3, 1, 20)), direction: raw.direction, x, y } };
    }
    case "text": {
      const text = raw.text;
      if (typeof text !== "string" || text === "" || Array.from(text).length > LIVE_MAX_TEXT) {
        return { error: `text must have 1 to ${LIVE_MAX_TEXT} characters` };
      }
      return { input: { action: "text", text } };
    }
    case "key": {
      const key = raw.key;
      // eslint-disable-next-line no-control-regex
      if (typeof key !== "string" || key === "" || Array.from(key).length > LIVE_MAX_KEY || /[\u0000-\u001f\u007f]/.test(key)) {
        return { error: "key must be a key name such as enter or one character" };
      }
      const given = raw.modifiers === undefined || raw.modifiers === null ? [] : raw.modifiers;
      const problem = { error: "modifiers must be cmd, shift, option or ctrl, each once" };
      if (!Array.isArray(given)) return problem;
      const modifiers = ["cmd", "shift", "option", "ctrl"].filter((modifier) => given.includes(modifier));
      if (modifiers.length !== given.length) return problem;
      return { input: { action: "key", key, modifiers } };
    }
    case "home":
      return { input: { action: "home" } };
  }
  return { error: "action must be tap, long_press, swipe, scroll, text, key or home" };
}

/** A close frame's reason may have 123 bytes. */
export function closeReason(reason: string): string {
  const encoder = new TextEncoder();
  let characters = Array.from(reason);
  while (encoder.encode(characters.join("")).byteLength > 120) characters = characters.slice(0, -1);
  return characters.join("");
}
