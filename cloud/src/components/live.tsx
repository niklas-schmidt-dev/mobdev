import { T, useGT } from "gt-tanstack-start";
import {
  useEffect,
  useRef,
  useState,
  type CSSProperties,
  type ClipboardEvent,
  type KeyboardEvent,
  type PointerEvent,
  type ReactNode,
} from "react";
import { LIVE_AUTH_PREFIX, LIVE_CLOSE, LIVE_MAX_TEXT, LIVE_SUBPROTOCOL, type LiveMode } from "../../shared/live";
import type { TicketResult } from "../server/live";

// A device's screen in the browser through the relay's live view (shared/live.ts): frames are drawn
// on a canvas and acknowledged once drawn, so a slow browser gets fewer frames instead of a backlog.
// Click taps, a long press holds, a drag swipes, the wheel scrolls, and typing goes to the device
// while the screen has keyboard focus. View-only links send nothing.

type Status =
  | { kind: "connecting" }
  | { kind: "live" }
  | { kind: "offline" }
  | { kind: "ended"; code: string }
  | { kind: "expired" }
  | { kind: "revoked" }
  | { kind: "limit" }
  | { kind: "failed" };

interface Frame {
  seq: number;
  width: number;
  height: number;
  jpeg: string;
}

const FPS = 8;
/** Keys the device understands by name; other single characters are typed as text. */
const NAMED_KEYS: Record<string, string> = {
  Enter: "enter",
  Backspace: "backspace",
  Escape: "escape",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  PageUp: "pageup",
  PageDown: "pagedown",
};

const clamp01 = (value: number) => Math.min(Math.max(value, 0), 1);

