import { createFileRoute } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { AGENT_BURST, MAX_IN_FLIGHT_PER_MAC } from "../../relay/src/protocol";
import { FREE_PLAN, PRO_PLAN, allowanceText } from "../../shared/plans";
import { Code, Page, buttonPrimary } from "../components/site";
import { pageMeta } from "../lib/meta";
import { GITHUB_URL } from "../lib/releases";

export const Route = createFileRoute("/docs")({
  head: () => ({ meta: pageMeta("Docs — Mobdev", "/docs") }),
  component: Docs,
});

const sections = [
  ["install", "Install"],
  ["iphone", "Set up the iPhone"],
  ["agents", "Connect an agent"],
  ["tools", "Tools"],
  ["developer", "Build, run and debug"],
  ["skills", "Skills"],
  ["remote", "Remote access"],
  ["self-host", "Run your own relay"],
  ["security", "Security and privacy"],
] as const;

const tools = [
  ["list_devices", "", "The iPhones on this Mac: id, name, model, iOS version, ready"],
  ["status", "", "Screen and Bluetooth readiness, screenshot size"],
  ["screenshot", "", "JPEG of the screen"],
  ["tap", "x, y", "Tap a point of the screenshot"],
  ["long_press", "x, y, seconds", "Touch and hold"],
  ["swipe", "from_x, from_y, to_x, to_y, duration", "Drag, e.g. to scroll"],
  ["scroll", "direction, amount, x, y", "Mouse wheel"],
  ["type_text", "text, submit", "Type into the focused field"],
  ["press_key", "key, modifiers", "e.g. space + cmd for Spotlight"],
  ["home", "", "Go to the home screen"],
  ["open_app", "name", "Open an app through Spotlight"],
  ["read_screen", "", "All visible text with positions (on-device OCR)"],
  ["find_text", "text", "Where a label is"],
  ["tap_text", "text, index", "Tap a visible label"],
  ["wait_for_text", "text, timeout, gone", "Wait for text to appear or disappear"],
];

/** Need Developer Mode on the iPhone and Xcode on the Mac. */
const developerTools = [
  ["list_apps", "all", "Apps installed for development, or every app"],
  ["install_app", "path", "Install an .app or .ipa built for iPhone from the Mac"],
  ["uninstall_app", "bundle_id", "Remove an app installed for development"],
  ["launch_app", "bundle_id, arguments, environment, restart", "Launch an app and capture what it prints"],
  ["stop_app", "bundle_id", "Stop a running app"],
  ["open_url", "url", "Open a deep link, universal link or web page"],
  ["logs", "bundle_id, after, lines, contains", "print, NSLog and os_log output, and how the app ended"],
  ["crash_reports", "app, name, limit", "List crash reports, or read one: exception, reason, crashed thread"],
];

