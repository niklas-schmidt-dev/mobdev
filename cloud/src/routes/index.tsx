import { Link, createFileRoute } from "@tanstack/react-router";
import { AppMock } from "../components/app-mock";
import { Code, Page } from "../components/site";

export const Route = createFileRoute("/")({
  component: Home,
});

const steps = [
  {
    title: "The screen, over USB",
    body: "Your iPhone shows up on the Mac like it does for QuickTime. Mobdev reads each frame. No app, no developer mode.",
  },
  {
    title: "Taps, over Bluetooth",
    body: "The Mac pairs as a keyboard and pointer. With AssistiveTouch on, iOS turns its clicks into taps and swipes.",
  },
  {
    title: "Your agent, over MCP",
    body: "Claude Code, Codex, Cursor or any MCP client gets screenshot, tap, type, open_app and tap_text.",
  },
];

const features = [
  ["Real apps, real accounts", "Agents use the App Store, iMessage, Wallet and your logins, because it is your phone."],
  ["Finds text on screen", "tap_text and read_screen use Apple’s Vision framework on the Mac. Fewer screenshots, fewer tokens."],
  ["Live mirror", "Click to tap, drag to swipe and type on the phone yourself while the agent works."],
  ["Every action logged", "The Activity view shows each tool call, from this Mac or from far away."],
  ["Reach it from anywhere", "Turn on remote access and agents on other machines connect through a relay. No open ports."],
  ["2 MB, native", "A SwiftUI app with Liquid Glass. No Electron, no account needed, no telemetry."],
];

const faqs = [
  [
    "Does the iPhone need developer mode or an app?",
    "No. Mobdev only uses the USB screen feed and a Bluetooth keyboard and pointer, which iOS supports for everyone. Turn on AssistiveTouch once.",
  ],
  [
    "What do I need?",
    "A Mac with macOS 26 or later, an iPhone and a USB data cable. The phone stays plugged in and unlocked while agents work.",
  ],
  [
    "Where do my screenshots go?",
    "Nowhere, unless your agent sends them to its model. Mobdev keeps everything on your Mac. The relay passes requests through and stores nothing.",
  ],
  [
    "Can I run the relay myself?",
    "Yes. The relay is a small Go server in the repository, or a Docker image. The hosted relay just saves you the setup.",
  ],
  [
    "How many phones?",
    "As many as you plug in, for free. Today Mobdev drives one phone per Mac; several Macs can share one account.",
  ],
];

