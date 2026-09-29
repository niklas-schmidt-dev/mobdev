import { createFileRoute, redirect, useRouter } from "@tanstack/react-router";
import { useState, type FormEvent, type ReactNode } from "react";
import { Code, CopyButton, Page, buttonPrimary } from "../components/site";
import {
  createToken,
  deleteAccount,
  forgetMac,
  loadDashboard,
  revokeToken,
  type DashboardData,
} from "../server/dashboard";

export const Route = createFileRoute("/dashboard")({
  head: () => ({ meta: [{ title: "Account — Mobdev" }] }),
  loader: async ({ location }) => {
    const data = await loadDashboard();
    if (data.state === "signed-out") {
      // A full page load: the sign-in route only exists on the server, so an in-app navigation
      // after clicking a link to /dashboard would render "Not Found".
      throw redirect({
        href: `/api/auth/sign-in?returnPathname=${encodeURIComponent(location.pathname)}`,
        reloadDocument: true,
      });
    }
    return data;
  },
  component: DashboardPage,
});

function DashboardPage() {
  const data = Route.useLoaderData();
  if (data.state !== "ready") {
    return (
      <Page tone="mist">
        <div className="mx-auto max-w-xl px-5 py-32 text-center">
          <h1 className="headline text-[40px]">Almost there.</h1>
          <p className="mt-4 text-[19px] leading-[1.45] text-muted">
            Accounts are being set up. The Mac app and self-hosted relay work without one in the meantime.
          </p>
        </div>
      </Page>
    );
  }
  return <Dashboard data={data} />;
}