export function LiveScreen({
  getTicket,
  label,
  deviceClass,
  children,
}: {
  /** Asked before every connection; keep it stable (useCallback). */
  getTicket: () => Promise<TicketResult>;
  /** The device's name, for screen readers. */
  label: string;
  deviceClass: string;
  /** More controls next to Home, such as Share. */
  children?: ReactNode;
}) {
  const gt = useGT();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const screenRef = useRef<HTMLDivElement>(null);
  const socketRef = useRef<WebSocket | null>(null);
  const [status, setStatus] = useState<Status>({ kind: "connecting" });
  const [mode, setMode] = useState<LiveMode | null>(null);
  const [size, setSize] = useState<{ width: number; height: number } | null>(null);
  const [fps, setFps] = useState(0);
  /** Seconds since the last frame, while connected. */
  const [quiet, setQuiet] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [touches, setTouches] = useState<{ id: number; x: number; y: number }[]>([]);
  const modeRef = useRef<LiveMode | null>(null);
  modeRef.current = mode;

  useEffect(() => {
    let stopped = false;
    let socket: WebSocket | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let failures = 0;
    let frames = 0;
    let lastFrameAt = 0;
    let ended: string | null = null;

    const retry = (delay: number) => {
      if (!stopped) retryTimer = setTimeout(connect, delay);
    };

    function draw(frame: Frame) {
      const image = new Image();
      image.src = `data:image/jpeg;base64,${frame.jpeg}`;
      image
        .decode()
        .then(() => {
          const canvas = canvasRef.current;
          if (!canvas || stopped) return;
          if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            setSize({ width: image.naturalWidth, height: image.naturalHeight });
          }
          canvas.getContext("2d")?.drawImage(image, 0, 0);
          frames++;
          lastFrameAt = Date.now();
        })
        .catch(() => {})
        .finally(() => {
          // Drawn (or undrawable): the relay may send the next one.
          if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "ack", seq: frame.seq }));
        });
    }

    async function connect() {
      if (stopped) return;
      let ticket: TicketResult;
      try {
        ticket = await getTicket();
      } catch {
        failures++;
        setStatus({ kind: "failed" });
        retry(Math.min(30_000, 2000 * failures));
        return;
      }
      if (stopped) return;
      if ("error" in ticket) {
        if (ticket.error === "offline") {
          setStatus({ kind: "offline" });
          retry(5000);
        } else if (ticket.error === "expired") {
          setStatus({ kind: "expired" });
        } else if (ticket.error === "invalid") {
          setStatus({ kind: "revoked" });
        } else {
          failures++;
          setStatus({ kind: "failed" });
          retry(Math.min(30_000, 2000 * failures));
        }
        return;
      }
      const url = new URL("/v1/live", ticket.relayUrl);
      url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
      url.searchParams.set("fps", String(FPS));
      ended = null;
      socket = new WebSocket(url, [LIVE_SUBPROTOCOL, LIVE_AUTH_PREFIX + ticket.ticket]);
      socketRef.current = socket;
      socket.onmessage = (event) => {
        if (typeof event.data !== "string" || event.data === "pong") return;
        let message: { type?: string; mode?: LiveMode; code?: string; message?: string } & Partial<Frame>;
        try {
          message = JSON.parse(event.data);
        } catch {
          return;
        }
        if (message.type === "live") {
          failures = 0;
          lastFrameAt = Date.now();
          setMode(message.mode ?? "view");
          setStatus({ kind: "live" });
        } else if (message.type === "live_frame" && typeof message.jpeg === "string" && typeof message.seq === "number") {
          draw(message as Frame);
        } else if (message.type === "live_error" && message.message) {
          setNotice(message.message);
        } else if (message.type === "live_end") {
          ended = message.code ?? "ended";
        }
      };
      socket.onclose = (event) => {
        if (socketRef.current === socket) socketRef.current = null;
        if (stopped) return;
        switch (event.code) {
          case LIVE_CLOSE.macGone:
            setStatus({ kind: "offline" });
            retry(3000);
            break;
          case LIVE_CLOSE.ended:
            setStatus({ kind: "ended", code: ended ?? "ended" });
            break;
          case LIVE_CLOSE.expired:
            setStatus({ kind: "expired" });
            break;
          case LIVE_CLOSE.revoked:
            setStatus({ kind: "revoked" });
            break;
          case LIVE_CLOSE.allowance:
            setStatus({ kind: "limit" });
            break;
          default:
            // Network trouble, a relay deploy or a closed laptop lid: try again, slower each time.
            failures++;
            setStatus({ kind: "connecting" });
            retry(Math.min(30_000, 1000 * 2 ** Math.min(failures, 5)));
        }
      };
    }

    setStatus({ kind: "connecting" });
    void connect();
    const ping = setInterval(() => {
      if (socket?.readyState === WebSocket.OPEN) socket.send("ping");
    }, 20_000);
    const meter = setInterval(() => {
      setFps(frames);
      frames = 0;
      setQuiet(socket?.readyState === WebSocket.OPEN && lastFrameAt ? Math.floor((Date.now() - lastFrameAt) / 1000) : 0);
    }, 1000);
    return () => {
      stopped = true;
      clearTimeout(retryTimer);
      clearInterval(ping);
      clearInterval(meter);
      socket?.close(1000, "left");
      socketRef.current = null;
    };
  }, [getTicket, attempt]);

  // Notices fade after a few seconds.
  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(null), 4000);
    return () => clearTimeout(timer);
  }, [notice]);

  const canControl = mode === "control" && status.kind === "live";

  function send(input: Record<string, unknown>) {
    const socket = socketRef.current;
    if (modeRef.current !== "control" || socket?.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({ type: "input", ...input }));
  }

  // Pointer: a click taps, holding presses long, a drag swipes.
  const pointer = useRef<{ x: number; y: number; at: number; id: number } | null>(null);
  const lastPoint = useRef({ x: 0.5, y: 0.5 });

  function position(event: { clientX: number; clientY: number }) {
    const rect = canvasRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0 || rect.height === 0) return null;
    return { x: clamp01((event.clientX - rect.left) / rect.width), y: clamp01((event.clientY - rect.top) / rect.height) };
  }

  function onPointerDown(event: PointerEvent<HTMLDivElement>) {
    if (!canControl || event.button !== 0) return;
    const point = position(event);
    if (!point) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    pointer.current = { ...point, at: performance.now(), id: event.pointerId };
  }

  function onPointerUp(event: PointerEvent<HTMLDivElement>) {
    const start = pointer.current;
    pointer.current = null;
    if (!start || start.id !== event.pointerId) return;
    const end = position(event) ?? start;
    const held = (performance.now() - start.at) / 1000;
    if (Math.hypot(end.x - start.x, end.y - start.y) < 0.015) {
      if (held >= 0.5) send({ action: "long_press", x: start.x, y: start.y, seconds: Math.min(held, 5) });
      else send({ action: "tap", x: start.x, y: start.y });
      const id = Date.now() + Math.random();
      setTouches((current) => [...current, { id, x: start.x, y: start.y }]);
      setTimeout(() => setTouches((current) => current.filter((touch) => touch.id !== id)), 900);
    } else {
      send({
        action: "swipe",
        from_x: start.x,
        from_y: start.y,
        to_x: end.x,
        to_y: end.y,
        duration: Math.min(Math.max(held, 0.1), 2),
      });
    }
  }

  // The wheel scrolls; React's wheel events are passive, so the listener is added here.
  useEffect(() => {
    const element = screenRef.current;
    if (!element) return;
    let dx = 0;
    let dy = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onWheel = (event: WheelEvent) => {
      if (modeRef.current !== "control") return;
      event.preventDefault();
      dx += event.deltaX;
      dy += event.deltaY;
      lastPoint.current = position(event) ?? lastPoint.current;
      timer ??= setTimeout(() => {
        timer = undefined;
        const vertical = Math.abs(dy) >= Math.abs(dx);
        const distance = vertical ? dy : dx;
        const direction = vertical ? (dy > 0 ? "down" : "up") : dx > 0 ? "right" : "left";
        dx = dy = 0;
        if (Math.abs(distance) < 4) return;
        const amount = Math.min(Math.max(Math.round(Math.abs(distance) / 60), 1), 10);
        send({ action: "scroll", x: lastPoint.current.x, y: lastPoint.current.y, direction, amount });
      }, 200);
    };
    element.addEventListener("wheel", onWheel, { passive: false });
    return () => {
      element.removeEventListener("wheel", onWheel);
      clearTimeout(timer);
    };
  }, []);

  // Typing: characters are collected briefly and sent as text; named keys go one by one.
  const typed = useRef("");
  const typedTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  function flushText() {
    clearTimeout(typedTimer.current);
    typedTimer.current = undefined;
    if (typed.current) send({ action: "text", text: typed.current });
    typed.current = "";
  }

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!canControl || event.metaKey || event.ctrlKey || event.altKey) return; // Browser shortcuts; ⌘V pastes.
    const named = NAMED_KEYS[event.key];
    if (named) {
      event.preventDefault();
      flushText();
      send({ action: "key", key: named, modifiers: event.shiftKey ? ["shift"] : [] });
    } else if (Array.from(event.key).length === 1) {
      event.preventDefault();
      typed.current += event.key;
      if (Array.from(typed.current).length >= 200) flushText();
      else {
        clearTimeout(typedTimer.current);
        typedTimer.current = setTimeout(flushText, 250);
      }
    }
  }

  function onPaste(event: ClipboardEvent<HTMLDivElement>) {
    if (!canControl) return;
    const text = event.clipboardData.getData("text/plain");
    if (!text) return;
    event.preventDefault();
    flushText();
    const characters = Array.from(text);
    for (let start = 0; start < characters.length; start += LIVE_MAX_TEXT) {
      send({ action: "text", text: characters.slice(start, start + LIVE_MAX_TEXT).join("") });
    }
  }

  const ratio = size ? size.width / size.height : deviceClass === "iPad" ? 3 / 4 : 9 / 19.5;
  const rounded = deviceClass === "iPad" ? "rounded-[28px]" : deviceClass === "Android" ? "rounded-[30px]" : "rounded-[44px]";
  // The screen's corners, also for its focus ring (styles.css, .live-screen).
  const radius = deviceClass === "iPad" ? 18 : deviceClass === "Android" ? 22 : 34;
  const live = status.kind === "live";
  const waiting = live && (!size || quiet >= 6);
  const canRetry = ["ended", "failed", "offline"].includes(status.kind);
  // A short label above the screen; what it means, at length, over the screen.
  const badge = waiting ? gt("Waiting for the screen") : shortStatus(status, gt, fps, quiet);
  const explanation = waiting ? waitingText(gt, quiet, !!size) : live ? null : statusText(status, gt);
  const spinner = status.kind === "connecting" || (waiting && !size);

  return (
    <div className="flex flex-col items-center">
      <p
        role="status"
        aria-live="polite"
        className="mb-5 inline-flex items-center gap-2 rounded-full bg-card px-3.5 py-1.5 text-[14px] text-muted shadow-sm ring-1 ring-black/5 dark:shadow-none dark:ring-white/10"
      >
        <span
          className={`size-2 shrink-0 rounded-full ${live && !waiting ? "bg-[#34c759]" : status.kind === "connecting" || waiting ? "bg-[#ff9500]" : "bg-line"}`}
          aria-hidden="true"
        />
        {badge}
        {explanation && <span className="sr-only">. {explanation}</span>}
      </p>

      <div className={`${rounded} bg-[#1d1d1f] p-[10px] shadow-[0_30px_60px_-25px_rgba(0,0,0,0.5)] dark:shadow-none dark:ring-1 dark:ring-white/15`}>
        <div
          ref={screenRef}
          role="application"
          aria-roledescription={gt("Live device screen")}
          aria-label={
            canControl
              ? gt("{device}. Click to tap, drag to swipe, and type while it has focus.", { device: label })
              : gt("{device}, view only", { device: label })
          }
          tabIndex={0}
          onPointerDown={onPointerDown}
          onPointerUp={onPointerUp}
          onPointerCancel={() => (pointer.current = null)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
          onBlur={flushText}
          className={`live-screen relative overflow-hidden bg-black ${canControl ? "cursor-pointer touch-none" : ""}`}
          style={
            {
              aspectRatio: `${ratio}`,
              width: `min(calc(100vw - 60px), calc(min(70dvh, 760px) * ${ratio}))`,
              borderRadius: radius,
              "--live-radius": `${radius}px`,
            } as CSSProperties
          }
        >
          <canvas ref={canvasRef} className={`block size-full select-none ${size ? "" : "invisible"}`} aria-hidden="true" />
          {touches.map((touch) => (
            <span
              key={touch.id}
              className="touch"
              style={{ left: `${touch.x * 100}%`, top: `${touch.y * 100}%` }}
              aria-hidden="true"
            />
          ))}
          {(spinner || explanation) && (
            // Over the last picture, dimmed, or the black screen before the first.
            <div
              className={`absolute inset-0 flex items-center justify-center p-6 text-center text-[15px] leading-[1.4] text-white/85 ${size ? "bg-black/60 backdrop-blur-[2px]" : ""}`}
              aria-hidden="true"
            >
              {spinner ? (
                <span className="size-6 animate-spin rounded-full border-2 border-white/25 border-t-white/80 motion-reduce:animate-none" />
              ) : (
                <span>{explanation}</span>
              )}
            </div>
          )}
        </div>
      </div>

      {notice && (
        <p role="alert" className="mt-4 rounded-full bg-alert px-4 py-1.5 text-[14px] text-alert-ink">
          {notice}
        </p>
      )}

      <div className="mt-6 flex flex-wrap items-center justify-center gap-3">
        {mode === "control" && live ? (
          <button
            type="button"
            disabled={!canControl}
            onClick={() => send({ action: "home" })}
            className="inline-flex items-center gap-2 rounded-full bg-card px-5 py-2.5 text-[15px] font-medium shadow-sm ring-1 ring-black/5 transition-colors hover:bg-mist disabled:opacity-40 dark:shadow-none dark:ring-white/10"
          >
            <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
              <path d="M4 11l8-7 8 7M6 9.5V20h12V9.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <T>Home</T>
          </button>
        ) : mode === "view" && live ? (
          <span className="rounded-full bg-card px-4 py-2 text-[14px] text-muted ring-1 ring-black/5 dark:ring-white/10">
            <T>View only</T>
          </span>
        ) : null}
        {canRetry && (
          <button
            type="button"
            onClick={() => setAttempt((value) => value + 1)}
            className="rounded-full bg-blue px-5 py-2.5 text-[15px] font-medium text-white transition-colors hover:bg-blue-hover"
          >
            <T>Try again</T>
          </button>
        )}
        {children}
      </div>
      {canControl && (
        <T>
          <p className="mt-4 max-w-md text-center text-[13px] leading-[1.45] text-faint">
            Click to tap, hold to press long, drag to swipe, scroll with the wheel. Click the screen, then type to send
            keys; ⌘V pastes.
          </p>
        </T>
      )}
    </div>
  );
}

