import { Link, createFileRoute } from "@tanstack/react-router";
import type { CSSProperties } from "react";
import { FREE_PLAN, PRO_PLAN, allowanceText } from "../../shared/plans";
import { AppMock } from "../components/app-mock";
import { LitText, Tilt, useReveal } from "../components/scroll-effects";
import { Code, Icon, Page, buttonPrimary, buttonSecondary, moreLink } from "../components/site";
import { Story } from "../components/story";
import { GITHUB_URL } from "../lib/releases";

export const Route = createFileRoute("/")({
  component: Home,
});

/** The toolkit at a glance, under the hero. Each links to the section that covers it. */
const toolkit = [
  { icon: "sparkle", title: "AI control", body: "Agents see, tap and type on any phone.", href: "#agents" },
  { icon: "devices", title: "Every device", body: "iPhone, Simulator and Android in one list.", href: "#devices" },
  { icon: "terminal", title: "Build and run", body: "Install builds, launch apps, open deep links.", href: "#build" },
  { icon: "bug", title: "Debug", body: "Logs and crash reports, straight to your agent.", href: "#build" },
  { icon: "check", title: "Test", body: "Recorded flows, CI runs and smoke tests.", href: "#test" },
  { icon: "search", title: "Research", body: "Competing apps and their paywalls, on a real iPhone.", href: "#test" },
  { icon: "pointer", title: "Live mirror", body: "Click, swipe and type from your Mac.", href: "#desk" },
  { icon: "globe", title: "Remote", body: "Every Mac and its phones, from anywhere.", href: "#desk" },
] as const;

const devices = [
  {
    icon: "phone",
    title: "iPhone.",
    body: "The screen comes over the USB cable, taps and typing over Bluetooth. No developer mode and no app on the phone, so every app works: the App Store, Messages, Wallet.",
    needs: "a USB data cable",
  },
  {
    icon: "devices",
    title: "iOS Simulator.",
    body: "Every booted simulator appears on its own. Install the build you just made and drive it like a user.",
    needs: "Xcode",
  },
  {
    icon: "phones",
    title: "Android.",
    body: "Emulators and Android phones take the same tools: screenshots, taps, APK installs, logs and crash reports.",
    needs: "adb from the Android SDK",
  },
] as const;

/** A drawing of an agent's dev loop on a simulator: run, crash, read, fix, verify. */
const trace = [
  { tool: "install_app", input: "build/Notes.app", result: "Installed com.example.notes", tone: "ok" },
  { tool: "tap_text", input: "“Save”", result: "Tapped “Save”", tone: "ok" },
  { tool: "logs", input: "com.example.notes", result: "Fatal error: Index out of range", tone: "error" },
  { tool: "crash_reports", input: "Notes", result: "Crashed in NoteStore.save(_:), line 42", tone: "error" },
  { tool: "install_app", input: "build/Notes.app", result: "Installed the fix", tone: "ok" },
  { tool: "tap_text", input: "“Save”", result: "Saved. No errors in the logs.", tone: "ok" },
] as const;

const developerTools = ["install_app", "launch_app", "stop_app", "open_url", "logs", "crash_reports", "list_apps", "uninstall_app"];

const skills = [
  {
    icon: "check",
    title: "Smoke tests.",
    body: "Walks the critical paths on each device, keeps a screenshot of every step and writes a pass/fail report.",
    prompt: "Smoke-test the new build on the simulator and the Pixel.",
  },
  {
    icon: "list",
    title: "Onboarding audits.",
    body: "Every first-run screen from launch to first value, scored for friction, with concrete fixes.",
    prompt: "Audit our onboarding on my iPhone.",
  },
  {
    icon: "search",
    title: "Competitor research.",
    body: "App Store listings, ratings and prices, then the onboarding and paywalls of the apps themselves.",
    prompt: "Compare the top five habit trackers on the App Store.",
  },
  {
    icon: "terminal",
    title: "The dev loop.",
    body: "Build, install, run and debug until the fix is verified on the device, not just in the compiler.",
    prompt: "Run it on my iPhone and find out why it crashes.",
  },
] as const;

/** The roadmap in "Coming next". Keep the statuses honest; move shipped items into the page above. */
type RoadmapStatus = "Next" | "Planned";

