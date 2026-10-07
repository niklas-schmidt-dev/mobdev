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
  ["terminal", msg("From the terminal")],
  ["tools", msg("Tools")],
  ["state", msg("Device state")],
  ["emulators", msg("Simulators and Android")],
  ["developer", msg("Build, run and debug")],
  ["projects", msg("Projects")],
  ["flows", msg("Flows and CI")],
  ["tests", msg("Tests")],
  ["checks", msg("Checks")],
  ["crawl", msg("Explore an app")],
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
  ["observe", "image, contains", msg("The screen as numbered marks, cheaper than a screenshot; image draws them on one")],
  ["tap_mark", "mark", msg("Tap a mark from the last observe")],
  ["scroll_until_visible", "text, id, direction, max_scrolls", msg("Scroll until something shows; stops at the end of the list")],
  ["wait_for_idle", "timeout, stable", msg("Wait until the screen stops changing")],
  ["press_button", "button", msg("Volume, mute, play/pause; lock on simulators and Android")],
  ["start_recording", "path", msg("Record the screen to an .mp4, by default into the project")],
  ["save_screenshot", "path", msg("Save the screen at full resolution into the project's screenshots, e.g. for the App Store")],
  ["stop_recording", "", msg("End the recording and say where it is")],
  ["recent_steps", "count, clear", msg("The newest actions that worked, as steps for a test")],
  ["run_shortcut", "name", msg("Run a shortcut from Apple’s Shortcuts app")],
  ["ui_tree", "contains, all", msg("Elements from the accessibility tree (simulators, Android, iPhones with the UI tree on)")],
  ["tap_element", "id, text, index, timeout", msg("Tap an element by identifier or label")],
  ["wait_for_element", "id, text, timeout, gone", msg("Wait for an element to appear or disappear")],
  ["run_flow", "path, steps, variables, video", msg("Replay a flow (JSON or Maestro YAML); stops at the first failing step and can save a video")],
  ["assert_screenshot", "name, threshold, mask, update", msg("Compare the screen with a baseline picture; fails with a diff image")],
  ["accessibility_audit", "image, fail_on, ignore", msg("Missing labels, small tap targets, low contrast and unclear labels")],
  ["assert_with_ai", "question, expect", msg("Ask Apple Intelligence on the Mac a yes/no question about the screen")],
  ["crawl_app", "bundle_id, max_actions, seconds, avoid", msg("Explore an app by itself and keep every crash with its steps")],
  ["navigate_to", "bundle_id, screen", msg("Go to a screen that crawl_app mapped")],
  ["list_projects", "", msg("The projects Mobdev knows, which is active, and which one your calls use")],
  ["create_project", "path, name, bundle_id, builds", msg("Make a project in the app's repository and make it active")],
  ["open_project", "project", msg("Make a project active: its folder, a repository with mobdev/, or its name")],
  ["run_tests", "project, tests, variables, video, language", msg("Run a project's tests: every result, the first failure's screen, results.json and junit.xml")],
  ["list_tests", "project", msg("A project's tests and its newest results")],
  ["save_test", "project, name, steps, description, platforms, file", msg("Write a test into a project, creating it when needed")],
  ["save_flow", "project, name, steps, file", msg("Write a flow into the project's flows/")],
  ["test_result", "project, run", msg("The newest run's results with each failure's step, screenshot and video")],
];

/** Set a device up directly instead of tapping through Settings. */
const stateTools = [
  ["set_location", "latitude, longitude, route, speed, clear", msg("A simulated position, or a route the device follows")],
  ["set_permission", "bundle_id, permission, state", msg("Grant, revoke or reset location, photos, camera and more without the prompt")],
  ["send_push", "bundle_id, title, body, badge, data, payload", msg("A push notification to a simulator app")],
  ["set_appearance", "dark, text_size, increase_contrast, reduce_motion", msg("Dark mode, Dynamic Type and accessibility switches")],
  ["set_language", "language, bundle_id", msg("e.g. de-DE, for the simulator or one Android app")],
  ["set_status_bar", "preset, time, battery_level, …", msg("9:41 and full bars for screenshots, or clear")],
  ["biometrics", "action", msg("Answer a Face ID, Touch ID or fingerprint prompt")],
  ["reset_app", "bundle_id, keychain", msg("Delete an app’s data as if it had just been installed")],
  ["clipboard", "text", msg("Read the clipboard, or set it")],
  ["set_orientation", "orientation", msg("Portrait or landscape")],
];

