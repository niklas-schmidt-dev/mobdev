import { Link, createFileRoute } from "@tanstack/react-router";
import { Num, T, Var, msg, useGT, useMessages } from "gt-tanstack-start";
import type { ReactNode } from "react";
import { AGENT_BURST, MAX_IN_FLIGHT_PER_MAC } from "../../relay/src/protocol";
import { FREE_PLAN, PRO_PLAN } from "../../shared/plans";
import { Code, Page, buttonPrimary } from "../components/site";
import { currentLocale } from "../lib/i18n";
import { pageHead } from "../lib/meta";
import { GITHUB_URL } from "../lib/releases";

export const Route = createFileRoute("/docs")({
  head: () => pageHead("/docs", currentLocale()),
  component: Docs,
});

/** Anchor and title of each section, in page order. Anchors stay English in every language. */
const sections = [
  ["install", msg("Install")],
  ["iphone", msg("Set up the iPhone")],
  ["agents", msg("Connect an agent")],
  ["tools", msg("Tools")],
  ["emulators", msg("Simulators and Android")],
  ["developer", msg("Build, run and debug")],
  ["flows", msg("Flows and CI")],
  ["skills", msg("Skills")],
  ["remote", msg("Remote access")],
  ["self-host", msg("Run your own relay")],
  ["security", msg("Security and privacy")],
] as const;

type SectionId = (typeof sections)[number][0];

const sectionTitles = Object.fromEntries(sections) as Record<SectionId, string>;

/** Tool name, argument names and what it does. Only the description is translated. */
const tools = [
  ["list_devices", "", msg("iPhones, simulators and Android devices: id, name, model, system version, ready")],
  ["status", "", msg("Screen and input readiness, screenshot size")],
  ["screenshot", "", msg("JPEG of the screen")],
  ["tap", "x, y", msg("Tap a point of the screenshot")],
  ["long_press", "x, y, seconds", msg("Touch and hold")],
  ["swipe", "from_x, from_y, to_x, to_y, duration", msg("Drag, e.g. to scroll")],
  ["scroll", "direction, amount, x, y", msg("Mouse wheel")],
  ["type_text", "text, submit", msg("Type into the focused field (up to 1000 characters per call)")],
  ["press_key", "key, modifiers", msg("e.g. space + cmd for Spotlight")],
  ["home", "", msg("Go to the home screen")],
  ["open_app", "name", msg("Open an app by name (Spotlight on an iPhone)")],
  ["read_screen", "", msg("All visible text with positions (on-device OCR)")],
  ["find_text", "text", msg("Where a label is")],
  ["tap_text", "text, index", msg("Tap a visible label")],
  ["wait_for_text", "text, timeout, gone", msg("Wait for text to appear or disappear")],
  ["ui_tree", "contains, all", msg("Elements from the accessibility tree (simulators and Android)")],
  ["tap_element", "id, text, index, timeout", msg("Tap an element by identifier or label")],
  ["wait_for_element", "id, text, timeout, gone", msg("Wait for an element to appear or disappear")],
  ["run_flow", "path, steps", msg("Replay a flow; stops at the first failing step")],
];

/** Need Developer Mode on the iPhone and Xcode on the Mac. */
const developerTools = [
  ["list_apps", "all", msg("Apps installed for development, or every app")],
  ["install_app", "path", msg("Install a build from the Mac: .app/.ipa, simulator .app or .apk")],
  ["uninstall_app", "bundle_id", msg("Remove an app installed for development")],
  ["launch_app", "bundle_id, arguments, environment, restart", msg("Launch an app and capture what it prints")],
  ["stop_app", "bundle_id", msg("Stop a running app")],
  ["open_url", "url", msg("Open a deep link, universal link or web page")],
  ["logs", "bundle_id, after, lines, contains", msg("print, NSLog and os_log output, and how the app ended")],
  ["crash_reports", "app, name, limit", msg("List crash reports, or read one: exception, reason, crashed thread")],
];

const code = "rounded bg-mist px-1.5 py-0.5 text-[15px]";