const roadmap = [
  {
    icon: "tree",
    status: "Planned" as RoadmapStatus,
    title: "UI tree on iPhones.",
    body: "Tap elements by identifier on developer-mode iPhones too, as on simulators and Android today.",
  },
  {
    icon: "replay",
    status: "Planned" as RoadmapStatus,
    title: "A video of every run.",
    body: "Keep a recording of each flow run, in the app and in CI.",
  },
  {
    icon: "browser",
    status: "Planned" as RoadmapStatus,
    title: "Live view in the browser.",
    body: "Watch and take over a phone from the dashboard, and share devices with your team.",
  },
] as const;

const faqs = [
  [
    "Does it replace Xcode or Android Studio?",
    "No. Keep building with Xcode, Android Studio, Gradle or XcodeBuildMCP. Mobdev takes over once there is a build: it installs it on a device, runs it, drives it and reads its logs and crash reports.",
  ],
  [
    "Does the iPhone need developer mode or an app?",
    "No. Mobdev only uses the USB screen feed and a Bluetooth keyboard and pointer, which every iPhone supports. You turn on AssistiveTouch once. Only the optional tools for your own apps, such as installing builds and reading their logs, need Developer Mode and Xcode.",
  ],
  [
    "Does it work with the Simulator and Android?",
    "Yes. Booted iOS simulators and Android emulators and phones appear next to your iPhones and take the same tools, installing and reading logs included. Simulators need Xcode, Android needs adb from the Android SDK. Nothing is installed on them.",
  ],
  [
    "Do I need an AI agent?",
    "No. Every device gets a live mirror in the app that you can click, swipe and type on. Agents add the automation: Claude Code, Codex, Cursor or any MCP client, or a script that calls the HTTP API.",
  ],
  [
    "What do I need?",
    "A Mac with macOS 26 or later. For an iPhone, a USB data cable; the phone stays plugged in and unlocked while agents work. For simulators and Android, Xcode or the Android SDK is enough.",
  ],
  [
    "Where do my screenshots go?",
    "Nowhere, unless your agent sends them to its model. Mobdev keeps everything on your Mac. The relay passes requests through and stores nothing.",
  ],
  [
    "Can I run the relay myself?",
    "Yes. It is a small Go server in the repository, or a Docker image. The hosted relay just saves you the setup.",
  ],
  [
    "How many phones can I use?",
    `As many as you own, for free. One Mac drives several iPhones, simulators and Android devices at once. Through the hosted relay, Free connects ${FREE_PLAN.macs} Mac and ${PRO_PLAN.name} ${PRO_PLAN.macs}.`,
  ],
  [
    "What counts toward the hosted relay’s limits?",
    "Each request an agent sends to your Mac through the relay, and the time your Mac spends answering it. A connected Mac that waits costs nothing. Mobdev on the Mac itself and a relay you run yourself have no limits.",
  ],
] as const;

/** Marks an element to fade in as it scrolls into view; `order` staggers the items of a grid. */
const reveal = (order = 0) => ({ "data-reveal": "", style: { "--reveal-delay": `${order * 70}ms` } as CSSProperties });

/** A gray section; in dark mode it turns into the page with hairlines above and below. */
const mistSection = "bg-mist dark:border-y dark:border-line dark:bg-page";
/** A card on a white section, or a well inside a card. */
const mistCard = "rounded-3xl bg-mist p-8 dark:inset-ring dark:inset-ring-white/5";
/** A card on a gray section. */
const whiteCard = "rounded-3xl bg-card p-8 dark:inset-ring dark:inset-ring-white/5";

