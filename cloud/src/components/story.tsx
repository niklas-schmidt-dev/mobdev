import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import type { Stage, StoryState } from "../three/stage";
import { buttonPrimary, moreLink } from "./site";

/**
 * The top of the home page: a pinned 3D stage the visitor scrolls through. The folded m of the logo
 * dissolves into particles that become an iPhone, a simulator and an Android phone, an agent taps on
 * them, and they turn into a globe for remote access. The text is real text; without WebGPU or
 * WebGL the chapters still read, over the app icon.
 */

/** Scroll progress (0 to 1) at which each chapter's text fades in, is fully in, starts and ends fading out. */
const chapters = {
  hero: [-1, 0, 0.06, 0.14],
  devices: [0.3, 0.36, 0.49, 0.55],
  agent: [0.55, 0.6, 0.71, 0.76],
  anywhere: [0.86, 0.92, 2, 3],
} as const satisfies Record<string, readonly [number, number, number, number]>;

type ChapterName = keyof typeof chapters;

const ramp = (p: number, from: number, to: number) => Math.min(1, Math.max(0, (p - from) / (to - from)));

function storyState(p: number, reducedMotion: boolean): StoryState {
  if (reducedMotion) {
    // No flights: the scene cuts between states while the canvas is faded out (see canvasOpacity).
    const phones = p >= 0.24 ? 1 : 0;
    return { dissolve: phones, toPhones: phones, agent: 0, toGlobe: p >= 0.8 ? 1 : 0 };
  }
  return {
    dissolve: ramp(p, 0.08, 0.2),
    toPhones: ramp(p, 0.13, 0.33),
    agent: ramp(p, 0.56, 0.6) * (1 - ramp(p, 0.72, 0.76)),
    toGlobe: ramp(p, 0.73, 0.9),
  };
}

function canvasOpacity(p: number, reducedMotion: boolean) {
  if (!reducedMotion) return 1;
  const dip = (at: number) => Math.max(0, 1 - Math.abs(p - at) / 0.05);
  return 1 - Math.max(dip(0.24), dip(0.8));
}

/** 0 before a chapter, 1 while it is on, 0 after; with the direction it moves in. */
function fade(p: number, [a, b, c, d]: readonly [number, number, number, number]) {
  if (p < b) return { amount: ramp(p, a, b), rising: true };
  return { amount: 1 - ramp(p, c, d), rising: false };
}

/** What the agent does, one line per tap, per phone. Tool names match the real tools. */
const devices = ["iPhone", "iPhone 17 Pro", "Pixel 9"] as const;
const script: readonly (readonly [string, string])[][] = [
  [
    ["tap_text", "“Continue”"],
    ["read_screen", "14 lines of text"],
    ["swipe", "Up"],
    ["open_app", "Settings"],
  ],
  [
    ["install_app", "Notes.app"],
    ["tap_text", "“New Note”"],
    ["type_text", "Typed 9 characters"],
    ["logs", "No errors"],
  ],
  [
    ["launch_app", "com.example.notes"],
    ["tap", "540, 1210"],
    ["screenshot", "1080 × 2400"],
    ["crash_reports", "None"],
  ],
];

type Activity = { id: number; tool: string; detail: string; device: string };
type Touch = { id: number; x: number; y: number };

/** What the activity card shows before the first tap, so it never starts empty. */
const earlierActivity: Activity[] = [
  { id: -1, tool: "list_devices", detail: "3 devices ready", device: "This Mac" },
  { id: -2, tool: "screenshot", detail: "1179 × 2556", device: "iPhone" },
  { id: -3, tool: "install_app", detail: "app-debug.apk", device: "Pixel 9" },
];

const labels = [
  { name: "iPhone", needs: "USB cable" },
  { name: "Simulator", needs: "Xcode" },
  { name: "Android", needs: "adb" },
];