function Home() {
  return (
    <Page>
      {/* Hero */}
      <section className="relative overflow-hidden">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 -top-40 h-[640px] bg-[radial-gradient(60%_50%_at_50%_30%,rgba(209,237,165,0.16),transparent_70%)]"
        />
        <div className="relative mx-auto max-w-6xl px-5 pb-20 pt-20 text-center sm:pt-28">
          <p className="glass mx-auto mb-7 inline-flex items-center gap-2 rounded-full px-3.5 py-1 text-xs text-muted">
            <span className="size-1.5 rounded-full bg-lime" />
            Free and open source · Early release
          </p>
          <h1 className="text-balance mx-auto max-w-4xl font-display text-5xl font-semibold tracking-[-0.035em] sm:text-7xl">
            Give your AI agent a real iPhone.
          </h1>
          <p className="text-balance mx-auto mt-6 max-w-2xl text-lg leading-relaxed text-muted sm:text-xl">
            Mobdev lets Claude Code, Codex and any MCP agent see and tap the iPhone on your desk. Nothing to install on
            the phone. No per-device fees.
          </p>
          <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
            <Link
              to="/docs"
              hash="install"
              className="rounded-full bg-lime px-6 py-3 font-medium text-ink transition hover:bg-lime-strong"
            >
              Get Mobdev for Mac
            </Link>
            <Link to="/docs" className="glass rounded-full px-6 py-3 font-medium transition hover:bg-white/10">
              How it works
            </Link>
          </div>
          <p className="mt-4 text-xs text-faint">macOS 26 or later · iPhone with a USB data cable</p>
          <div className="mt-16">
            <AppMock />
          </div>
        </div>
      </section>

      {/* How it works */}
      <section className="mx-auto max-w-6xl px-5 py-20">
        <h2 className="text-balance max-w-2xl font-display text-3xl font-semibold tracking-tight sm:text-4xl">
          Three ordinary connections. No tricks on the phone.
        </h2>
        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {steps.map((step, index) => (
            <div key={step.title} className="glass rounded-3xl p-6">
              <p className="font-mono text-xs text-lime">0{index + 1}</p>
              <h3 className="mt-3 text-lg font-semibold">{step.title}</h3>
              <p className="mt-2 leading-relaxed text-muted">{step.body}</p>
            </div>
          ))}
        </div>
        <div className="mt-8 grid items-center gap-6 rounded-3xl border border-white/10 bg-ink-raised p-6 md:grid-cols-[1fr_1.1fr] md:p-8">
          <div>
            <h3 className="text-xl font-semibold">One line to connect Claude Code</h3>
            <p className="mt-2 leading-relaxed text-muted">
              The app shows the exact command for your agent. No token in the config: Mobdev reads it locally and
              starts in the background when your agent calls it.
            </p>
          </div>
          <Code>{"claude mcp add --scope user mobdev -- \\\n  /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
        </div>
      </section>

      {/* Features */}
      <section className="mx-auto max-w-6xl px-5 py-20">
        <h2 className="text-balance max-w-2xl font-display text-3xl font-semibold tracking-tight sm:text-4xl">
          Built for agents. Pleasant for people.
        </h2>
        <div className="mt-10 grid gap-px overflow-hidden rounded-3xl border border-white/10 bg-white/10 sm:grid-cols-2 lg:grid-cols-3">
          {features.map(([title, body]) => (
            <div key={title} className="bg-ink p-6">
              <h3 className="font-semibold">{title}</h3>
              <p className="mt-2 leading-relaxed text-muted">{body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Pricing */}
      <section id="pricing" className="mx-auto max-w-6xl scroll-mt-20 px-5 py-20">
        <h2 className="text-balance max-w-2xl font-display text-3xl font-semibold tracking-tight sm:text-4xl">
          Your phone. Your Mac. No meter running.
        </h2>
        <p className="mt-4 max-w-2xl leading-relaxed text-muted">
          You already own the hardware. Mobdev does not charge per device, and the hosted relay is free while it is in
          beta. Prefer your own server? Run the relay yourself.
        </p>
        <div className="mt-10 grid gap-4 lg:grid-cols-3">
          <div className="rounded-3xl border border-lime/40 bg-lime/[0.06] p-7">
            <h3 className="text-lg font-semibold">Mobdev</h3>
            <p className="mt-4 font-display text-5xl font-semibold tracking-tight">$0</p>
            <p className="mt-1 text-sm text-muted">any number of phones</p>
            <ul className="mt-6 space-y-2 text-sm text-paper/90">
              <li>Mac app, MCP and HTTP API</li>
              <li>Hosted relay, free during beta</li>
              <li>Self-hosted relay, MIT licensed</li>
            </ul>
            <Link
              to="/dashboard"
              className="mt-7 inline-block rounded-full bg-lime px-5 py-2.5 text-sm font-medium text-ink hover:bg-lime-strong"
            >
              Create a free account
            </Link>
          </div>
          <div className="rounded-3xl border border-white/10 p-7">
            <h3 className="text-lg font-semibold text-muted">TapKit</h3>
            <p className="mt-4 font-display text-5xl font-semibold tracking-tight">$49</p>
            <p className="mt-1 text-sm text-muted">per phone, per month</p>
            <p className="mt-6 text-sm leading-relaxed text-muted">
              Same approach on your own Mac and iPhone. Commands and screenshots go through their cloud.
            </p>
          </div>
          <div className="rounded-3xl border border-white/10 p-7">
            <h3 className="text-lg font-semibold text-muted">MobAI</h3>
            <p className="mt-4 font-display text-5xl font-semibold tracking-tight">$9.99</p>
            <p className="mt-1 text-sm text-muted">per month for more than one device</p>
            <p className="mt-6 text-sm leading-relaxed text-muted">
              Test automation workbench for iOS and Android. Closed source.
            </p>
          </div>
        </div>
        <p className="mt-4 text-xs text-faint">Other prices as listed on the vendors’ websites in September 2026.</p>
      </section>

      {/* FAQ */}
      <section className="mx-auto max-w-3xl px-5 py-20">
        <h2 className="font-display text-3xl font-semibold tracking-tight sm:text-4xl">Questions</h2>
        <div className="mt-8 divide-y divide-white/10 border-y border-white/10">
          {faqs.map(([question, answer]) => (
            <details key={question} className="group py-5">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium">
                {question}
                <span className="text-faint transition group-open:rotate-45">+</span>
              </summary>
              <p className="mt-3 leading-relaxed text-muted">{answer}</p>
            </details>
          ))}
        </div>
      </section>
    </Page>
  );
}