/** Need Developer Mode on the iPhone and Xcode on the Mac. */
const developerTools = [
  ["list_apps", "all", msg("Apps installed for development, or every app")],
  ["install_app", "path, upload", msg("Install a build from the Mac, or one uploaded through the relay: .app/.ipa, simulator .app or .apk")],
  ["uninstall_app", "bundle_id", msg("Remove an app installed for development")],
  ["launch_app", "bundle_id, arguments, environment, restart", msg("Launch an app and capture what it prints")],
  ["stop_app", "bundle_id", msg("Stop a running app")],
  ["open_url", "url", msg("Open a deep link, universal link or web page")],
  ["logs", "bundle_id, after, lines, contains", msg("print, NSLog and os_log output, and how the app ended")],
  ["crash_reports", "app, name, limit", msg("List crash reports, or read one: exception, reason, crashed thread")],
];

/** Which requests an app makes. */
const networkTools = [
  ["start_network_capture", "bundle_id", msg("Start recording an app’s requests")],
  ["network_log", "bundle_id, contains, after, query, headers", msg("The recorded requests: method, URL, status, bytes and time")],
  ["stop_network_capture", "bundle_id", msg("Stop recording; on Android this removes the proxy again")],
  ["mock_response", "url, status, body, content_type, clear", msg("Android: a fixed answer for plain HTTP requests, e.g. an error from your API")],
];