function relative(timestamp: number | null): string {
  if (!timestamp) return "never";
  const seconds = Math.round((Date.now() - timestamp) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return new Date(timestamp).toLocaleDateString();
}

function Card({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <section className="rounded-3xl bg-white p-7 sm:p-8">
      <h2 className="text-[24px] font-semibold tracking-tight">{title}</h2>
      {subtitle && <p className="mt-1.5 text-[15px] leading-[1.47] text-muted">{subtitle}</p>}
      <div className="mt-6">{children}</div>
    </section>
  );
}

const destructive = "text-[15px] text-[#e30000] transition-opacity hover:opacity-70 disabled:opacity-40";

function Dashboard({ data }: { data: DashboardData }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [created, setCreated] = useState<{ name: string; token: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const online = data.hosts.filter((host) => host.online === 1).length;
  const tokenNames = new Map(data.tokens.map((token) => [token.id, token.name]));

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setError(null);
    try {
      await action();
      await router.invalidate();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  }

  async function onCreate(event: FormEvent) {
    event.preventDefault();
    await run(async () => {
      const result = await createToken({ data: { name: name || "My Mac" } });
      setCreated({ name: result.name, token: result.token });
      setName("");
    });
  }

  const deepLink = created
    ? `mobdev://connect?relay=${encodeURIComponent(data.relayUrl)}&token=${encodeURIComponent(created.token)}`
    : "";

  return (
    <Page tone="mist">
      <div className="mx-auto max-w-3xl px-5 py-16">
        <div className="flex flex-wrap items-end gap-4">
          <div>
            <h1 className="headline text-[48px]">{data.user.firstName ? `Hi, ${data.user.firstName}.` : "Account"}</h1>
            <p className="mt-2 text-[17px] text-muted">{data.user.email}</p>
          </div>
          <a href="/sign-out" className="ml-auto text-[15px] text-link hover:underline underline-offset-4">
            Sign out
          </a>
        </div>

        {error && (
          <p role="alert" className="mt-8 rounded-2xl bg-[#fff2f2] px-5 py-4 text-[15px] text-[#b00000]">
            {error}
          </p>
        )}

        <div className="mt-10 space-y-5">
          <Card
            title="Connect a Mac"
            subtitle="An access token lets a Mac use the hosted relay, so agents on other computers can reach its iPhone."
          >
            {created ? (
              <div>
                <p className="text-[17px] font-semibold">Your token for “{created.name}”</p>
                <p className="mt-1 text-[15px] text-muted">It is shown only once. Open it in Mobdev on that Mac, or copy it.</p>
                <div className="mt-5">
                  <Code copy={false}>{created.token}</Code>
                </div>
                <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-3">
                  <a href={deepLink} className={buttonPrimary}>
                    Open in Mobdev
                  </a>
                  <CopyButton text={created.token} label="Copy token" />
                  <button
                    type="button"
                    onClick={() => setCreated(null)}
                    className="text-[15px] text-link hover:underline underline-offset-4"
                  >
                    Done
                  </button>
                </div>
                <p className="mt-5 text-[15px] leading-[1.47] text-muted">
                  Then copy the remote command from Remote Access in the app and run it where your agent lives.
                </p>
              </div>
            ) : (
              <form onSubmit={onCreate} className="flex flex-col gap-3 sm:flex-row">
                <label className="sr-only" htmlFor="token-name">
                  Name for this Mac
                </label>
                <input
                  id="token-name"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  placeholder="Name, e.g. Studio Mac"
                  maxLength={60}
                  className="h-12 flex-1 rounded-xl border border-line bg-white px-4 text-[17px] outline-none transition-shadow placeholder:text-faint focus:border-blue focus:ring-4 focus:ring-blue/15"
                />
                <button type="submit" disabled={busy} className={`${buttonPrimary} h-12 py-0`}>
                  Create token
                </button>
              </form>
            )}
          </Card>

          <Card title="Macs" subtitle={data.hosts.length ? `${online} of ${data.hosts.length} connected.` : undefined}>
            {data.hosts.length === 0 ? (
              <p className="text-[15px] text-muted">No Mac has connected yet. Create a token above and open it in Mobdev.</p>
            ) : (
              <ul className="divide-y divide-line/70">
                {data.hosts.map((host) => (
                  <li key={host.space_id + host.name} className="flex items-center gap-4 py-4 first:pt-0 last:pb-0">
                    <span
                      className={`size-2.5 shrink-0 rounded-full ${host.online ? "bg-[#34c759]" : "bg-line"}`}
                      aria-hidden="true"
                    />
                    <div className="min-w-0">
                      <p className="text-[17px] font-medium">{host.name}</p>
                      <p className="text-[14px] text-muted">
                        {host.online ? `Connected ${relative(host.connected_at)}` : `Last seen ${relative(host.disconnected_at)}`}
                        {host.token_id && tokenNames.get(host.token_id) ? ` · ${tokenNames.get(host.token_id)}` : ""}
                        <span className="sr-only">{host.online ? ", online" : ", offline"}</span>
                      </p>
                    </div>
                    {!host.online && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => run(() => forgetMac({ data: { spaceId: host.space_id, name: host.name } }))}
                        className="ml-auto text-[15px] text-link hover:underline underline-offset-4"
                      >
                        Forget
                      </button>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Access tokens" subtitle="Revoking a token disconnects every Mac that uses it.">
            {data.tokens.length === 0 ? (
              <p className="text-[15px] text-muted">No tokens yet.</p>
            ) : (
              <ul className="divide-y divide-line/70">
                {data.tokens.map((token) => (
                  <li key={token.id} className="flex items-center gap-4 py-4 first:pt-0 last:pb-0">
                    <div className="min-w-0">
                      <p className="text-[17px] font-medium">{token.name}</p>
                      <p className="text-[14px] text-muted">
                        {token.prefix}… · created {relative(token.created_at)} · used {relative(token.last_used_at)}
                      </p>
                    </div>
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => {
                        if (confirm(`Revoke “${token.name}”? Macs using it disconnect.`)) {
                          void run(() => revokeToken({ data: { id: token.id } }));
                        }
                      }}
                      className={`ml-auto ${destructive}`}
                    >
                      Revoke
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Delete account" subtitle="Removes your account, tokens and Mac records, and disconnects your Macs.">
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                if (confirm("Delete your Mobdev account? This cannot be undone.")) {
                  setBusy(true);
                  // No reload in between: loading the dashboard would create the account again.
                  deleteAccount()
                    .then(() => window.location.assign("/sign-out"))
                    .catch((reason: unknown) => {
                      setError(reason instanceof Error ? reason.message : String(reason));
                      setBusy(false);
                    });
                }
              }}
              className={destructive}
            >
              Delete account…
            </button>
          </Card>
        </div>
      </div>
    </Page>
  );
}