type Translate = ReturnType<typeof useGT>;

/** The label above the screen. */
function shortStatus(status: Status, gt: Translate, fps: number, quiet: number): string {
  switch (status.kind) {
    case "connecting":
      return gt("Connecting…");
    case "live":
      return fps > 0 && quiet < 2 ? gt("Live · {fps} fps", { fps }) : gt("Live");
    case "offline":
      return gt("Mac offline");
    case "expired":
      return gt("Link expired");
    case "revoked":
      return gt("Link not valid");
    case "limit":
      return gt("Limit reached");
    case "failed":
      return gt("Not connected");
    case "ended":
      return status.code === "disabled" ? gt("Live view off") : gt("Live view ended");
  }
}

/** What a status means, over the screen; null while the picture runs. */
function statusText(status: Status, gt: Translate): string | null {
  switch (status.kind) {
    case "connecting":
    case "live":
      return null;
    case "offline":
      return gt("The Mac is offline. Trying again…");
    case "expired":
      return gt("This link has expired.");
    case "revoked":
      return gt("This link is no longer valid.");
    case "limit":
      return gt("This account has used up its hosted relay time for this month.");
    case "failed":
      return gt("Could not connect. Trying again…");
    case "ended":
      switch (status.code) {
        case "disabled":
          return gt("Live view is off on this Mac. Turn on “Allow live view” under Remote Access in Mobdev, then try again.");
        case "no_device":
          return gt("This device is not connected to the Mac right now.");
        case "stopped":
          return gt("The live view was stopped on the Mac.");
        default:
          return gt("The live view ended.");
      }
  }
}

/** The Mac sends a picture at least every 2 s, so a longer pause means it has none. */
function waitingText(gt: Translate, quiet: number, hadPicture: boolean): string {
  if (hadPicture) return gt("The picture stopped. The device may be locked or asleep.");
  if (quiet >= 15) return gt("No picture yet. The device may be locked, or Mobdev on the Mac may need an update.");
  return gt("Connected. Waiting for the screen…");
}
