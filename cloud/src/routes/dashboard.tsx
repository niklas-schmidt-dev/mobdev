import { createFileRoute, redirect, useRouter } from "@tanstack/react-router";
import { useState, type FormEvent, type ReactNode } from "react";
import { Code, CopyButton, Page } from "../components/site";
import { createToken, deleteAccount, forgetMac, loadDashboard, revokeToken } from "../server/dashboard";

export const Route = createFileRoute("/dashboard")({
  head: () => ({ meta: [{ title: "Dashboard — Mobdev" }] }),
  loader: async ({ location }) => {
    const data = await loadDashboard();
    if (!data) {
      throw redirect({ href: `/api/auth/sign-in?returnPathname=${encodeURIComponent(location.pathname)}` });
    }
    return data;
  },
  component: Dashboard,
});

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

function Card({ title, subtitle, children, action }: { title: string; subtitle?: string; children: ReactNode; action?: ReactNode }) {
  return (
    <section className="rounded-3xl border border-white/10 bg-ink-raised p-6">
      <div className="mb-5 flex items-start gap-4">
        <div>
          <h2 className="text-lg font-semibold">{title}</h2>
          {subtitle && <p className="mt-1 text-sm text-muted">{subtitle}</p>}
        </div>
        <div className="ml-auto">{action}</div>
      </div>
      {children}
    </section>
  );
}

function Dashboard() {
  const data = Route.useLoaderData();
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
    <Page>
      <div className="mx-auto max-w-5xl px-5 py-12">
        <div className="flex flex-wrap items-end gap-4">
          <div>
            <p className="text-sm text-muted">{data.user.email}</p>
            <h1 className="mt-1 font-display text-4xl font-semibold tracking-tight">
              {data.user.firstName ? `Hi ${data.user.firstName}` : "Dashboard"}
            </h1>
          </div>
          <a href="/sign-out" className="glass ml-auto rounded-full px-4 py-2 text-sm hover:bg-white/10">
            Sign out
          </a>
        </div>

        {error && (
          <p role="alert" className="mt-6 rounded-2xl border border-red-400/30 bg-red-500/10 px-4 py-3 text-sm text-red-200">
            {error}
          </p>
        )}

        <div className="mt-8 grid gap-5">
          <Card
            title="Connect a Mac"
            subtitle="Access tokens let a Mac use the hosted relay at relay.mobdev.sh, so agents on other computers can reach its iPhone."
          >
            {created ? (
              <div className="rounded-2xl border border-lime/40 bg-lime/[0.06] p-5">
                <p className="font-medium">Token for “{created.name}” created</p>
                <p className="mt-1 text-sm text-muted">It is shown only once. Open it in Mobdev on the Mac, or copy it.</p>
                <div className="mt-4 flex flex-wrap items-center gap-3">
                  <a
                    href={deepLink}
                    className="rounded-full bg-lime px-5 py-2.5 text-sm font-medium text-ink hover:bg-lime-strong"
                  >
                    Open in Mobdev
                  </a>
                  <CopyButton text={created.token} label="Copy token" />
                  <button type="button" onClick={() => setCreated(null)} className="text-sm text-muted hover:text-paper">
                    Done
                  </button>
                </div>
                <div className="mt-4">
                  <Code copy={false}>{created.token}</Code>
                </div>
                <p className="mt-4 text-sm text-muted">
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
                  className="flex-1 rounded-full border border-white/10 bg-black/30 px-5 py-2.5 outline-none placeholder:text-faint focus:border-lime/60"
                />
                <button
                  type="submit"
                  disabled={busy}
                  className="rounded-full bg-lime px-6 py-2.5 font-medium text-ink transition hover:bg-lime-strong disabled:opacity-60"
                >
                  Create access token
                </button>
              </form>
            )}
          </Card>

          <Card title="Macs" subtitle={`${online} of ${data.hosts.length} connected`}>
            {data.hosts.length === 0 ? (
              <p className="text-sm text-muted">No Mac has connected yet. Create a token above and open it in Mobdev.</p>
            ) : (
              <ul className="divide-y divide-white/5">
                {data.hosts.map((host) => (
                  <li key={host.space_id + host.name} className="flex flex-wrap items-center gap-3 py-3">
                    <span
                      className={`size-2 rounded-full ${host.online ? "bg-lime shadow-[0_0_10px_rgba(209,237,165,0.8)]" : "bg-faint"}`}
                      aria-hidden="true"
                    />
                    <div className="min-w-0">
                      <p className="font-medium">{host.name}</p>
                      <p className="text-sm text-muted">
                        {host.online ? `Connected ${relative(host.connected_at)}` : `Last seen ${relative(host.disconnected_at)}`}
                        {host.token_id && tokenNames.get(host.token_id) ? ` · ${tokenNames.get(host.token_id)}` : ""}
                      </p>
                    </div>
                    <span className="sr-only">{host.online ? "online" : "offline"}</span>
                    {!host.online && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => run(() => forgetMac({ data: { spaceId: host.space_id, name: host.name } }))}
                        className="ml-auto text-sm text-muted hover:text-paper"
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
              <p className="text-sm text-muted">No tokens yet.</p>
            ) : (
              <ul className="divide-y divide-white/5">
                {data.tokens.map((token) => (
                  <li key={token.id} className="flex flex-wrap items-center gap-3 py-3">
                    <div className="min-w-0">
                      <p className="font-medium">{token.name}</p>
                      <p className="font-mono text-xs text-muted">
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
                      className="ml-auto rounded-full border border-red-400/30 px-3.5 py-1 text-sm text-red-200 hover:bg-red-500/10"
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
                  void run(async () => {
                    await deleteAccount();
                    window.location.href = "/sign-out";
                  });
                }
              }}
              className="rounded-full border border-red-400/30 px-4 py-2 text-sm text-red-200 hover:bg-red-500/10"
            >
              Delete account
            </button>
          </Card>
        </div>
      </div>
    </Page>
  );
}