function ToolTable({ rows }: { rows: string[][] }) {
  return (
    <div className="overflow-x-auto rounded-2xl bg-mist">
      <table className="w-full text-left text-[15px]">
        <thead className="text-muted">
          <tr>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">Tool</th>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">Arguments</th>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">What it does</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line/70">
          {rows.map(([name, args, what]) => (
            <tr key={name}>
              <td className="px-4 py-2.5 font-semibold text-ink">{name}</td>
              <td className="px-4 py-2.5 text-muted">{args}</td>
              <td className="px-4 py-2.5 text-ink/85">{what}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="scroll-mt-20 border-b border-line pb-14 pt-2 last:border-0">
      <h2 className="text-[28px] font-semibold tracking-tight">{title}</h2>
      <div className="mt-5 space-y-5 text-[17px] leading-[1.6] text-ink/85 [&_a]:text-link [&_a]:underline-offset-4 hover:[&_a]:underline [&_strong]:font-semibold [&_strong]:text-ink">
        {children}
      </div>
    </section>
  );
}

function Docs() {
  return (
    <Page>
      <div className="mx-auto grid max-w-5xl grid-cols-1 gap-12 px-5 py-16 lg:grid-cols-[190px_minmax(0,1fr)]">
        <nav aria-label="On this page" className="hidden lg:block">
          <div className="sticky top-20">
          <p className="mb-3 px-3 text-[12px] font-semibold uppercase tracking-wide text-faint">On this page</p>
          <ul className="space-y-0.5 text-[14px]">
            {sections.map(([id, title]) => (
              <li key={id}>
                <a href={`#${id}`} className="block rounded-lg px-3 py-1.5 text-muted transition-colors hover:bg-mist hover:text-ink">
                  {title}
                </a>
              </li>
            ))}
          </ul>
          </div>
        </nav>
        <article className="min-w-0 max-w-3xl">
          <p className="text-[17px] font-semibold text-blue">Documentation</p>
          <h1 className="headline mt-1 text-[48px]">Mobdev</h1>
          <p className="mt-4 text-[21px] leading-[1.45] text-muted">
            Mobdev reads the iPhone screen over USB and taps and types as a Bluetooth keyboard and pointer. Agents use it
            through MCP or HTTP.
          </p>
          <div className="mt-14 space-y-12">
            <Section id="install" title="Install">
              <p>
                You need a Mac with Bluetooth LE and <strong>macOS 26 or later</strong>, an iPhone and a USB{" "}
                <strong>data</strong> cable. Download the app, open the disk image and drag Mobdev into Applications.
                It is signed and notarized by Apple and updates itself.
              </p>
              <p>
                <a href="/download" className={`${buttonPrimary} !text-white !no-underline`}>
                  Download for Mac
                </a>
              </p>
              <p>
                Allow Bluetooth and Camera when macOS asks. macOS treats the iPhone screen like a camera, which is why
                it asks for camera access. To build it yourself with Xcode 26 or later:
              </p>
              <Code>{`git clone ${GITHUB_URL}\ncd mobdev/macos\nscripts/build-app.sh\nopen build/Mobdev.app`}</Code>
            </Section>

            <Section id="iphone" title="Set up the iPhone">
              <ol className="list-decimal space-y-2 pl-5">
                <li>Plug it in, unlock it and tap <strong>Trust</strong>. If the Mac asks to allow the accessory, click Allow.</li>
                <li>
                  On the iPhone open <strong>Settings › Bluetooth</strong> and tap your Mac under Other Devices. iOS lists it by the Mac’s name.
                </li>
                <li>
                  Turn on <strong>Settings › Accessibility › Touch › AssistiveTouch</strong>. It turns the pointer into
                  taps.
                </li>
                <li>
                  In Mobdev, pick the keyboard layout that matches <strong>Settings › General › Keyboard › Hardware
                  Keyboard</strong> on the iPhone.
                </li>
                <li>Set Auto-Lock to Never while agents work. The phone must stay unlocked.</li>
              </ol>
            </Section>

            <Section id="agents" title="Connect an agent">
              <p>The app shows these with the right paths under Connect. They contain no secret.</p>
              <p className="text-[15px] font-semibold text-ink">Claude Code</p>
              <Code>{"claude mcp add --scope user mobdev -- /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
              <p className="text-[15px] font-semibold text-ink">Codex (~/.codex/config.toml)</p>
              <Code>{'[mcp_servers.mobdev]\ncommand = "/Applications/Mobdev.app/Contents/MacOS/Mobdev"\nargs = ["mcp"]'}</Code>
              <p className="text-[15px] font-semibold text-ink">Claude Desktop, Cursor and others</p>
              <Code>
                {'{\n  "mcpServers": {\n    "mobdev": {\n      "command": "/Applications/Mobdev.app/Contents/MacOS/Mobdev",\n      "args": ["mcp"]\n    }\n  }\n}'}
              </Code>
              <p>
                HTTP clients can use <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">http://127.0.0.1:4686/mcp</code> with the token
                from Settings › API. The server speaks MCP 2026-07-28 and the earlier versions back to 2024-11-05.
              </p>
            </Section>

            <Section id="tools" title="Tools">
              <p>
                Coordinates are pixels of the image <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">screenshot</code> returns (long
                edge 1280 px). Actions return a fresh screenshot unless you pass{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">"screenshot": false</code>. With more
                than one iPhone on the Mac, pass{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">device</code> (an id or name from{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">list_devices</code>) to pick one.
              </p>
              <ToolTable rows={tools} />
            </Section>

            <Section id="developer" title="Build, run and debug">
              <p>
                For apps you build, Mobdev also installs builds, launches them and reads their output and crash
                reports. The agent builds with <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">xcodebuild</code>,
                installs, drives the app with the tools above and reads the logs. These tools use Xcode’s{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">devicectl</code>, so they need{" "}
                <strong>Xcode</strong> on the Mac and <strong>Developer Mode</strong> on the iPhone (Settings ›
                Privacy &amp; Security › Developer Mode). Everything else works without them.
              </p>
              <ToolTable rows={developerTools} />
              <Code>
                {"xcodebuild -scheme MyApp -destination 'generic/platform=iOS' \\\n  -derivedDataPath build -allowProvisioningUpdates build\n# install_app {\"path\": \"…/build/Build/Products/Debug-iphoneos/MyApp.app\"}\n# launch_app  {\"bundle_id\": \"com.example.MyApp\"}\n# logs        {\"bundle_id\": \"com.example.MyApp\"}"}
              </Code>
              <p>
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">logs</code> returns a cursor; pass it as{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">after</code> to get only new lines. When the
                app crashes, <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">logs</code> says so and{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">crash_reports</code> shows the report.
                Paths for <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">install_app</code> are on the Mac
                that runs Mobdev, also through a relay. Mobdev never removes App Store or system apps.
              </p>
            </Section>

            <Section id="skills" title="Skills">
              <p>
                Skills give your agent whole workflows on top of the tools: the build and debug loop, smoke tests,
                onboarding audits and competitor research. They work with Claude Code, Codex, Cursor and other agents
                that read <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">SKILL.md</code> files.
              </p>
              <Code>{"npx skills add niklas-schmidt-dev/mobdev"}</Code>
              <p>
                Or copy a folder from <a href={`${GITHUB_URL}/tree/main/skills`}>skills/</a> into your agent’s skills
                directory.
              </p>
            </Section>

            <Section id="remote" title="Remote access">
              <p>
                To reach the phone from another computer, the Mac keeps an outgoing WebSocket to a relay. No port is
                opened on the Mac, and the relay stores nothing.
              </p>
              <ol className="list-decimal space-y-2 pl-5">
                <li>
                  Sign in to the <a href="/dashboard">dashboard</a> and create an access token.
                </li>
                <li>Click “Open in Mobdev”, or paste the token under Remote Access in the app.</li>
                <li>Copy the remote command from the app and run it on the other computer:</li>
              </ol>
              <Code>
                {'claude mcp add --transport http mobdev-remote \\\n  https://relay.mobdev.sh/h/<mac-name>/mcp \\\n  --header "Authorization: Bearer mdc_…"'}
              </Code>
              <p>
                The client key (<code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">mdc_…</code>) is derived from a secret that never
                leaves your Mac. Anyone with it can control the phone; “New Client Key” in the app revokes it. Revoking
                the access token in the dashboard disconnects the Mac.
              </p>
              <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Limits of the hosted relay</h3>
              <p>
                {FREE_PLAN.name} connects {FREE_PLAN.macs} Mac and includes {allowanceText(FREE_PLAN)}. {PRO_PLAN.name}{" "}
                (${PRO_PLAN.priceUsd} USD a month, plus applicable tax) connects {PRO_PLAN.macs} Macs and includes {allowanceText(PRO_PLAN)}. Active
                time counts while a Mac works on a request; a connected Mac that waits costs nothing. The dashboard shows
                what you used. Mobdev on the Mac and a relay you run yourself have no limits.
              </p>
              <p>When a limit is reached, the relay answers with HTTP 429 and a Retry-After header:</p>
              <ul className="list-disc space-y-2 pl-5">
                <li>
                  More than {AGENT_BURST.limit} requests in {AGENT_BURST.seconds} seconds with one client key.
                </li>
                <li>More than {MAX_IN_FLIGHT_PER_MAC} requests waiting for the same Mac.</li>
                <li>The month’s requests or active time used up. Retry-After points to when they renew.</li>
              </ul>
            </Section>

            <Section id="self-host" title="Run your own relay">
              <p>The relay in the repository speaks the same protocol. It is one Go binary or a small Docker image:</p>
              <Code>{"cd relay\nRELAY_HOST_ACCESS_TOKEN=choose-one go run .\n# or\ndocker build -t mobdev-relay . && docker run -p 8080:8080 mobdev-relay"}</Code>
              <p>
                Put it behind HTTPS and enter its URL in the app. With{" "}
                <code className="rounded bg-mist px-1.5 py-0.5 text-[15px]">RELAY_HOST_ACCESS_TOKEN</code> set, only Macs that know the token
                may connect.
              </p>
            </Section>

            <Section id="security" title="Security and privacy">
              <ul className="list-disc space-y-2 pl-5">
                <li>The local API binds to 127.0.0.1, needs a bearer token and rejects browser requests.</li>
                <li>Text recognition runs on the Mac. No screen content leaves it unless your agent sends it to its model.</li>
                <li>
                  The hosted relay stores your email, hashed access tokens, which Macs are connected and the iPhones they
                  report. Requests and screenshots only pass through memory. See <a href="/privacy">privacy</a>.
                </li>
                <li>
                  Agents act on your real phone with your accounts. Keep a person in the loop for anything that sends
                  messages, pays or deletes.
                </li>
              </ul>
            </Section>
          </div>
        </article>
      </div>
    </Page>
  );
}