export function Story() {
  const section = useRef<HTMLElement>(null);
  const host = useRef<HTMLDivElement>(null);
  /** Everything that fades with a chapter, keyed by chapter and part. */
  const chapterNodes = useRef(new Map<string, { name: ChapterName; node: HTMLDivElement }>());
  const labelRefs = useRef<(HTMLDivElement | null)[]>([]);
  const [status, setStatus] = useState<"loading" | "ready" | "failed">("loading");
  const [activity, setActivity] = useState<Activity[]>(earlierActivity);
  const [touches, setTouches] = useState<Touch[]>([]);

  useEffect(() => {
    const element = section.current;
    const container = host.current;
    if (!element || !container) return;
    // A canvas per run: a WebGPU context belongs to its canvas, and a renderer that is still
    // starting up from an earlier run (React runs effects twice in development) must not share it.
    const surface = document.createElement("canvas");
    surface.className = "block size-full";
    surface.setAttribute("aria-hidden", "true");
    container.appendChild(surface);
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
    let stage: Stage | null = null;
    let disposed = false;
    let visible = true;
    let progress = 0;
    let scheduled = 0;
    let tapCount = 0;
    const steps = [0, 0, 0];

    const applyScroll = () => {
      scheduled = 0;
      const rect = element.getBoundingClientRect();
      progress = Math.min(1, Math.max(0, -rect.top / Math.max(1, rect.height - window.innerHeight)));
      for (const { name, node } of chapterNodes.current.values()) {
        const { amount, rising } = fade(progress, chapters[name]);
        node.style.opacity = String(amount);
        node.style.visibility = amount < 0.01 ? "hidden" : "visible";
        if (!reducedMotion) {
          const rest = 1 - amount;
          node.style.transform = `translate3d(0, ${(rising ? 1 : -1) * rest * 36}px, 0)`;
          node.style.filter = rest > 0.01 ? `blur(${rest * 10}px)` : "";
        }
      }
      const labelsOn = fade(progress, chapters.devices).amount;
      labelRefs.current.forEach((label) => label && (label.style.opacity = String(labelsOn)));
      surface.style.opacity = String(canvasOpacity(progress, reducedMotion));
      stage?.setState(storyState(progress, reducedMotion));
    };
    const onScroll = () => {
      if (!scheduled) scheduled = requestAnimationFrame(applyScroll);
    };

    /** Tells the stage where the text of each chapter ends, so the 3D objects sit below it. */
    const measure = () => {
      const height = container.clientHeight;
      const gap = Math.min(32, height * 0.03);
      const bottomOf = (key: string) => {
        const node = chapterNodes.current.get(key)?.node;
        return node ? node.offsetTop + node.offsetHeight : height * 0.4;
      };
      const activityTop = chapterNodes.current.get("agent:activity")?.node.offsetTop ?? height;
      stage?.setLayout({
        m: [bottomOf("hero:text") + gap, height - gap],
        devices: [bottomOf("devices:text") + gap, height - 64 - gap],
        agent: [bottomOf("agent:text") + gap, activityTop - gap],
        globe: [bottomOf("anywhere:text") + gap, height - gap],
      });
    };

    const resize = () => {
      const rect = surface.getBoundingClientRect();
      stage?.resize(rect.width, rect.height);
      measure();
      onScroll();
    };
    void document.fonts.ready.then(() => !disposed && measure());

    const onPointer = (event: PointerEvent) => {
      if (event.pointerType !== "mouse" || !stage) return;
      const rect = surface.getBoundingClientRect();
      const x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
      const y = -(((event.clientY - rect.top) / rect.height) * 2 - 1);
      stage.setPointer(Math.abs(x) <= 1 && Math.abs(y) <= 1 ? { x, y } : null);
    };
    const onLeave = () => stage?.setPointer(null);
    const onTheme = () => stage?.setDark(darkQuery.matches);
    const run = () => stage?.setRunning(visible && document.visibilityState === "visible");

    const observer = new IntersectionObserver(([entry]) => {
      visible = entry?.isIntersecting ?? true;
      run();
    });
    observer.observe(element);

    applyScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", resize);
    window.addEventListener("pointermove", onPointer, { passive: true });
    document.documentElement.addEventListener("pointerleave", onLeave);
    document.addEventListener("visibilitychange", run);
    darkQuery.addEventListener("change", onTheme);

    // Effects never run on the server; the SSR check also keeps three.js out of the Worker's bundle.
    const loadStage = import.meta.env.SSR ? Promise.reject(new Error("No 3D on the server")) : import("../three/stage");
    loadStage
      .then(({ createStage }) =>
        createStage({
          canvas: surface,
          dark: darkQuery.matches,
          reducedMotion,
          onFrame: (current) => {
            labelRefs.current.forEach((label, k) => {
              if (!label) return;
              const { x, y } = current.phoneLabel(k);
              label.style.transform = `translate3d(${x}px, ${y}px, 0) translateX(-50%)`;
            });
          },
          onTap: (phone, at) => {
            setTouches((current) => [...current.slice(-3), { id: tapCount, ...at }]);
            const lines = script[phone] ?? [];
            const line = lines[(steps[phone] ?? 0) % lines.length];
            steps[phone] = (steps[phone] ?? 0) + 1;
            if (!line) return;
            const entry: Activity = { id: tapCount++, tool: line[0], detail: line[1], device: devices[phone] ?? "" };
            setActivity((current) => [entry, ...current].slice(0, 3));
          },
        }),
      )
      .then((created) => {
        if (disposed) return created.dispose();
        stage = created;
        resize();
        run();
        setStatus("ready");
      })
      .catch((error: unknown) => {
        console.warn("Mobdev: the 3D stage is unavailable", error);
        if (!disposed) setStatus("failed");
      });

    return () => {
      disposed = true;
      cancelAnimationFrame(scheduled);
      observer.disconnect();
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", resize);
      window.removeEventListener("pointermove", onPointer);
      document.documentElement.removeEventListener("pointerleave", onLeave);
      document.removeEventListener("visibilitychange", run);
      darkQuery.removeEventListener("change", onTheme);
      stage?.dispose();
      surface.remove();
    };
  }, []);

  const chapter = (name: ChapterName, part = "text") => (node: HTMLDivElement | null) => {
    if (node) chapterNodes.current.set(`${name}:${part}`, { name, node });
    else chapterNodes.current.delete(`${name}:${part}`);
  };
  const hidden: CSSProperties = { opacity: 0, visibility: "hidden" };

  return (
    <section ref={section} className="relative h-[480vh] sm:h-[520vh]">
      <div className="sticky top-0 h-svh overflow-hidden">
        <div aria-hidden="true" className="story-glow absolute inset-0" />
        <div
          ref={host}
          className={`absolute inset-0 transition-opacity duration-700 ${status === "ready" ? "opacity-100" : "opacity-0"}`}
        />
        {status === "failed" && (
          <img
            src="/app-icon.png"
            width="512"
            height="512"
            alt=""
            className="absolute bottom-[10svh] left-1/2 size-56 -translate-x-1/2 drop-shadow-[0_30px_60px_rgba(0,80,255,0.25)] sm:size-72"
          />
        )}

        {/* Chapter 1: the hero */}
        <div ref={chapter("hero")} className="absolute inset-x-0 top-[calc(48px+5svh)] px-5 text-center will-change-transform sm:top-[calc(48px+7svh)]">
          <p className="rise text-[19px] font-semibold sm:text-[21px]" style={{ "--rise-delay": "80ms" } as CSSProperties}>
            Mobdev for Mac
          </p>
          <h1
            className="rise headline text-balance mx-auto mt-2 max-w-4xl text-[44px] sm:text-[min(80px,9svh)]"
            style={{ "--rise-delay": "160ms" } as CSSProperties}
          >
            Mobile development.
            <br />
            All in one app.
          </h1>
          <p
            className="rise text-balance mx-auto mt-5 max-w-2xl text-[17px] leading-[1.45] text-muted sm:text-[21px]"
            style={{ "--rise-delay": "260ms" } as CSSProperties}
          >
            Let AI agents drive your phones, install and debug your builds and run smoke tests. On your iPhone, iOS
            simulators and Android, from one native Mac app. Free and open source.
          </p>
          <div
            className="rise mt-7 flex flex-wrap items-center justify-center gap-x-7 gap-y-3"
            style={{ "--rise-delay": "360ms" } as CSSProperties}
          >
            <a href="/download" className={buttonPrimary}>
              Download for Mac
            </a>
            <a href="#toolkit" className={moreLink}>
              See what’s inside ›
            </a>
          </div>
          <p className="rise mt-4 text-[13px] text-faint" style={{ "--rise-delay": "440ms" } as CSSProperties}>
            Free. Updates itself. Requires macOS 26.
          </p>
        </div>

        {/* Chapter 2: three kinds of device */}
        <StoryText refCallback={chapter("devices")} style={hidden} title={<>iPhone. Simulator.<br />Android.</>}>
          Every device in one list, and every device takes the same 23 tools.
        </StoryText>
        {labels.map((label, k) => (
          <div
            key={label.name}
            ref={(node) => {
              labelRefs.current[k] = node;
            }}
            aria-hidden="true"
            className="pointer-events-none absolute left-0 top-0 mt-3 whitespace-nowrap text-center opacity-0"
          >
            <p className="text-[15px] font-semibold sm:text-[17px]">{label.name}</p>
            <p className="text-[12px] text-muted sm:text-[13px]">{label.needs}</p>
          </div>
        ))}

        {/* Chapter 3: agents at work */}
        <StoryText refCallback={chapter("agent")} style={hidden} title={<>Your agent drives.</>}>
          Claude Code, Codex, Cursor or any MCP client sees, taps and types on every phone. You watch it happen.
        </StoryText>
        <div
          ref={chapter("agent", "activity")}
          style={hidden}
          aria-hidden="true"
          className="absolute inset-x-0 bottom-[5svh] flex justify-center px-5"
        >
          <div className="story-glass w-full max-w-sm rounded-3xl p-4 text-left">
            <p className="px-1 text-[12px] font-semibold text-faint">Activity</p>
            <ol className="mt-2 space-y-1.5">
              {activity.map((entry) => (
                <li key={entry.id} className="activity-row flex items-center gap-3 rounded-2xl bg-mist px-3 py-2">
                  <span className="size-2 shrink-0 rounded-full bg-[#34c759]" />
                  <p className="min-w-0 flex-1 truncate text-[14px]">
                    <span className="font-semibold">{entry.tool}</span> <span className="text-muted">{entry.detail}</span>
                  </p>
                  <span className="shrink-0 text-[12px] text-faint">{entry.device}</span>
                </li>
              ))}
            </ol>
          </div>
        </div>

        {touches.map((touch) => (
          <span key={touch.id} aria-hidden="true" className="touch" style={{ left: touch.x, top: touch.y }} />
        ))}

        {/* Chapter 4: from anywhere */}
        <StoryText refCallback={chapter("anywhere")} style={hidden} title={<>From anywhere.</>}>
          Agents on other machines reach your Mac through a relay. Your Mac keeps one outgoing connection, so no port is
          ever opened.{" "}
          <a href="#desk" className="text-link hover:underline underline-offset-4">
            Remote access ›
          </a>
        </StoryText>
      </div>
    </section>
  );
}

function StoryText({
  refCallback,
  style,
  title,
  children,
}: {
  refCallback: (node: HTMLDivElement | null) => void;
  style: CSSProperties;
  title: ReactNode;
  children: ReactNode;
}) {
  return (
    <div ref={refCallback} style={style} className="absolute inset-x-0 top-[calc(48px+5svh)] px-5 text-center will-change-transform sm:top-[calc(48px+7svh)]">
      <h2 className="headline text-balance mx-auto max-w-3xl text-[40px] sm:text-[min(64px,7.5svh)]">{title}</h2>
      <p className="text-balance mx-auto mt-4 max-w-xl text-[17px] leading-[1.45] text-muted sm:text-[19px]">{children}</p>
    </div>
  );
}
