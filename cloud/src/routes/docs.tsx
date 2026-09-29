import { createFileRoute } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { Code, Page } from "../components/site";

export const Route = createFileRoute("/docs")({
  head: () => ({ meta: [{ title: "Docs — Mobdev" }] }),
  component: Docs,
});

const sections = [
  ["install", "Install"],
  ["iphone", "Set up the iPhone"],
  ["agents", "Connect an agent"],
  ["tools", "Tools"],
  ["remote", "Remote access"],
  ["self-host", "Run your own relay"],
  ["security", "Security and privacy"],
] as const;

const tools = [
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

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="scroll-mt-24 border-b border-white/5 pb-12 pt-4 last:border-0">
      <h2 className="font-display text-2xl font-semibold tracking-tight">{title}</h2>
      <div className="mt-4 space-y-4 leading-relaxed text-paper/85 [&_a]:text-lime [&_a]:underline-offset-4 hover:[&_a]:underline [&_strong]:text-paper">
        {children}
      </div>
    </section>
  );
}

function Docs() {
  return (
    <Page>
      <div className="mx-auto grid max-w-6xl gap-10 px-5 py-14 lg:grid-cols-[200px_1fr]">
        <nav aria-label="On this page" className="hidden lg:block">
          <ul className="sticky top-24 space-y-1 text-sm">
            {sections.map(([id, title]) => (
              <li key={id}>
                <a href={`#${id}`} className="block rounded-lg px-3 py-1.5 text-muted transition hover:bg-white/5 hover:text-paper">
                  {title}
                </a>
              </li>
            ))}
          </ul>
        </nav>
        <article className="min-w-0 max-w-3xl">
          <h1 className="font-display text-4xl font-semibold tracking-tight">Mobdev docs</h1>
          <p className="mt-3 text-lg text-muted">
            Mobdev reads the iPhone screen over USB and taps and types as a Bluetooth keyboard and pointer. Agents use it
            through MCP or HTTP.
          </p>
          <div className="mt-10 space-y-8">
            <Section id="install" title="Install">
              <p>
                You need a Mac with Bluetooth LE and <strong>macOS 26 or later</strong>, an iPhone and a USB{" "}
                <strong>data</strong> cable. Signed downloads are on the way; until then, build the app from source
                with Xcode 26 or later:
              </p>
              <Code>{"git clone <repository>\ncd mobdev/macos\nscripts/build-app.sh\nopen build/Mobdev.app"}</Code>
              <p>
                Allow Bluetooth and Camera when macOS asks. macOS treats the iPhone screen like a camera, which is why
                it asks for camera access.
              </p>
            </Section>

            <Section id="iphone" title="Set up the iPhone">
              <ol className="list-decimal space-y-2 pl-5">
                <li>Plug it in, unlock it and tap <strong>Trust</strong>. If the Mac asks to allow the accessory, click Allow.</li>
                <li>
                  On the iPhone open <strong>Settings › Bluetooth</strong> and tap your Mac or “Mobdev”.
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
              <p className="text-sm text-muted">Claude Code</p>
              <Code>{"claude mcp add --scope user mobdev -- /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp"}</Code>
              <p className="text-sm text-muted">Codex (~/.codex/config.toml)</p>
              <Code>{'[mcp_servers.mobdev]\ncommand = "/Applications/Mobdev.app/Contents/MacOS/Mobdev"\nargs = ["mcp"]'}</Code>
              <p className="text-sm text-muted">Claude Desktop, Cursor and others</p>
              <Code>
                {'{\n  "mcpServers": {\n    "mobdev": {\n      "command": "/Applications/Mobdev.app/Contents/MacOS/Mobdev",\n      "args": ["mcp"]\n    }\n  }\n}'}
              </Code>
              <p>
                HTTP clients can use <code className="font-mono text-sm">http://127.0.0.1:4686/mcp</code> with the token
                from Settings › API. The server speaks MCP 2026-07-28 and the earlier versions back to 2024-11-05.
              </p>
            </Section>

            <Section id="tools" title="Tools">
              <p>
                Coordinates are pixels of the image <code className="font-mono text-sm">screenshot</code> returns (long
                edge 1280 px). Actions return a fresh screenshot unless you pass{" "}
                <code className="font-mono text-sm">"screenshot": false</code>.
              </p>
              <div className="overflow-x-auto rounded-2xl border border-white/10">
                <table className="w-full text-left text-sm">
                  <thead className="bg-white/[0.03] text-muted">
                    <tr>
                      <th className="px-4 py-2.5 font-medium">Tool</th>
                      <th className="px-4 py-2.5 font-medium">Arguments</th>
                      <th className="px-4 py-2.5 font-medium">What it does</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-white/5">
                    {tools.map(([name, args, what]) => (
                      <tr key={name}>
                        <td className="px-4 py-2.5 font-mono text-[13px] text-lime">{name}</td>
                        <td className="px-4 py-2.5 font-mono text-[13px] text-muted">{args}</td>
                        <td className="px-4 py-2.5">{what}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
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
                The client key (<code className="font-mono text-sm">mdc_…</code>) is derived from a secret that never
                leaves your Mac. Anyone with it can control the phone; “New Client Key” in the app revokes it. Revoking
                the access token in the dashboard disconnects the Mac.
              </p>
            </Section>

            <Section id="self-host" title="Run your own relay">
              <p>The relay in the repository speaks the same protocol. It is one Go binary or a small Docker image:</p>
              <Code>{"cd relay\nRELAY_HOST_ACCESS_TOKEN=choose-one go run .\n# or\ndocker build -t mobdev-relay . && docker run -p 8080:8080 mobdev-relay"}</Code>
              <p>
                Put it behind HTTPS and enter its URL in the app. With{" "}
                <code className="font-mono text-sm">RELAY_HOST_ACCESS_TOKEN</code> set, only Macs that know the token
                may connect.
              </p>
            </Section>

            <Section id="security" title="Security and privacy">
              <ul className="list-disc space-y-2 pl-5">
                <li>The local API binds to 127.0.0.1, needs a bearer token and rejects browser requests.</li>
                <li>Text recognition runs on the Mac. No screen content leaves it unless your agent sends it to its model.</li>
                <li>
                  The hosted relay stores your email, hashed access tokens and which Macs are connected. Requests and
                  screenshots only pass through memory. See <a href="/privacy">privacy</a>.
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