/** Measure an app, and the React Native and Expo dev loop. */
const performanceTools = [
  ["performance", "bundle_id, seconds, max_cpu, max_memory_mb, max_janky_percent", msg("CPU, memory and, on Android, frames of a running app; budgets fail the call")],
  ["measure_launch", "bundle_id, runs, method, max_ms, stable", msg("Cold launch time over several runs: fastest, median, slowest")],
  ["reload_app", "port", msg("Reload a React Native or Expo app through Metro, else through its developer menu")],
  ["dev_menu", "port", msg("Open a React Native or Expo app’s developer menu")],
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
              <T>
                <p className="text-[15px] font-semibold text-ink">Claude Code plugin, with the skills</p>
              </T>
              <Code>{"/plugin marketplace add niklas-schmidt-dev/mobdev\n/plugin install mobdev@mobdev"}</Code>
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

            <Section id="terminal">
              <T>
                <p>
                  Every tool also runs from a shell, for scripts and for agents that prefer a terminal to
                  MCP. <code className={code}>Mobdev tools</code> lists them; values are JSON where they parse as JSON.
                  It goes through the running app, so it reaches iPhones too, and works on its own with booted simulators
                  and Android devices.
                </p>
              </T>
              <Code>
                {'M=/Applications/Mobdev.app/Contents/MacOS/Mobdev\n$M observe\n$M tap_mark mark=4\n$M type_text text="hello world" submit=true\n$M screenshot --image screen.png'}
              </Code>
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
              <T>
                <p>
                  <code className={code}>observe</code> is the cheapest way for an agent to look: a numbered list of
                  what can be read or tapped, such as <code className={code}>[4] Button "Sign in" id=login</code>, from
                  the UI tree or, where there is none, from text recognition. <code className={code}>tap_mark</code> taps
                  one by its number. <code className={code}>wait_for_idle</code> replaces fixed pauses after animations,
                  and <code className={code}>scroll_until_visible</code> replaces guessed swipes.
                </p>
              </T>
              <T>
                <p>
                  <strong>Inspect</strong> in a device’s toolbar shows the identifier and label of the element under the
                  pointer, and a click copies the step that taps it, ready for a flow or test.
                </p>
              </T>
            </Section>

            <Section id="state">
              <T>
                <p>
                  Tests and agents set up a situation directly instead of tapping through Settings: a location or route,
                  permissions, a push notification, dark mode and text size, the language, a clean status bar for
                  screenshots, Face ID, an app’s data and the orientation. Simulators and Android take almost all of it;
                  an iPhone in Developer Mode takes the location, appearance, status bar, clipboard and orientation
                  through Xcode 27.
                </p>
              </T>
              <ToolTable rows={stateTools} />
              <Code>
                {'{"set_permission": {"bundle_id": "com.example.MyApp", "permission": "location"}}\n{"set_location": {"latitude": 52.52, "longitude": 13.405}}\n{"send_push": {"bundle_id": "com.example.MyApp", "title": "Order shipped", "data": {"order": 7}}}\n{"set_status_bar": {"preset": "screenshot"}}'}
              </Code>
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
                    and <code className={code}>press_key</code> with <code className={code}>escape</code> is Back.
                    Mobdev shows the screen and sends input through scrcpy’s server, which it brings along: video
                    is fast, and any text types, emoji included. <code className={code}>open_app</code> matches
                    package names: “Settings” opens com.android.settings.
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
                  them by identifier or label: steadier than OCR, and they find buttons that show only an icon. On an
                  iPhone they need the UI tree turned on (see Build, run and debug); until then agents
                  use <code className={code}>tap_text</code>.
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
              <T>
                <p>
                  <strong>UI tree on iPhones.</strong> With Developer Mode and Xcode, open the iPhone’s info in Mobdev and
                  turn on <strong>UI Tree</strong>. Mobdev builds Mobdev Runner, a small UI test, with Xcode, signs it
                  with your development team and keeps it running on the iPhone, as WebDriverAgent does.
                  Then <code className={code}>ui_tree</code>, <code className={code}>tap_element</code> and <code className={code}>wait_for_element</code> work
                  there as on simulators, and <code className={code}>type_text</code> also types emoji. The first build
                  takes a minute or two. With a free Apple Account, trust the developer once under Settings › General ›
                  VPN &amp; Device Management.
                </p>
              </T>
              <T>
                <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Performance and React Native</h3>
                <p>
                  <code className={code}>performance</code> samples a running app for up to a minute,
                  and <code className={code}>measure_launch</code> times cold launches the way Xcode and Android report
                  them. Both work on simulators and Android; on an iPhone, <code className={code}>measure_launch</code> times
                  the screen until it stays still. Budgets such as <code className={code}>max_ms</code> fail the step, so a
                  test catches an app that got slower or heavier.
                </p>
              </T>
              <ToolTable rows={performanceTools} />
              <Code>{'{"measure_launch": {"bundle_id": "com.example.MyApp", "runs": 5, "max_ms": 1500}}\n{"performance": {"bundle_id": "com.example.MyApp", "seconds": 20, "max_memory_mb": 300}}'}</Code>
              <T>
                <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Network</h3>
                <p>
                  The network tools show which requests an app makes, for debugging, for checking analytics and API
                  calls, and for privacy audits. Nothing is installed on the device, and HTTPS is never decrypted. On
                  iOS, Mobdev relaunches the app with Apple’s network diagnostics on and reads its log: method, host,
                  status, bytes and time, but iOS hides paths and queries. On Android, Mobdev points the device at a
                  proxy on the Mac: plain HTTP in full, HTTPS as host, bytes and time. Stopping the capture removes the
                  proxy again, and a dev server on the Mac stays reachable as 10.0.2.2.
                </p>
              </T>
              <ToolTable rows={networkTools} />
            </Section>

            <Section id="flows">
              <T>
                <p>
                  A flow is a list of tool calls saved as JSON. Click <strong>Record</strong> in a device’s activity and
                  everything you or an agent do on it is collected; on simulators, Android and iPhones with the UI tree,
                  clicks on named elements become <code className={code}>tap_element</code>, so the flow survives layout
                  changes. Replay it
                  with <strong>Run Flow…</strong>, the <code className={code}>run_flow</code> tool or, without the
                  app, <code className={code}>Mobdev flow</code>. Every run stops at the first failing step and says
                  which. Run Flow… keeps a video of each run; <code className={code}>run_flow</code> saves one where
                  its <code className={code}>video</code> argument says.
                </p>
              </T>
              <Code>
                {'{\n  "name": "Sign in",\n  "steps": [\n    {"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}},\n    {"tap_element": {"id": "email"}},\n    {"type_text": {"text": "me@example.com", "submit": true}},\n    {"wait_for_element": {"text": "Welcome"}}\n  ]\n}'}
              </Code>
              <T>
                <p>
                  Control steps look at the screen instead of guessing waits: <code className={code}>if</code> runs steps
                  when something is visible or on one platform, <code className={code}>repeat</code> runs them a number of
                  times or until something shows, and <code className={code}>retry</code> runs them again when one fails.
                </p>
              </T>
              <Code>
                {'{"if": {"visible": {"text": "Allow"}, "then": [{"tap_element": {"text": "Allow"}}]}}\n{"repeat": {"until_visible": {"id": "checkout"}, "max": 10, "steps": [{"scroll": {"direction": "down"}}]}}\n{"retry": {"times": 2, "steps": [{"tap_element": {"id": "pay"}}, {"wait_for_text": {"text": "Paid"}}]}}'}
              </Code>
              <T>
                <p>
                  <strong>Maestro</strong> flows run as they are: <code className={code}>run_flow</code>, <code className={code}>Mobdev flow</code> and
                  tests take <code className={code}>.yaml</code> files, and <code className={code}>Mobdev convert</code> turns
                  a flow into the other format.
                </p>
              </T>
              <Code>{"Mobdev convert login.yaml > login.json   # Maestro to Mobdev\nMobdev convert login.json > login.yaml   # Mobdev to Maestro"}</Code>
              <T>
                <p>
                  <code className={code}>Mobdev flow</code> runs on booted simulators and Android devices, for scripts
                  and CI. It exits 0 when every step passed and 1 when one failed; <code className={code}>--artifacts</code> keeps
                  a video of the run (<code className={code}>run.mp4</code>), the activity, crash reports and a
                  screenshot of the failure. In CI,
                  prefer <code className={code}>tap_element</code> to the OCR tools, which do not work on GitHub’s
                  virtualized Macs.
                </p>
              </T>
              <Code>
                {"/Applications/Mobdev.app/Contents/MacOS/Mobdev flow sign-in.json \\\n  --device \"$UDID\" --artifacts flow-artifacts"}
              </Code>
              <T>
                <p>
                  On GitHub, the Mobdev action does all of it on a hosted Mac: it boots a simulator, installs your
                  build, runs a test project or a flow, puts the results into the job summary and, if you want, a pull
                  request comment, and keeps the videos and screenshots as an artifact.
                </p>
              </T>
              <Code>
                {"- uses: niklas-schmidt-dev/mobdev/actions/test@main\n  with:\n    project: mobdev\n    comment: true"}
              </Code>
            </Section>

            <Section id="projects">
              <T>
                <p>
                  A project is a folder in your app’s repository, usually <code className={code}>mobdev/</code>, with
                  everything Mobdev keeps for the app. Commit it all but <code className={code}>output/</code>, which
                  brings its own <code className={code}>.gitignore</code> and appears only when Mobdev first writes there.
                </p>
              </T>
              <Code>
                {"mobdev/\n  mobdev.json    the app, its builds and what every test starts with\n  tests/         tests\n  flows/         saved flows\n  baselines/     assert_screenshot's reference pictures\n  screenshots/   save_screenshot's pictures, such as store screenshots\n  maps/          crawl_app's map of each app\n  output/        test runs, recordings, crawls, failed checks and flow videos"}
              </Code>
              <T>
                <ul className="list-disc space-y-2 pl-5">
                  <li>
                    <strong>New Project…</strong> in the app writes <code className={code}>mobdev/mobdev.json</code> into
                    the repository you choose, with the bundle ID it finds there in an Expo config, the Xcode project or
                    Gradle, and <strong>Open Project…</strong> adds an existing one. Projects come first
                    in the sidebar, each with its tests, flows, screenshots, app map, recordings and runs.
                  </li>
                  <li>
                    The project you select is the active one: recordings, screenshots, saved flows and tests, crawls and
                    named baselines land there without a path.
                  </li>
                  <li>
                    An agent’s working folder comes first: <code className={code}>Mobdev mcp</code> sends the project of the
                    folder it runs in, so agents in two repositories, or two worktrees of one, never save into each
                    other’s project. Agents find projects with <code className={code}>list_projects</code> and switch
                    with <code className={code}>open_project</code>.
                  </li>
                  <li>
                    A test run stays in its project, even when another one becomes active meanwhile.
                  </li>
                  <li>
                    Each project shows its app’s icon, found in the repository: the icon of an
                    Expo <code className={code}>app.json</code>, the iOS app icon or Android’s launcher icon. Choose any other
                    image file in the project’s overview.
                  </li>
                </ul>
              </T>
            </Section>

            <Section id="tests">
              <T>
                <p>
                  A project’s tests are files in its <code className={code}>tests/</code> folder,
                  and <code className={code}>mobdev.json</code> names the app, its builds per platform and the steps
                  every test starts with. Each file is one test, a flow with
                  a name, a description and the platforms it runs on. A test passes when every step does, so it ends
                  with a wait that proves the result. <code className={code}>{"${NAME}"}</code> takes a variable from the
                  project, the environment or the run, and a secret’s value never appears in results.
                </p>
              </T>
              <Code>
                {'{\n  "name": "My App",\n  "app": {"bundle_id": "com.example.MyApp", "builds": {"simulator": "build/MyApp.app"}},\n  "before_each": [{"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}}],\n  "variables": {"EMAIL": "me@example.com"},\n  "secrets": ["PASSWORD"]\n}'}
              </Code>
              <T>
                <p>
                  A project’s <strong>Tests</strong> in the app runs them on a device and shows every result with its
                  steps, the screenshot of a failure and the video. Agents get the same
                  through <code className={code}>list_tests</code>, <code className={code}>save_test</code>, <code className={code}>run_tests</code> and <code className={code}>test_result</code>:
                  they drive the app until a path works, save it as a test, run it and fix it from the failing
                  step. <code className={code}>Mobdev test</code> runs a project in CI without the app and
                  writes <code className={code}>results.json</code>, <code className={code}>junit.xml</code> and a video and a
                  screenshot per test.
                </p>
              </T>
              <Code>
                {"/Applications/Mobdev.app/Contents/MacOS/Mobdev test mobdev/ \\\n  --device \"$UDID\" --artifacts test-artifacts"}
              </Code>
              <T>
                <p>
                  Repeat <code className={code}>--device</code> to run on several devices at once,
                  or add <code className={code}>--simulator "iPhone 17"</code> to make a simulator of that type for the
                  run and delete it afterwards. <code className={code}>--emulator Pixel_9_Pro</code> starts that Android
                  Virtual Device read-only for the run, also several copies at once, and shuts it down
                  again. <code className={code}>--language de-DE</code> runs the tests in that
                  language, repeated in each language in turn, and puts the old one back afterwards. Each device and
                  language gets its own folder, and <code className={code}>summary.md</code> is ready for a CI job summary. A
                  test step like <code className={code}>{'{"save_screenshot": {"path": "${LANGUAGE}/01-home"}}'}</code> saves
                  store screenshots in every language. When an agent has found a path through the
                  app, <code className={code}>recent_steps</code> hands it the actions that worked, to save with <code className={code}>save_test</code>.
                </p>
              </T>
            </Section>

            <Section id="checks">
              <T>
                <p>
                  Three tools judge the screen and fail their step when it does not pass, so a test checks how a screen
                  looks, not only what is on it.
                </p>
              </T>
              <Code>
                {'{"assert_screenshot": {"name": "home", "mask": ["home.clock"]}}\n{"accessibility_audit": {"fail_on": "error"}}\n{"assert_with_ai": {"question": "Is any text cut off?", "expect": "no"}}'}
              </Code>
              <T>
                <ul className="list-disc space-y-2 pl-5">
                  <li>
                    <code className={code}>assert_screenshot</code> compares the screen with a baseline picture. The first
                    run records it in the project’s <code className={code}>baselines</code> folder; commit it with your
                    tests. A failure keeps a diff image with the changed regions marked, in the run or the
                    project’s <code className={code}>output/</code>. The status bar is left out,
                    and <code className={code}>mask</code> leaves out more, such as a clock or a map.
                  </li>
                  <li>
                    <code className={code}>accessibility_audit</code> finds buttons without a label, tap targets smaller
                    than iOS and Android recommend, text below WCAG’s contrast ratios and labels that read like file
                    names or identifiers.
                  </li>
                  <li>
                    <code className={code}>assert_with_ai</code> asks Apple Intelligence on the Mac a yes/no question about
                    the screen. The screenshot stays on the Mac, which needs Apple Intelligence turned on.
                  </li>
                </ul>
              </T>
            </Section>

            <Section id="crawl">
              <T>
                <p>
                  <code className={code}>crawl_app</code> explores an app by itself, without a model: it launches the
                  app, taps every element it has not tried, maps the screens with screenshots and keeps every crash with
                  the steps that cause it as a flow to replay. It never taps text fields or anything that reads like
                  delete, pay, buy, send or sign out. The map goes into the project’s <code className={code}>maps/</code> and
                  the screenshots into its <code className={code}>output/</code>. <code className={code}>navigate_to</code> then
                  goes straight to a mapped screen by its title.
                </p>
              </T>
              <Code>{'{"crawl_app": {"bundle_id": "com.example.MyApp", "max_actions": 60}}\n{"navigate_to": {"bundle_id": "com.example.MyApp", "screen": "Settings"}}'}</Code>
            </Section>

            <Section id="skills">
              <T>
                <p>
                  Skills give your agent whole workflows on top of the tools: the build and debug loop, smoke tests,
                  reproducing a reported bug, App Store and Google Play screenshots, React Native and Expo apps,
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
                <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Builds from anywhere</h3>
                <p>
                  A cloud agent or a CI job builds the app in its own container, uploads the build to the Mac through
                  the relay and installs it there with <code className={code}>install_app</code> and the upload’s id. The
                  relay keeps nothing; the Mac deletes the build a day after its last use. The script needs only a shell
                  and curl; on a Mac, <code className={code}>Mobdev upload</code> does the same.
                </p>
              </T>
              <Code>
                {'curl -fsSLO https://raw.githubusercontent.com/niklas-schmidt-dev/mobdev/main/scripts/mobdev-upload.sh\nexport MOBDEV_URL=https://relay.mobdev.sh/h/<mac-name> MOBDEV_KEY=mdc_…\nid=$(sh mobdev-upload.sh app-debug.apk)\n# install_app {"upload": "<id>", "device": "emulator-5554"}'}
              </Code>
              <T>
                <h3 className="pt-2 text-[21px] font-semibold tracking-tight text-ink">Live view</h3>
                <p>
                  Turn on “Allow live view” under Remote Access in the app, then click “Live” next to a device in
                  the <Link to="/dashboard">dashboard</Link> to watch its screen in the browser: click to tap, drag to
                  swipe and type on it. “Share…” there creates a link that expires, to view only or to control, which
                  anyone can open without an account until you revoke it. The app shows while someone watches and can
                  stop it. Watching counts as active time. Agents open the same stream with the client key at{" "}
                  <code className={code}>/v1/live</code>; see the <a href={`${GITHUB_URL}/blob/main/relay/README.md#live-view`}>relay’s protocol</a>.
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
                  <li>
                    Under Settings › Agents, list apps agents may never open, such as your bank. It prevents mistakes; it
                    is not a sandbox.
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