function ToolTable({ rows }: { rows: string[][] }) {
  const m = useMessages();
  return (
    <div className="overflow-x-auto rounded-2xl bg-mist">
      <table className="w-full text-left text-[15px]">
        <thead className="text-muted">
          <tr>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">
              <T>Tool</T>
            </th>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">
              <T>Arguments</T>
            </th>
            <th className="px-4 pb-2 pt-3.5 text-[13px] font-semibold">
              <T>What it does</T>
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-line/70">
          {rows.map(([name, args, what]) => (
            <tr key={name}>
              <td className="px-4 py-2.5 font-semibold text-ink">{name}</td>
              <td className="px-4 py-2.5 text-muted">{args}</td>
              <td className="px-4 py-2.5 text-ink/85">{m(what)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Section({ id, children }: { id: SectionId; children: ReactNode }) {
  const m = useMessages();
  return (
    <section id={id} className="scroll-mt-20 border-b border-line pb-14 pt-2 last:border-0">
      <h2 className="text-[28px] font-semibold tracking-tight">{m(sectionTitles[id])}</h2>
      <div className="mt-5 space-y-5 text-[17px] leading-[1.6] text-ink/85 [&_a]:text-link [&_a]:underline-offset-4 hover:[&_a]:underline [&_strong]:font-semibold [&_strong]:text-ink">
        {children}
      </div>
    </section>
  );
}

function Docs() {
  const gt = useGT();
  const m = useMessages();
  const onThisPage = gt("On this page");
  return (
    <Page>
      <div className="mx-auto grid max-w-5xl grid-cols-1 gap-12 px-5 py-16 lg:grid-cols-[190px_minmax(0,1fr)]">
        <nav aria-label={onThisPage} className="hidden lg:block">
          <div className="sticky top-20">
          <p className="mb-3 px-3 text-[12px] font-semibold uppercase tracking-wide text-faint">{onThisPage}</p>
          <ul className="space-y-0.5 text-[14px]">
            {sections.map(([id, title]) => (
              <li key={id}>
                <a href={`#${id}`} className="block rounded-lg px-3 py-1.5 text-muted transition-colors hover:bg-mist hover:text-ink">
                  {m(title)}
                </a>
              </li>
            ))}
          </ul>
          </div>
        </nav>
        <article className="min-w-0 max-w-3xl">
          <T>
            <p className="text-[17px] font-semibold text-tint">Documentation</p>
            <h1 className="headline mt-1 text-[48px]">Mobdev</h1>
            <p className="mt-4 text-[21px] leading-[1.45] text-muted">
              Mobdev puts your iPhones, iOS simulators and Android devices in one Mac app, for you and your AI agent. It
              reads the iPhone screen over USB and taps and types as a Bluetooth keyboard and pointer; simulators and
              Android need only Xcode or adb. Agents use it through MCP or HTTP.
            </p>
          </T>
          <div className="mt-14 space-y-12">
            <Section id="install">
              <T>
                <p>
                  You need a Mac with Bluetooth LE and <strong>macOS 26 or later</strong>, an iPhone and a USB <strong>data</strong> cable.
                  Download the app, open the disk image and drag Mobdev into Applications. It is signed and notarized by
                  Apple and updates itself.
                </p>
              </T>
              <p>
                <a href="/download" className={`${buttonPrimary} !text-white !no-underline`}>
                  <T>Download for Mac</T>
                </a>
              </p>
              <T>
                <p>
                  Allow Bluetooth and Camera when macOS asks. macOS treats the iPhone screen like a camera, which is why
                  it asks for camera access. To build it yourself with Xcode 26 or later:
                </p>
              </T>
              <Code>{`git clone ${GITHUB_URL}\ncd mobdev/macos\nscripts/build-app.sh\nopen build/Mobdev.app`}</Code>
            </Section>

            <Section id="iphone">
              <T>
                <ol className="list-decimal space-y-2 pl-5">
                  <li>Plug it in, unlock it and tap <strong>Trust</strong>. If the Mac asks to allow the accessory, click Allow.</li>
                  <li>
                    On the iPhone open <strong>Settings › Bluetooth</strong> and tap your Mac under Other Devices. iOS lists it by the Mac’s name.
                    If it is missing, wait a moment or click <strong>Show on iPhone Again</strong> in Mobdev: an iPhone on the same Apple
                    Account can miss the Mac until Mobdev offers it again.
                  </li>
                  <li>
                    Turn on <strong>Settings › Accessibility › Touch › AssistiveTouch</strong>. It turns the pointer into
                    taps. On the same page turn off <strong>Snap to Item</strong> and keep <strong>Perform Touch
                    Gestures</strong> on, otherwise every swipe becomes a tap.
                  </li>
                  <li>
                    In Mobdev, pick the keyboard layout that matches <strong>Settings › General › Keyboard › Hardware
                    Keyboard</strong> on the iPhone.
                  </li>
                  <li>Set Auto-Lock to Never while agents work. The phone must stay unlocked.</li>
                </ol>
              </T>
            </Section>

            <Section id="agents">
              <T>
                <p>The app shows these with the right paths under Connect. They contain no secret.</p>
              </T>
              <p className="text-[15px] font-semibold text-ink">Claude Code</p>
              <Code>{"claude mcp add --scope user mobdev -- /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
              <p className="text-[15px] font-semibold text-ink">Codex (~/.codex/config.toml)</p>
              <Code>{'[mcp_servers.mobdev]\ncommand = "/Applications/Mobdev.app/Contents/MacOS/Mobdev"\nargs = ["mcp"]'}</Code>
              <T>
                <p className="text-[15px] font-semibold text-ink">Claude Desktop, Cursor and others</p>
              </T>
              <Code>
                {'{\n  "mcpServers": {\n    "mobdev": {\n      "command": "/Applications/Mobdev.app/Contents/MacOS/Mobdev",\n      "args": ["mcp"]\n    }\n  }\n}'}
              </Code>
              <T>
                <p>
                  HTTP clients can use <code className={code}>http://127.0.0.1:4686/mcp</code> with the token
                  from Settings › API. The server speaks MCP 2026-07-28 and the earlier versions back to 2024-11-05.
                </p>
              </T>
            </Section>

            <Section id="tools">
              <T>
                <p>
                  Coordinates are pixels of the image <code className={code}>screenshot</code> returns (long
                  edge 1280 px). Actions return a fresh screenshot unless you pass <code className={code}>"screenshot": false</code>.
                  With more than one device, pass <code className={code}>device</code> (an id or name
                  from <code className={code}>list_devices</code>) to pick one. Without it, Mobdev uses the only device, or
                  the connected iPhone when simulators or Android devices run next to it.
                </p>
              </T>
              <ToolTable rows={tools} />
            </Section>

            <Section id="emulators">
              <T>
                <p>
                  Booted iOS simulators and Android emulators and phones appear next to your iPhones, in the app and
                  in <code className={code}>list_devices</code>, and take the same tools. There is nothing to set up on
                  them: no cable, no Bluetooth, no Developer Mode.
                </p>
              </T>
              <T>
                <ul className="list-disc space-y-2 pl-5">
                  <li>
                    <strong>iOS Simulator</strong> needs Xcode. Mobdev reads the screen from the simulator itself and
                    sends touches and keys the way Simulator.app does, so no window has to stay open. Install builds
                    made for the simulator (<code className={code}>Debug-iphonesimulator</code>); crash reports come
                    from the Mac.
                  </li>
                  <li>
                    <strong>Android</strong> needs adb from the Android SDK, for example through Android Studio.
                    Emulators and phones with USB debugging appear while adb runs. Install
                    an <code className={code}>.apk</code>, <code className={code}>logs</code> follows logcat,
                    and <code className={code}>press_key</code> with <code className={code}>escape</code> is Back. Text
                    is typed as ASCII, and <code className={code}>open_app</code> matches package names: “Settings”
                    opens com.android.settings.
                  </li>
                </ul>
              </T>
              <Code>
                {"xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' \\\n  -derivedDataPath build build\n# install_app {\"device\": \"iPhone 17\", \"path\": \"…/Debug-iphonesimulator/MyApp.app\"}\n# install_app {\"device\": \"emulator-5554\", \"path\": \"…/app-debug.apk\"}"}
              </Code>
              <T>
                <p>
                  On both, <code className={code}>ui_tree</code> lists the elements on screen with their role, label and
                  accessibility identifier, and <code className={code}>tap_element</code> and <code className={code}>wait_for_element</code> find
                  them by identifier or label: steadier than OCR, and they find buttons that show only an icon. An iPhone has no such tree without a test runner on
                  the phone, so there agents use <code className={code}>tap_text</code>.
                </p>
              </T>
              <T>
                <p>Turn them off under Settings › General in the app if you only want iPhones.</p>
              </T>
            </Section>

            <Section id="developer">
              <T>
                <p>
                  For apps you build, Mobdev also installs builds, launches them and reads their output and crash
                  reports. The agent builds with <code className={code}>xcodebuild</code>, installs, drives the app with
                  the tools above and reads the logs. These tools use Xcode’s <code className={code}>devicectl</code>, so
                  they need <strong>Xcode</strong> on the Mac and <strong>Developer Mode</strong> on the iPhone (Settings ›
                  Privacy &amp; Security › Developer Mode). Everything else works without them. Simulators and Android
                  need neither.
                </p>
              </T>
              <ToolTable rows={developerTools} />
              <Code>
                {"xcodebuild -scheme MyApp -destination 'generic/platform=iOS' \\\n  -derivedDataPath build -allowProvisioningUpdates build\n# install_app {\"path\": \"…/build/Build/Products/Debug-iphoneos/MyApp.app\"}\n# launch_app  {\"bundle_id\": \"com.example.MyApp\"}\n# logs        {\"bundle_id\": \"com.example.MyApp\"}"}
              </Code>
              <T>
                <p>
                  <code className={code}>logs</code> returns a cursor; pass it as <code className={code}>after</code> to
                  get only new lines. When the app crashes, <code className={code}>logs</code> says so
                  and <code className={code}>crash_reports</code> shows the report. Paths
                  for <code className={code}>install_app</code> are on the Mac that runs Mobdev, also through a relay.
                  Mobdev never removes App Store or system apps.
                </p>
              </T>
            </Section>

            <Section id="flows">
              <T>
                <p>
                  A flow is a list of tool calls saved as JSON. Click <strong>Record</strong> in a device’s activity and
                  everything you or an agent do on it is collected; on simulators and Android, clicks on named elements
                  become <code className={code}>tap_element</code>, so the flow survives layout changes. Replay it
                  with <strong>Run Flow…</strong>, the <code className={code}>run_flow</code> tool or, without the
                  app, <code className={code}>Mobdev flow</code>. Every run stops at the first failing step and says
                  which.
                </p>
              </T>
              <Code>
                {'{\n  "name": "Sign in",\n  "steps": [\n    {"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}},\n    {"tap_element": {"id": "email"}},\n    {"type_text": {"text": "me@example.com", "submit": true}},\n    {"wait_for_element": {"text": "Welcome"}}\n  ]\n}'}
              </Code>
              <T>
                <p>
                  <code className={code}>Mobdev flow</code> runs on booted simulators and Android devices, for scripts
                  and CI. It exits 0 when every step passed and 1 when one failed; <code className={code}>--artifacts</code> keeps
                  the activity, crash reports and a screenshot of the failure. In CI,
                  prefer <code className={code}>tap_element</code> to the OCR tools, which do not work on GitHub’s
                  virtualized Macs.
                </p>
              </T>
              <Code>
                {"/Applications/Mobdev.app/Contents/MacOS/Mobdev flow sign-in.json \\\n  --device \"$UDID\" --artifacts flow-artifacts"}
              </Code>
            </Section>

            <Section id="skills">
              <T>
                <p>
                  Skills give your agent whole workflows on top of the tools: the build and debug loop, smoke tests,
                  onboarding audits and competitor research. They work with Claude Code, Codex, Cursor and other agents
                  that read <code className={code}>SKILL.md</code> files.
                </p>
              </T>
              <Code>{"npx skills add niklas-schmidt-dev/mobdev"}</Code>
              <T>
                <p>
                  Or copy a folder from <a href={`${GITHUB_URL}/tree/main/skills`}>skills/</a> into your agent’s skills
                  directory.
                </p>
              </T>
            </Section>

            <Section id="remote">
              <T>
                <p>
                  To reach the phone from another computer, the Mac keeps an outgoing WebSocket to a relay. No port is
                  opened on the Mac, and the relay stores nothing.
                </p>
              </T>
              <T>
                <ol className="list-decimal space-y-2 pl-5">
                  <li>
                    Sign in to the <Link to="/dashboard">dashboard</Link> and create an access token.
                  </li>
                  <li>Click “Open in Mobdev”, or paste the token under Remote Access in the app.</li>
                  <li>Copy the remote command from the app and run it on the other computer:</li>
                </ol>
              </T>
              <Code>
                {'claude mcp add --transport http mobdev-remote \\\n  https://relay.mobdev.sh/h/<mac-name>/mcp \\\n  --header "Authorization: Bearer mdc_…"'}
              </Code>
              <T>
                <p>
                  The client key (<code className={code}>mdc_…</code>) is derived from a secret that never leaves your
                  Mac. Anyone with it can control the phone; “New Client Key” in the app revokes it. Revoking the access
                  token in the dashboard disconnects the Mac.
                </p>
              </T>
              <T>
                <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Limits of the hosted relay</h3>
                <p>
                  <Var>{FREE_PLAN.name}</Var> connects <Num>{FREE_PLAN.macs}</Num> Mac and
                  includes <Num>{FREE_PLAN.requests}</Num> requests and <Num>{FREE_PLAN.activeHours}</Num> active hours a
                  month. <Var>{PRO_PLAN.name}</Var> ($<Num>{PRO_PLAN.priceUsd}</Num> USD a month, plus applicable tax)
                  connects <Num>{PRO_PLAN.macs}</Num> Macs and includes <Num>{PRO_PLAN.requests}</Num> requests
                  and <Num>{PRO_PLAN.activeHours}</Num> active hours a month. Active time counts while a Mac works on a
                  request; a connected Mac that waits costs nothing. The dashboard shows what you used. Mobdev on the Mac
                  and a relay you run yourself have no limits.
                </p>
              </T>
              <T>
                <p>When a limit is reached, the relay answers with HTTP 429 and a Retry-After header:</p>
              </T>
              <T>
                <ul className="list-disc space-y-2 pl-5">
                  <li>
                    More than <Num>{AGENT_BURST.limit}</Num> requests in <Num>{AGENT_BURST.seconds}</Num> seconds with
                    one client key.
                  </li>
                  <li>
                    More than <Num>{MAX_IN_FLIGHT_PER_MAC}</Num> requests waiting for the same Mac.
                  </li>
                  <li>The month’s requests or active time used up. Retry-After points to when they renew.</li>
                </ul>
              </T>
            </Section>

            <Section id="self-host">
              <T>
                <p>The relay in the repository speaks the same protocol. It is one Go binary or a small Docker image:</p>
              </T>
              <Code>{"cd relay\nRELAY_HOST_ACCESS_TOKEN=choose-one go run .\n# or\ndocker build -t mobdev-relay . && docker run -p 8080:8080 mobdev-relay"}</Code>
              <T>
                <p>
                  Put it behind HTTPS and enter its URL in the app. With <code className={code}>RELAY_HOST_ACCESS_TOKEN</code> set,
                  only Macs that know the token may connect.
                </p>
              </T>
            </Section>

            <Section id="security">
              <T>
                <ul className="list-disc space-y-2 pl-5">
                  <li>The local API binds to 127.0.0.1, needs a bearer token and rejects browser requests.</li>
                  <li>Text recognition runs on the Mac. No screen content leaves it unless your agent sends it to its model.</li>
                  <li>
                    The hosted relay stores your email, hashed access tokens, which Macs are connected and the iPhones they
                    report. Requests and screenshots only pass through memory. See <Link to="/privacy">privacy</Link>.
                  </li>
                  <li>
                    Agents act on your real phone with your accounts. Keep a person in the loop for anything that sends
                    messages, pays or deletes.
                  </li>
                </ul>
              </T>
            </Section>
          </div>
        </article>
      </div>
    </Page>
  );
}