function Home() {
  useReveal();
  return (
    <Page>
      <Story />

      {/* The toolkit at a glance */}
      <section id="toolkit" className={`scroll-mt-12 px-5 py-24 sm:py-32 ${mistSection}`}>
        <div className="mx-auto max-w-5xl">
          <h2 {...reveal()} className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">
            One app.
            <br />
            Every step.
          </h2>
          <p {...reveal(1)} className="text-balance mx-auto mt-6 max-w-2xl text-center text-[19px] leading-[1.45] text-muted">
            Mobdev covers everything that happens on the device, for you and for your agent. Keep building the way you
            do; Mobdev takes it from there.
          </p>
          <div className="mt-14 sm:mt-20">
            <Tilt>
              <AppMock />
            </Tilt>
          </div>
          <ul className="mt-14 grid grid-cols-2 gap-3 sm:mt-20 sm:gap-5 lg:grid-cols-4">
            {toolkit.map((item, index) => (
              <li key={item.title} {...reveal(index % 4)}>
                <a
                  href={item.href}
                  className="flex h-full flex-col rounded-3xl bg-card p-5 transition-transform duration-200 hover:scale-[1.02] motion-reduce:hover:scale-100 sm:p-7 dark:inset-ring dark:inset-ring-white/5"
                >
                  <Icon name={item.icon} className="size-7 text-tint" />
                  <span className="mt-5 text-[17px] font-semibold tracking-tight">{item.title}</span>
                  <span className="mt-1 text-[15px] leading-[1.4] text-muted">{item.body}</span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* Devices */}
      <section id="devices" className="scroll-mt-12 px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 {...reveal()} className="headline text-balance max-w-3xl text-[40px] sm:text-[56px]">
            Plug it in.
            <br />
            It shows up.
          </h2>
          <p className="text-balance mt-6 max-w-2xl text-[19px] leading-[1.45] text-muted">
            Plug in an iPhone, boot a simulator or start an emulator, and it shows up in Mobdev. Every device takes the
            same 27 tools, so one agent can test on all of them in one session.
          </p>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            {devices.map((device, index) => (
              <div key={device.title} {...reveal(index)} className={`flex flex-col ${mistCard}`}>
                <Icon name={device.icon} className="size-8 text-tint" />
                <h3 className="mt-6 text-[21px] font-semibold tracking-tight">{device.title}</h3>
                <p className="mt-2 flex-1 text-[17px] leading-[1.47] text-muted">{device.body}</p>
                <p className="mt-6 border-t border-line pt-4 text-[13px] text-muted">
                  Needs <span className="text-ink">{device.needs}</span>
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Statement */}
      <section className="bg-black px-5 py-28 text-center text-white sm:py-40 dark:border-b dark:border-line">
        <LitText
          className="headline text-balance mx-auto max-w-4xl text-[40px] sm:text-[64px]"
          parts={[
            "Every phone you own.",
            "\n",
            "Every tool you need.",
            "\n",
            <span className="shine bg-clip-text text-transparent">No per-device fees.</span>,
          ]}
        />
        <p {...reveal()} className="text-balance mx-auto mt-8 max-w-xl text-[19px] leading-[1.45] text-[#a1a1a6]">
          You bring the Mac and the phones. Mobdev brings the rest, free and open source.
        </p>
      </section>

      {/* AI control */}
      <section id="agents" className="scroll-mt-12 px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <p {...reveal()} className="text-[17px] font-semibold text-tint">AI control</p>
          <h2 {...reveal()} className="headline text-balance mt-2 max-w-3xl text-[40px] sm:text-[56px]">
            Hand every phone
            <br />
            to your agent.
          </h2>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            <div className={`${mistCard} md:col-span-2`}>
              <Icon name="bolt" className="size-8 text-tint" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Connect Claude Code in one line.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                The app shows the exact command for your agent. No token in the config: Mobdev reads it locally and
                starts in the background when your agent calls.
              </p>
              <div className="mt-6">
                <Code surface="white">{"claude mcp add --scope user mobdev -- \\\n  /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
              </div>
            </div>
            <div className={`flex flex-col ${mistCard}`}>
              <p className="headline text-[64px] text-ink">27</p>
              <p className="mt-auto text-[17px] leading-[1.47] text-muted">
                tools, from <span className="text-ink">tap</span> and <span className="text-ink">tap_text</span> to{" "}
                <span className="text-ink">install_app</span> and <span className="text-ink">logs</span>.
              </p>
            </div>
            <div className={mistCard}>
              <Icon name="text" className="size-8 text-tint" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Reads the screen.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                On-device text recognition finds buttons by their label. Fewer screenshots, fewer tokens.
              </p>
            </div>
            <div className={mistCard}>
              <Icon name="sparkle" className="size-8 text-tint" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Any agent.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                Claude Code, Codex, Cursor, Claude Desktop and every other MCP client. Scripts use the HTTP API.
              </p>
            </div>
            <div className={mistCard}>
              <Icon name="devices" className="size-8 text-tint" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Many devices.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                <span className="text-ink">list_devices</span> shows every device and <span className="text-ink">device</span> picks one. Check the iPhone and the Pixel in one session.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Build, run, debug */}
      <section id="build" className={`scroll-mt-12 px-5 py-24 sm:py-32 ${mistSection}`}>
        <div className="mx-auto max-w-5xl">
          <p {...reveal()} className="text-[17px] font-semibold text-tint">Build, run and debug</p>
          <h2 {...reveal()} className="headline text-balance mt-2 max-w-3xl text-[40px] sm:text-[56px]">
            Install. Run. Debug.
            <br />
            On the device.
          </h2>
          <div className="mt-14 grid grid-cols-1 gap-5 lg:grid-cols-5">
            <div className="rounded-3xl bg-card p-5 sm:p-8 lg:col-span-3 dark:inset-ring dark:inset-ring-white/5">
              <p className="text-[13px] font-semibold text-faint">Activity · iPhone 17 Pro simulator</p>
              <ol className="mt-4 space-y-2">
                {trace.map((step, index) => (
                  <li key={index} className="flex gap-3 rounded-2xl bg-mist px-4 py-3">
                    <span
                      className={`mt-[7px] size-2 shrink-0 rounded-full ${step.tone === "error" ? "bg-danger" : "bg-[#34c759]"}`}
                    />
                    <div className="min-w-0 text-[15px] leading-[1.4]">
                      <p className="truncate">
                        <span className="font-semibold">{step.tool}</span>{" "}
                        <span className="text-muted">{step.input}</span>
                      </p>
                      <p className={step.tone === "error" ? "text-alert-ink" : "text-muted"}>{step.result}</p>
                    </div>
                  </li>
                ))}
              </ol>
            </div>
            <div className="flex flex-col gap-5 lg:col-span-2">
              <div className={`flex-1 ${whiteCard}`}>
                <h3 className="text-[21px] font-semibold tracking-tight">The whole loop, for your agent.</h3>
                <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                  Point it at a build. It installs and launches the app, taps through it, reads what the app prints and
                  finds the crash. Then it tries the fix, on the same device.
                </p>
                <ul className="mt-6 flex flex-wrap gap-2">
                  {developerTools.map((tool) => (
                    <li key={tool} className="rounded-full bg-mist px-3 py-1 text-[13px] font-medium">
                      {tool}
                    </li>
                  ))}
                </ul>
              </div>
              <div className={whiteCard}>
                <p className="text-[15px] leading-[1.47] text-muted">
                  Keep building with Xcode, Gradle or XcodeBuildMCP. On an iPhone these tools need Developer Mode;
                  simulators and Android work as they are.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Test and research */}
      <section id="test" className="scroll-mt-12 px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <p {...reveal()} className="text-[17px] font-semibold text-tint">Test and research</p>
          <h2 {...reveal()} className="headline text-balance mt-2 max-w-3xl text-[40px] sm:text-[56px]">
            Ask for a test.
            <br />
            Get a report.
          </h2>
          <p className="text-balance mt-6 max-w-2xl text-[19px] leading-[1.45] text-muted">
            Skills turn the tools into whole workflows. Add them once, then ask your agent in plain words. They stop
            and ask before anything that pays, sends, deletes or uses real accounts.
          </p>
          <div className="mt-8 max-w-xl">
            <Code>npx skills add niklas-schmidt-dev/mobdev</Code>
          </div>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            <div {...reveal()} className={`${mistCard} md:col-span-2`}>
              <Icon name="replay" className="size-8 text-tint" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Record once. Replay anywhere.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                Click Record, then use the app yourself or let your agent work. Mobdev saves the steps as a flow and
                replays it from the app, from your agent or in CI, and stops at the first step that fails.
              </p>
              <div className="mt-6">
                <Code surface="white">{"Mobdev flow sign-in.json --device \"$UDID\""}</Code>
              </div>
            </div>
            <div {...reveal(1)} className={mistCard}>
              <Icon name="tree" className="size-8 text-tint" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Tap by identifier.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                On simulators and Android, agents read the UI tree and tap elements by their accessibility identifier.
                Recorded clicks become identifiers too, so flows survive layout changes.
              </p>
            </div>
          </div>
          <div className="mt-5 grid grid-cols-1 gap-5 md:grid-cols-2">
            {skills.map((skill, index) => (
              <div key={skill.title} {...reveal(index % 2)} className={`flex flex-col ${mistCard}`}>
                <Icon name={skill.icon} className="size-8 text-tint" />
                <h3 className="mt-6 text-[21px] font-semibold tracking-tight">{skill.title}</h3>
                <p className="mt-2 flex-1 text-[17px] leading-[1.47] text-muted">{skill.body}</p>
                <p className="mt-6 self-start rounded-2xl rounded-bl-md bg-card px-4 py-2.5 text-[15px] leading-[1.4] shadow-sm ring-1 ring-black/5 dark:shadow-none dark:ring-white/5">
                  {skill.prompt}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* At your desk, or anywhere */}
      <section id="desk" className={`scroll-mt-12 px-5 py-24 sm:py-32 ${mistSection}`}>
        <div className="mx-auto max-w-5xl">
          <h2 {...reveal()} className="headline text-balance max-w-3xl text-[40px] sm:text-[56px]">
            At your desk.
            <br />
            Or anywhere.
          </h2>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            <div className={`${whiteCard} md:col-span-2`}>
              <Icon name="pointer" className="size-8 text-tint" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Take the controls.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                Every device gets a live mirror: click to tap, drag to swipe, scroll, and type with your Mac’s keyboard.
                ⌘V types the clipboard. Take over whenever the agent needs a hand.
              </p>
            </div>
            <div className={`flex flex-col ${whiteCard}`}>
              <p className="headline text-[64px] text-ink">3 MB</p>
              <p className="mt-auto text-[17px] leading-[1.47] text-muted">
                A native SwiftUI app with Liquid Glass. No Electron, no account, no telemetry.
              </p>
            </div>
            <div className={whiteCard}>
              <Icon name="list" className="size-8 text-tint" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Every action logged.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                See each tool call in the app, on every device, from this Mac or from afar.
              </p>
            </div>
            <div className={`${whiteCard} md:col-span-2`}>
              <Icon name="globe" className="size-8 text-tint" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Reach it from anywhere.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                Turn on remote access and agents on other machines connect through a relay. Your Mac keeps one outgoing
                connection, so no port is ever opened. The app and the dashboard list every Mac and its phones.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Coming next */}
      <section id="next" className="scroll-mt-12 px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 {...reveal()} className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">Coming next.</h2>
          <p className="text-balance mx-auto mt-6 max-w-2xl text-center text-[19px] leading-[1.45] text-muted">
            The toolkit keeps growing. Free, like everything else.
          </p>
          <ul className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            {roadmap.map((item, index) => (
              <li key={item.title} {...reveal(index)} className={mistCard}>
                <div className="flex items-start justify-between gap-4">
                  <Icon name={item.icon} className="size-8 text-tint" />
                  <span
                    className={`rounded-full px-2.5 py-1 text-[12px] font-medium ${item.status === "Next" ? "bg-blue/10 text-link dark:bg-blue/20" : "bg-card text-muted"}`}
                  >
                    {item.status}
                  </span>
                </div>
                <h3 className="mt-6 text-[21px] font-semibold tracking-tight">{item.title}</h3>
                <p className="mt-2 text-[17px] leading-[1.47] text-muted">{item.body}</p>
              </li>
            ))}
          </ul>
          <p className="mt-10 text-center">
            <a href={GITHUB_URL} className={moreLink}>
              Follow along on GitHub ›
            </a>
          </p>
        </div>
      </section>

      {/* Privacy */}
      <section className={`px-5 py-24 text-center sm:py-32 ${mistSection}`}>
        <Icon name="lock" className="mx-auto size-10 text-ink" />
        <h2 {...reveal()} className="headline text-balance mx-auto mt-6 max-w-3xl text-[40px] sm:text-[56px]">
          Your screen stays on your Mac.
        </h2>
        <p className="text-balance mx-auto mt-6 max-w-2xl text-[19px] leading-[1.45] text-muted">
          Text recognition runs locally. The API only answers on this Mac and needs a token. The relay forwards requests
          and stores nothing, and you can run your own.
        </p>
        <Link to="/privacy" className={`${moreLink} mt-6 inline-block`}>
          Read the privacy details ›
        </Link>
      </section>

      {/* Pricing */}
      <section id="pricing" className="scroll-mt-12 px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 {...reveal()} className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">
            Free. For every phone
            <br />
            you own.
          </h2>
          <p className="text-balance mx-auto mt-6 max-w-2xl text-center text-[19px] leading-[1.45] text-muted">
            You already have the Mac and the phones, so Mobdev never charges per device. {PRO_PLAN.name} is for the
            hosted relay, when agents on other computers need more Macs or more time.
          </p>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-2 lg:grid-cols-4">
            <div className="flex flex-col rounded-3xl p-8 ring-2 ring-blue">
              <p className="text-[21px] font-semibold">{FREE_PLAN.name}</p>
              <p className="headline mt-5 text-[56px]">$0</p>
              <p className="text-[15px] text-muted">for any number of phones</p>
              <ul className="mt-7 flex-1 space-y-3 border-t border-line pt-6 text-[15px]">
                <li>The Mac app with every tool</li>
                <li>iPhones, simulators and Android</li>
                <li>Self-hosted relay, MIT licensed</li>
                <li>
                  Hosted relay for {FREE_PLAN.macs} Mac: {allowanceText(FREE_PLAN)}
                </li>
              </ul>
              <Link to="/dashboard" className={`${buttonPrimary} mt-8 w-full`}>
                Get started
              </Link>
            </div>
            <div className="flex flex-col rounded-3xl p-8 ring-1 ring-line">
              <p className="text-[21px] font-semibold">{PRO_PLAN.name}</p>
              <p className="headline mt-5 text-[56px]">${PRO_PLAN.priceUsd}</p>
              <p className="text-[15px] text-muted">per month, for up to {PRO_PLAN.macs} Macs</p>
              <p className="mt-1 text-[13px] text-muted">USD, plus applicable tax</p>
              <ul className="mt-7 flex-1 space-y-3 border-t border-line pt-6 text-[15px]">
                <li>Everything in {FREE_PLAN.name}</li>
                <li>
                  Hosted relay for {PRO_PLAN.macs} Macs: {allowanceText(PRO_PLAN)}
                </li>
                <li>Cancel any time</li>
              </ul>
              <Link to="/dashboard" className={`${buttonSecondary} mt-8 w-full`}>
                Get {PRO_PLAN.name}
              </Link>
            </div>
            <div className={mistCard}>
              <p className="text-[21px] font-semibold text-muted">TapKit</p>
              <p className="headline mt-5 text-[56px] text-muted">$49</p>
              <p className="text-[15px] text-muted">per phone, per month</p>
              <p className="mt-7 border-t border-line pt-6 text-[15px] leading-[1.47] text-muted">
                Agent control of your iPhone through your own Mac. Commands and screenshots go through their cloud.
              </p>
            </div>
            <div className={mistCard}>
              <p className="text-[21px] font-semibold text-muted">MobAI</p>
              <p className="headline mt-5 text-[56px] text-muted">$9.99</p>
              <p className="text-[15px] text-muted">per month beyond one device</p>
              <p className="mt-7 border-t border-line pt-6 text-[15px] leading-[1.47] text-muted">
                A test automation workbench for iOS and Android. Closed source.
              </p>
            </div>
          </div>
          <p className="mt-6 text-center text-[12px] text-faint">
            Other prices as listed on the vendors’ websites in September 2026.
          </p>
        </div>
      </section>

      {/* FAQ */}
      <section className={`px-5 py-24 sm:py-32 ${mistSection}`}>
        <div className="mx-auto max-w-3xl">
          <h2 {...reveal()} className="headline text-center text-[40px] sm:text-[56px]">Questions? Answers.</h2>
          <div className="mt-12 divide-y divide-line border-y border-line">
            {faqs.map(([question, answer]) => (
              <details key={question} className="group">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-6 py-6 text-[19px] font-semibold tracking-tight">
                  {question}
                  <span
                    aria-hidden="true"
                    className="text-[24px] font-light text-muted transition-transform duration-200 group-open:rotate-45"
                  >
                    +
                  </span>
                </summary>
                <p className="-mt-2 pb-6 text-[17px] leading-[1.47] text-muted">{answer}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* Closing */}
      <section className="px-5 py-24 text-center sm:py-32">
        <h2 {...reveal()} className="headline text-balance mx-auto max-w-3xl text-[40px] sm:text-[56px]">
          Every phone.
          <br />
          One toolkit.
        </h2>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-x-7 gap-y-4">
          <a href="/download" className={buttonPrimary}>
            Download for Mac
          </a>
          <Link to="/docs" className={moreLink}>
            Read the docs ›
          </Link>
        </div>
      </section>
    </Page>
  );
}
