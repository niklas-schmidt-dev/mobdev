import { Link, createFileRoute } from "@tanstack/react-router";
import { AppMock } from "../components/app-mock";
import { Code, Icon, Page, buttonPrimary, moreLink } from "../components/site";
import { GITHUB_URL } from "../lib/releases";

export const Route = createFileRoute("/")({
  component: Home,
});

const steps = [
  {
    icon: "plug",
    title: "The screen, over USB.",
    body: "Your iPhone shows up on the Mac the way it does for QuickTime. Mobdev reads every frame.",
  },
  {
    icon: "bluetooth",
    title: "Taps, over Bluetooth.",
    body: "The Mac pairs as a keyboard and pointer. With AssistiveTouch on, iOS turns clicks into taps.",
  },
  {
    icon: "sparkle",
    title: "Your agent, over MCP.",
    body: "Claude Code, Codex, Cursor or any MCP client can see, tap, type and open apps.",
  },
] as const;

/** The roadmap in "Coming next". Keep the statuses honest; move shipped items into the page above. */
const roadmap = [
  {
    icon: "phones",
    status: "Just shipped",
    title: "Many iPhones, one device hub.",
    body: "Drive several iPhones from one Mac, and see the iPhones on all your Macs in one list.",
  },
  {
    icon: "devices",
    status: "Next",
    title: "Simulators and Android.",
    body: "The same tools for the iOS Simulator, Android emulators and Android phones.",
  },
  {
    icon: "terminal",
    status: "Next",
    title: "Install, launch, logs.",
    body: "Install builds, launch apps by bundle ID, open deep links, stream logs and crash reports.",
  },
  {
    icon: "tree",
    status: "Planned",
    title: "UI element tree.",
    body: "Tap elements by identifier instead of pixels, on simulators, Android and developer-mode iPhones.",
  },
  {
    icon: "replay",
    status: "Planned",
    title: "Flows and CI.",
    body: "Turn an agent session into a replayable test, run it in CI, keep a video of every run.",
  },
  {
    icon: "browser",
    status: "Planned",
    title: "Live view in the browser.",
    body: "Watch and take over a phone from the dashboard, and share devices with your team.",
  },
] as const;

const faqs = [
  [
    "Does the iPhone need developer mode or an app?",
    "No. Mobdev only uses the USB screen feed and a Bluetooth keyboard and pointer, which every iPhone supports. You turn on AssistiveTouch once.",
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
    "Yes. It is a small Go server in the repository, or a Docker image. The hosted relay just saves you the setup.",
  ],
  [
    "How many phones can I use?",
    "As many as you own, for free. One Mac drives several iPhones at once, and one account connects several Macs.",
  ],
] as const;

