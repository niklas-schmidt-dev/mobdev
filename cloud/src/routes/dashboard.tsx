import { createFileRoute, redirect, useRouter } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { signOut } from "@workos/authkit-tanstack-react-start";
import { useState, type FormEvent, type ReactNode } from "react";
import type { Device } from "../../shared/devices";
import { PRO_PLAN, allowanceText } from "../../shared/plans";
import { Code, CopyButton, Page, buttonPrimary } from "../components/site";
import { pageMeta } from "../lib/meta";
import {
  createToken,
  deleteAccount,
  forgetMac,
  loadDashboard,
  openBillingPortal,
  revokeToken,
  upgradePlan,
  type BillingData,
  type DashboardData,
} from "../server/dashboard";

export const Route = createFileRoute("/dashboard")({
  head: () => ({ meta: pageMeta("Account — Mobdev", "/dashboard") }),
  // Stripe Checkout returns to /dashboard?upgraded=1.
  validateSearch: (search: Record<string, unknown>): { upgraded?: boolean } =>
    search.upgraded ? { upgraded: true } : {},
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
    // One clock reading for the server render and the hydration, so "5 min ago" matches in both.
    return { ...data, loadedAt: Date.now() };
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

// The worker renders in UTC with its own locale and the browser hydrates in the visitor's, so dates
// use a fixed locale and time zone; otherwise React rejects the server's HTML.
const shortDate = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
const longDay = new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", timeZone: "UTC" });

function relative(timestamp: number | null, now: number): string {
  if (!timestamp) return "never";
  const seconds = Math.round((now - timestamp) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h ago`;
  return shortDate.format(timestamp);
}

function Card({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <section className="rounded-3xl bg-card p-7 dark:inset-ring dark:inset-ring-white/5 sm:p-8">
      <h2 className="text-[24px] font-semibold tracking-tight">{title}</h2>
      {subtitle && <p className="mt-1.5 text-[15px] leading-[1.47] text-muted">{subtitle}</p>}
      <div className="mt-6">{children}</div>
    </section>
  );
}

const destructive = "text-[15px] text-danger transition-opacity hover:opacity-70 disabled:opacity-40";

function deviceStatus(device: Device, macOnline: boolean): { label: string; dot: string } {
  if (!macOnline) return { label: "Offline", dot: "bg-line" };
  if (device.ready) return { label: "Ready", dot: "bg-[#34c759]" };
  if (device.screen && !device.bluetooth) return { label: "Screen only", dot: "bg-[#ff9500]" };
  if (device.bluetooth && !device.screen) return { label: "Bluetooth only", dot: "bg-[#ff9500]" };
  return { label: "Not ready", dot: "bg-[#ff9500]" };
}

function DeviceGlyph({ tablet }: { tablet: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className="size-5 shrink-0 text-faint"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      aria-hidden="true"
    >
      {tablet ? <rect x="4" y="3" width="16" height="18" rx="2.5" /> : <rect x="7" y="2.5" width="10" height="19" rx="2.5" />}
      <path d="M11 18.5h2" />
    </svg>
  );
}

function DeviceRow({ device, macOnline }: { device: Device; macOnline: boolean }) {
  const tablet = device.device_class === "iPad";
  const system = tablet ? "iPadOS" : device.device_class === "Android" ? "Android" : "iOS";
  const name = device.name || device.model_name || device.device_class || "iPhone";
  const status = deviceStatus(device, macOnline);
  const details = [device.model_name || device.model, device.os_version ? `${system} ${device.os_version}` : ""]
    .filter(Boolean)
    .join(" · ");
  // Below `sm` the status moves under the details so names keep their room.
  const label = (className: string) => (
    <span className={`items-center gap-1.5 text-[13px] text-muted ${className}`}>
      <span className={`size-2 shrink-0 rounded-full ${status.dot}`} aria-hidden="true" />
      {status.label}
    </span>
  );
  return (
    <li className="flex items-center gap-3 rounded-2xl bg-mist px-4 py-3">
      <DeviceGlyph tablet={tablet} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-[15px] font-medium" title={name}>
          {name}
        </p>
        {details && <p className="truncate text-[13px] text-muted">{details}</p>}
        {label("mt-1 flex sm:hidden")}
      </div>
      {label("hidden shrink-0 sm:flex")}
    </li>
  );
}

const numbers = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });

function day(timestamp: number): string {
  return longDay.format(timestamp);
}

function Usage({ label, used, limit, unit }: { label: string; used: number; limit: number | null; unit?: string }) {
  const share = limit === null || limit <= 0 ? 0 : Math.min(1, used / limit);
  const tone = share >= 1 ? "bg-danger" : share >= 0.8 ? "bg-[#ff9500]" : "bg-blue";
  const amount = `${numbers.format(used)} of ${limit === null ? "unlimited" : numbers.format(limit)}${unit ? ` ${unit}` : ""}`;
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3 text-[15px]">
        <span className="font-medium">{label}</span>
        <span className="text-muted">{amount}</span>
      </div>
      <div
        role="progressbar"
        aria-label={label}
        aria-valuetext={amount}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.round(share * 100)}
        className="mt-2 h-1.5 overflow-hidden rounded-full bg-mist"
      >
        <div className={`h-full rounded-full ${tone}`} style={{ width: `${share * 100}%` }} />
      </div>
    </div>
  );
}

function PlanCard({
  billing,
  online,
  upgraded,
  busy,
  open,
}: {
  billing: BillingData;
  online: number;
  upgraded: boolean;
  busy: boolean;
  open: (action: () => Promise<{ url: string | null }>) => void;
}) {
  const { plan } = billing;
  const hours = (seconds: number) => Math.round(seconds / 360) / 10;
  return (
    <Card
      title="Plan"
      subtitle={`${plan.name}${plan.priceUsd ? ` · $${plan.priceUsd} USD a month, plus applicable tax` : ""}. Limits apply to the hosted relay; Mobdev on your Mac has none.`}
    >
      {billing.pastDue && (
        <p role="alert" className="mb-5 rounded-2xl bg-alert px-5 py-4 text-[15px] text-alert-ink">
          The last payment failed. Update your payment method under “Manage billing”.
        </p>
      )}
      {upgraded && plan.priceUsd === 0 && (
        <p className="mb-5 rounded-2xl bg-mist px-5 py-4 text-[15px] text-muted">
          Thanks! Stripe is confirming your payment. Reload this page in a moment to see {PRO_PLAN.name}.
        </p>
      )}
      <div className="space-y-5">
        <Usage
          label="Requests"
          used={billing.requests.used}
          limit={billing.requests.unlimited ? null : billing.requests.granted}
        />
        <Usage
          label="Active time"
          used={hours(billing.activeSeconds.used)}
          limit={billing.activeSeconds.unlimited ? null : hours(billing.activeSeconds.granted)}
          unit="hours"
        />
        <Usage label="Connected Macs" used={online} limit={billing.macs} />
      </div>
      <p className="mt-5 text-[14px] leading-[1.47] text-muted">
        Active time counts while a Mac works on an agent’s request, not while it waits.
        {billing.resetsAt ? ` Requests and active time renew on ${day(billing.resetsAt)}.` : ""}
        {billing.endsAt ? ` ${plan.name} ends on ${day(billing.endsAt)}; the Free plan applies after that.` : ""}
      </p>
      <div className="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3">
        {plan.priceUsd === 0 ? (
          <>
            <button type="button" disabled={busy} onClick={() => open(() => upgradePlan())} className={buttonPrimary}>
              Upgrade to {PRO_PLAN.name} · ${PRO_PLAN.priceUsd} a month
            </button>
            <p className="text-[14px] text-muted">
              USD, plus applicable tax. {PRO_PLAN.macs} Macs, {allowanceText(PRO_PLAN)}.
            </p>
          </>
        ) : (
          <button
            type="button"
            disabled={busy}
            onClick={() => open(() => openBillingPortal())}
            className="text-[15px] text-link hover:underline underline-offset-4"
          >
            Manage billing
          </button>
        )}
      </div>
    </Card>
  );
}

function Dashboard({ data }: { data: DashboardData & { loadedAt: number } }) {
  const router = useRouter();
  const { upgraded = false } = Route.useSearch();
  const [name, setName] = useState("");
  const [created, setCreated] = useState<{ name: string; token: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // A POST to AuthKit's server function, which the CSRF check covers; see routes/sign-out.tsx.
  const signOutNow = useServerFn(signOut);
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

  /** Runs a billing action and follows the Stripe page it returns. */
  async function open(action: () => Promise<{ url: string | null }>) {
    setBusy(true);
    setError(null);
    try {
      const { url } = await action();
      if (url) {
        window.location.assign(url);
        return;
      }
      await router.invalidate();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    }
    setBusy(false);
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
          <button
            type="button"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              signOutNow({ data: { returnTo: "/" } }).catch((reason: unknown) => {
                setError(reason instanceof Error ? reason.message : String(reason));
                setBusy(false);
              });
            }}
            className="ml-auto text-[15px] text-link hover:underline underline-offset-4"
          >
            Sign out
          </button>
        </div>

        {error && (
          <p role="alert" className="mt-8 rounded-2xl bg-alert px-5 py-4 text-[15px] text-alert-ink">
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
                  className="h-12 flex-1 rounded-xl border border-line bg-card px-4 text-[17px] outline-none transition-shadow placeholder:text-faint focus:border-blue focus:ring-4 focus:ring-blue/15"
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
                  <li key={host.space_id + host.name} className="py-4 first:pt-0 last:pb-0">
                    <div className="flex items-center gap-4">
                      <span
                        className={`size-2.5 shrink-0 rounded-full ${host.online ? "bg-[#34c759]" : "bg-line"}`}
                        aria-hidden="true"
                      />
                      <div className="min-w-0">
                        <p className="text-[17px] font-medium">{host.name}</p>
                        <p className="text-[14px] text-muted">
                          {host.online
                            ? `Connected ${relative(host.connected_at, data.loadedAt)}`
                            : `Last seen ${relative(host.disconnected_at, data.loadedAt)}`}
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
                    </div>
                    {host.devices.length > 0 ? (
                      <ul className="mt-3 space-y-2 pl-[26px]" aria-label={`Devices of ${host.name}`}>
                        {host.devices.map((device) => (
                          <DeviceRow key={device.id} device={device} macOnline={host.online === 1} />
                        ))}
                      </ul>
                    ) : (
                      host.devices_updated_at !== null && (
                        <p className="mt-1 pl-[26px] text-[14px] text-muted">No iPhone connected.</p>
                      )
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          {data.billing === "unavailable" && (
            <Card title="Plan">
              <p className="text-[15px] text-muted">
                Your plan could not be loaded right now. Your Macs and agents keep working; try again in a moment.
              </p>
            </Card>
          )}
          {typeof data.billing === "object" && (
            <PlanCard billing={data.billing} online={online} upgraded={upgraded} busy={busy} open={open} />
          )}

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
                        {token.prefix}… · created {relative(token.created_at, data.loadedAt)} · used{" "}
                        {relative(token.last_used_at, data.loadedAt)}
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
                    .then(() => signOutNow({ data: { returnTo: "/" } }))
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