function Home() {
  return (
    <Page>
      {/* Hero */}
      <section className="px-5 pb-24 pt-20 text-center sm:pt-28">
        <p className="text-[21px] font-semibold">Mobdev for Mac</p>
        <h1 className="headline text-balance mx-auto mt-2 max-w-3xl text-[48px] sm:text-[80px]">
          Your agent.
          <br />A real iPhone.
        </h1>
        <p className="text-balance mx-auto mt-6 max-w-2xl text-[19px] leading-[1.45] text-muted sm:text-[21px]">
          Mobdev lets Claude Code, Codex and any MCP agent see and tap the iPhone on your desk. Nothing to install on
          the phone. Free and open source.
        </p>
        <div className="mt-9 flex flex-wrap items-center justify-center gap-x-7 gap-y-4">
          <a href="/download" className={buttonPrimary}>
            Download for Mac
          </a>
          <a href="#how" className={moreLink}>
            See how it works ›
          </a>
        </div>
        <p className="mt-5 text-[13px] text-faint">
          Free. Updates itself. Requires macOS 26 and an iPhone with a USB data cable.
        </p>
        <div className="mt-16 sm:mt-20">
          <AppMock />
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="scroll-mt-12 bg-mist px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">
            Three connections.
            <br />
            Nothing on the phone.
          </h2>
          <div className="mt-16 grid grid-cols-1 gap-5 md:grid-cols-3">
            {steps.map((step) => (
              <div key={step.title} className="rounded-3xl bg-white p-8">
                <Icon name={step.icon} className="size-8 text-blue" />
                <h3 className="mt-6 text-[21px] font-semibold tracking-tight">{step.title}</h3>
                <p className="mt-2 text-[17px] leading-[1.47] text-muted">{step.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Statement */}
      <section className="bg-black px-5 py-28 text-center text-white sm:py-40">
        <p className="headline text-balance mx-auto max-w-4xl text-[40px] sm:text-[64px]">
          No developer mode.
          <br />
          No app on the phone.
          <br />
          <span className="bg-gradient-to-r from-[#2997ff] via-[#a78bfa] to-[#ff7ab8] bg-clip-text text-transparent">
            No per-device fees.
          </span>
        </p>
        <p className="text-balance mx-auto mt-8 max-w-xl text-[19px] leading-[1.45] text-[#a1a1a6]">
          Agents use your real apps and accounts: the App Store, Messages, Wallet. Because it is simply your phone.
        </p>
      </section>

      {/* Features */}
      <section className="px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 className="headline text-balance max-w-3xl text-[40px] sm:text-[56px]">
            Made for agents.
            <br />
            Easy for you.
          </h2>
          <div className="mt-14 grid grid-cols-1 gap-5 md:grid-cols-3">
            <div className="rounded-3xl bg-mist p-8 md:col-span-2">
              <Icon name="bolt" className="size-8 text-blue" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Connect Claude Code in one line.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                The app shows the exact command for your agent. No token in the config: Mobdev reads it locally and
                starts in the background when your agent calls.
              </p>
              <div className="mt-6">
                <Code surface="white">{"claude mcp add --scope user mobdev -- \\\n  /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
              </div>
            </div>
            <div className="flex flex-col rounded-3xl bg-mist p-8">
              <p className="headline text-[64px] text-ink">15</p>
              <p className="mt-auto text-[17px] leading-[1.47] text-muted">
                tools, from <span className="text-ink">tap</span> and <span className="text-ink">swipe</span> to{" "}
                <span className="text-ink">open_app</span> and <span className="text-ink">tap_text</span>.
              </p>
            </div>
            <div className="rounded-3xl bg-mist p-8">
              <Icon name="text" className="size-8 text-blue" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Reads the screen.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                On-device text recognition finds buttons by their label. Fewer screenshots, fewer tokens.
              </p>
            </div>
            <div className="rounded-3xl bg-mist p-8">
              <Icon name="phone" className="size-8 text-blue" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Take over anytime.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                The live mirror lets you click, swipe and type on the phone while the agent works.
              </p>
            </div>
            <div className="flex flex-col rounded-3xl bg-mist p-8">
              <p className="headline text-[64px] text-ink">3 MB</p>
              <p className="mt-auto text-[17px] leading-[1.47] text-muted">
                A native SwiftUI app with Liquid Glass. No Electron, no account, no telemetry.
              </p>
            </div>
            <div className="rounded-3xl bg-mist p-8 md:col-span-2">
              <Icon name="globe" className="size-8 text-blue" />
              <h3 className="mt-6 text-[24px] font-semibold tracking-tight">Reach it from anywhere.</h3>
              <p className="mt-2 max-w-lg text-[17px] leading-[1.47] text-muted">
                Turn on remote access and agents on other machines connect through a relay. Your Mac keeps one outgoing
                connection, so no port is ever opened.
              </p>
            </div>
            <div className="rounded-3xl bg-mist p-8">
              <Icon name="list" className="size-8 text-blue" />
              <h3 className="mt-6 text-[21px] font-semibold tracking-tight">Every action logged.</h3>
              <p className="mt-2 text-[17px] leading-[1.47] text-muted">
                See each tool call in the app, from this Mac or from afar.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Coming next */}
      <section id="next" className="scroll-mt-12 bg-mist px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-5xl">
          <h2 className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">Coming next.</h2>
          <p className="text-balance mx-auto mt-6 max-w-2xl text-center text-[19px] leading-[1.45] text-muted">
            Mobdev is becoming a full mobile development platform. Free, like everything else.
          </p>
          <ul className="mt-14 grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {roadmap.map((item) => (
              <li key={item.title} className="rounded-3xl bg-white p-8">
                <div className="flex items-start justify-between gap-4">
                  <Icon name={item.icon} className="size-8 text-blue" />
                  <span
                    className={`rounded-full px-2.5 py-1 text-[12px] font-medium ${item.status === "Just shipped" ? "bg-blue/10 text-link" : "bg-mist text-muted"}`}
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
      <section className="px-5 py-24 text-center sm:py-32">
        <Icon name="lock" className="mx-auto size-10 text-ink" />
        <h2 className="headline text-balance mx-auto mt-6 max-w-3xl text-[40px] sm:text-[56px]">
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
          <h2 className="headline text-balance mx-auto max-w-3xl text-center text-[40px] sm:text-[56px]">
            Free. For every phone
            <br />
            you own.
          </h2>
          <p className="text-balance mx-auto mt-6 max-w-2xl text-center text-[19px] leading-[1.45] text-muted">
            You already have the Mac and the iPhone. Mobdev does not charge per device, and the hosted relay is free
            while it is in beta.
          </p>
          <div className="mt-14 grid grid-cols-1 gap-5 lg:grid-cols-3">
            <div className="rounded-3xl p-8 ring-2 ring-blue">
              <p className="text-[21px] font-semibold">Mobdev</p>
              <p className="headline mt-5 text-[56px]">$0</p>
              <p className="text-[15px] text-muted">for any number of phones</p>
              <ul className="mt-7 space-y-3 border-t border-line pt-6 text-[15px]">
                <li>Mac app, MCP and HTTP API</li>
                <li>Hosted relay, free during beta</li>
                <li>Self-hosted relay, MIT licensed</li>
              </ul>
              <Link to="/dashboard" className={`${buttonPrimary} mt-8 w-full`}>
                Create an account
              </Link>
            </div>
            <div className="rounded-3xl bg-mist p-8">
              <p className="text-[21px] font-semibold text-muted">TapKit</p>
              <p className="headline mt-5 text-[56px] text-muted">$49</p>
              <p className="text-[15px] text-muted">per phone, per month</p>
              <p className="mt-7 border-t border-line pt-6 text-[15px] leading-[1.47] text-muted">
                The same idea on your own Mac and iPhone. Commands and screenshots go through their cloud.
              </p>
            </div>
            <div className="rounded-3xl bg-mist p-8">
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
      <section className="bg-mist px-5 py-24 sm:py-32">
        <div className="mx-auto max-w-3xl">
          <h2 className="headline text-center text-[40px] sm:text-[56px]">Questions? Answers.</h2>
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
        <h2 className="headline text-balance mx-auto max-w-3xl text-[40px] sm:text-[56px]">Hand your agent a phone.</h2>
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
