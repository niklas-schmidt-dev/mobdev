import { Link, createFileRoute, redirect, useRouter } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { signOut } from "@workos/authkit-tanstack-react-start";
import { Num, T, Var, msg, useGT, useLocale, useMessages } from "gt-tanstack-start";
import { useState, type FormEvent, type ReactNode } from "react";
import type { Device } from "../../shared/devices";
import { PRO_PLAN } from "../../shared/plans";
import { useExpiry } from "../components/share-dialog";
import { Code, CopyButton, Page, buttonPrimary } from "../components/site";
import { currentLocale } from "../lib/i18n";
import { toLocale, type Locale } from "../lib/locales";
import { privatePageHead } from "../lib/meta";
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
import { revokeShareLink } from "../server/live";

export const Route = createFileRoute("/dashboard")({
  head: () => privatePageHead(currentLocale() === "de" ? "Konto — Mobdev" : "Account — Mobdev"),
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
          <T>
            <h1 className="headline text-[40px]">Almost there.</h1>
            <p className="mt-4 text-[19px] leading-[1.45] text-muted">
              Accounts are being set up. The Mac app and self-hosted relay work without one in the meantime.
            </p>
          </T>
        </div>
      </Page>
    );
  }
  return <Dashboard data={data} />;
}

// The worker renders in UTC with its own locale and the browser hydrates in the visitor's, so dates
// and numbers use the page language and UTC, which both know; otherwise React rejects the server's HTML.
function formats(locale: string) {
  return {
    shortDate: new Intl.DateTimeFormat(locale, { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }),
    longDay: new Intl.DateTimeFormat(locale, { month: "long", day: "numeric", timeZone: "UTC" }),
    numbers: new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }),
  };
}

const FORMATS: Record<Locale, ReturnType<typeof formats>> = { en: formats("en-US"), de: formats("de-DE") };

function useFormats() {
  return FORMATS[toLocale(useLocale())];
}

/** "5 min ago" and the like, measured from `now`; older times as a date. */
function useAgo(now: number): (timestamp: number | null) => string {
  const gt = useGT();
  const { shortDate } = useFormats();
  return (timestamp) => {
    if (!timestamp) return gt("never");
    const seconds = Math.round((now - timestamp) / 1000);
    if (seconds < 60) return gt("just now");
    const minutes = Math.round(seconds / 60);
    if (minutes < 60) return gt("{minutes} min ago", { minutes });
    const hours = Math.round(minutes / 60);
    if (hours < 48) return gt("{hours} h ago", { hours });
    return shortDate.format(timestamp);
  };
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

/** The label is registered with msg; translate it with useMessages. */
function deviceStatus(device: Device, macOnline: boolean): { label: string; dot: string } {
  if (!macOnline) return { label: msg("Offline"), dot: "bg-line" };
  if (device.ready) return { label: msg("Ready"), dot: "bg-[#34c759]" };
  if (device.screen && !device.bluetooth) return { label: msg("Screen only"), dot: "bg-[#ff9500]" };
  if (device.bluetooth && !device.screen) return { label: msg("Bluetooth only"), dot: "bg-[#ff9500]" };
  return { label: msg("Not ready"), dot: "bg-[#ff9500]" };
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

function DeviceRow({ device, host }: { device: Device; host: { space_id: string; name: string; online: number } }) {
  const m = useMessages();
  const gt = useGT();
  const macOnline = host.online === 1;
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
      {m(status.label)}
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
      {/* Watching needs the Mac online and the device's picture. */}
      {macOnline && device.screen && (
        <Link
          to="/live"
          search={{ space: host.space_id, mac: host.name, device: device.id }}
          aria-label={gt("Watch {name} live", { name })}
          className="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-card px-3 py-1 text-[13px] font-medium text-link ring-1 ring-black/5 transition-colors hover:bg-white dark:ring-white/10 dark:hover:bg-white/15"
        >
          <svg viewBox="0 0 24 24" className="size-3.5" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
            <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
            <circle cx="12" cy="12" r="3" />
          </svg>
          <T>Live</T>
        </Link>
      )}
    </li>
  );
}

function Usage({ label, used, limit, hours }: { label: string; used: number; limit: number | null; hours?: boolean }) {
  const gt = useGT();
  const { numbers } = useFormats();
  const share = limit === null || limit <= 0 ? 0 : Math.min(1, used / limit);
  const tone = share >= 1 ? "bg-danger" : share >= 0.8 ? "bg-[#ff9500]" : "bg-blue";
  const values = { used: numbers.format(used), limit: limit === null ? "" : numbers.format(limit) };
  const amount =
    limit === null
      ? hours
        ? gt("{used} of unlimited hours", values)
        : gt("{used} of unlimited", values)
      : hours
        ? gt("{used} of {limit} hours", values)
        : gt("{used} of {limit}", values);
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
  const gt = useGT();
  const { longDay } = useFormats();
  const { plan } = billing;
  const hours = (seconds: number) => Math.round(seconds / 360) / 10;
  return (
    <Card
      title={gt("Plan")}
      subtitle={
        plan.priceUsd
          ? gt(
              "{plan} · ${price} USD a month, plus applicable tax. Limits apply to the hosted relay; Mobdev on your Mac has none.",
              { plan: plan.name, price: plan.priceUsd },
            )
          : gt("{plan}. Limits apply to the hosted relay; Mobdev on your Mac has none.", { plan: plan.name })
      }
    >
      {billing.pastDue && (
        <T>
          <p role="alert" className="mb-5 rounded-2xl bg-alert px-5 py-4 text-[15px] text-alert-ink">
            The last payment failed. Update your payment method under “Manage billing”.
          </p>
        </T>
      )}
      {upgraded && plan.priceUsd === 0 && (
        <T>
          <p className="mb-5 rounded-2xl bg-mist px-5 py-4 text-[15px] text-muted">
            Thanks! Stripe is confirming your payment. Reload this page in a moment to see <Var>{PRO_PLAN.name}</Var>.
          </p>
        </T>
      )}
      <div className="space-y-5">
        <Usage
          label={gt("Requests")}
          used={billing.requests.used}
          limit={billing.requests.unlimited ? null : billing.requests.granted}
        />
        <Usage
          label={gt("Active time")}
          used={hours(billing.activeSeconds.used)}
          limit={billing.activeSeconds.unlimited ? null : hours(billing.activeSeconds.granted)}
          hours
        />
        <Usage label={gt("Connected Macs")} used={online} limit={billing.macs} />
      </div>
      <p className="mt-5 text-[14px] leading-[1.47] text-muted">
        <T>Active time counts while a Mac works on an agent’s request, not while it waits.</T>
        {billing.resetsAt ? (
          <>
            {" "}
            <T>
              Requests and active time renew on <Var>{longDay.format(billing.resetsAt)}</Var>.
            </T>
          </>
        ) : null}
        {billing.endsAt ? (
          <>
            {" "}
            <T>
              <Var>{plan.name}</Var> ends on <Var>{longDay.format(billing.endsAt)}</Var>; the Free plan applies after
              that.
            </T>
          </>
        ) : null}
      </p>
      <div className="mt-6 flex flex-wrap items-center gap-x-5 gap-y-3">
        {plan.priceUsd === 0 ? (
          <>
            <button type="button" disabled={busy} onClick={() => open(() => upgradePlan())} className={buttonPrimary}>
              <T>
                Upgrade to <Var>{PRO_PLAN.name}</Var> · $<Num>{PRO_PLAN.priceUsd}</Num> a month
              </T>
            </button>
            <T>
              <p className="text-[14px] text-muted">
                USD, plus applicable tax. <Num>{PRO_PLAN.macs}</Num> Macs, <Num>{PRO_PLAN.requests}</Num> requests
                and <Num>{PRO_PLAN.activeHours}</Num> active hours a month.
              </p>
            </T>
          </>
        ) : (
          <button
            type="button"
            disabled={busy}
            onClick={() => open(() => openBillingPortal())}
            className="text-[15px] text-link hover:underline underline-offset-4"
          >
            <T>Manage billing</T>
          </button>
        )}
      </div>
    </Card>
  );
}

function Dashboard({ data }: { data: DashboardData & { loadedAt: number } }) {
  const gt = useGT();
  const ago = useAgo(data.loadedAt);
  const expiry = useExpiry(data.loadedAt);
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
      const result = await createToken({ data: { name: name || gt("My Mac") } });
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
            <h1 className="headline text-[48px]">
              {data.user.firstName ? (
                <T>
                  Hi, <Var>{data.user.firstName}</Var>.
                </T>
              ) : (
                <T>Account</T>
              )}
            </h1>
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
            <T>Sign out</T>
          </button>
        </div>

        {error && (
          <p role="alert" className="mt-8 rounded-2xl bg-alert px-5 py-4 text-[15px] text-alert-ink">
            {error}
          </p>
        )}

        <div className="mt-10 space-y-5">
          <Card
            title={gt("Connect a Mac")}
            subtitle={gt(
              "An access token lets a Mac use the hosted relay, so agents on other computers can reach its iPhone.",
            )}
          >
            {created ? (
              <div>
                <T>
                  <p className="text-[17px] font-semibold">
                    Your token for “<Var>{created.name}</Var>”
                  </p>
                  <p className="mt-1 text-[15px] text-muted">
                    It is shown only once. Open it in Mobdev on that Mac, or copy it.
                  </p>
                </T>
                <div className="mt-5">
                  <Code copy={false}>{created.token}</Code>
                </div>
                <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-3">
                  <a href={deepLink} className={buttonPrimary}>
                    <T>Open in Mobdev</T>
                  </a>
                  <CopyButton text={created.token} label={gt("Copy token")} />
                  <button
                    type="button"
                    onClick={() => setCreated(null)}
                    className="text-[15px] text-link hover:underline underline-offset-4"
                  >
                    <T>Done</T>
                  </button>
                </div>
                <T>
                  <p className="mt-5 text-[15px] leading-[1.47] text-muted">
                    Then copy the remote command from Remote Access in the app and run it where your agent lives.
                  </p>
                </T>
              </div>
            ) : (
              <form onSubmit={onCreate} className="flex flex-col gap-3 sm:flex-row">
                <label className="sr-only" htmlFor="token-name">
                  <T>Name for this Mac</T>
                </label>
                <input
                  id="token-name"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  placeholder={gt("Name, e.g. Studio Mac")}
                  maxLength={60}
                  className="h-12 flex-1 rounded-xl border border-line bg-card px-4 text-[17px] outline-none transition-shadow placeholder:text-faint focus:border-blue focus:ring-4 focus:ring-blue/15"
                />
                <button type="submit" disabled={busy} className={`${buttonPrimary} h-12 py-0`}>
                  <T>Create token</T>
                </button>
              </form>
            )}
          </Card>

          <Card
            title={gt("Macs")}
            subtitle={
              data.hosts.length
                ? gt("{online} of {total} connected.", { online, total: data.hosts.length })
                : undefined
            }
          >
            {data.hosts.length === 0 ? (
              <T>
                <p className="text-[15px] text-muted">
                  No Mac has connected yet. Create a token above and open it in Mobdev.
                </p>
              </T>
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
                            ? gt("Connected {when}", { when: ago(host.connected_at) })
                            : gt("Last seen {when}", { when: ago(host.disconnected_at) })}
                          {host.token_id && tokenNames.get(host.token_id) ? ` · ${tokenNames.get(host.token_id)}` : ""}
                          <span className="sr-only">{host.online ? gt(", online") : gt(", offline")}</span>
                        </p>
                      </div>
                      {!host.online && (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => run(() => forgetMac({ data: { spaceId: host.space_id, name: host.name } }))}
                          className="ml-auto text-[15px] text-link hover:underline underline-offset-4"
                        >
                          <T>Forget</T>
                        </button>
                      )}
                    </div>
                    {host.devices.length > 0 ? (
                      <ul
                        className="mt-3 space-y-2 pl-[26px]"
                        aria-label={gt("Devices of {name}", { name: host.name })}
                      >
                        {host.devices.map((device) => (
                          <DeviceRow key={device.id} device={device} host={host} />
                        ))}
                      </ul>
                    ) : (
                      host.devices_updated_at !== null && (
                        <T>
                          <p className="mt-1 pl-[26px] text-[14px] text-muted">No iPhone connected.</p>
                        </T>
                      )
                    )}
                  </li>
                ))}
              </ul>
            )}
          </Card>

          {data.shares.length > 0 && (
            <Card
              title={gt("Shared live views")}
              subtitle={gt("Anyone with one of these links can watch until it expires. Revoking ends their view at once.")}
            >
              <ul className="divide-y divide-line/70">
                {data.shares.map((share) => {
                  const host = data.hosts.find((row) => row.space_id === share.space_id && row.name === share.mac);
                  const device = share.device ? host?.devices.find((candidate) => candidate.id === share.device) : null;
                  const shows = share.device === null ? share.mac : `${device?.name || share.device} · ${share.mac}`;
                  return (
                    <li key={share.id} className="flex items-center gap-4 py-4 first:pt-0 last:pb-0">
                      <div className="min-w-0">
                        <p className="truncate text-[17px] font-medium">{share.label}</p>
                        <p className="text-[14px] text-muted">
                          {shows} · {share.mode === "control" ? gt("View and control") : gt("View only")} ·{" "}
                          {expiry(share.expires_at)}
                        </p>
                      </div>
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void run(() => revokeShareLink({ data: { id: share.id } }))}
                        aria-label={gt("Revoke “{name}”", { name: share.label })}
                        className={`ml-auto ${destructive}`}
                      >
                        <T>Revoke</T>
                      </button>
                    </li>
                  );
                })}
              </ul>
            </Card>
          )}

          {data.billing === "unavailable" && (
            <Card title={gt("Plan")}>
              <T>
                <p className="text-[15px] text-muted">
                  Your plan could not be loaded right now. Your Macs and agents keep working; try again in a moment.
                </p>
              </T>
            </Card>
          )}
          {typeof data.billing === "object" && (
            <PlanCard billing={data.billing} online={online} upgraded={upgraded} busy={busy} open={open} />
          )}

          <Card title={gt("Access tokens")} subtitle={gt("Revoking a token disconnects every Mac that uses it.")}>
            {data.tokens.length === 0 ? (
              <T>
                <p className="text-[15px] text-muted">No tokens yet.</p>
              </T>
            ) : (
              <ul className="divide-y divide-line/70">
                {data.tokens.map((token) => (
                  <li key={token.id} className="flex items-center gap-4 py-4 first:pt-0 last:pb-0">
                    <div className="min-w-0">
                      <p className="text-[17px] font-medium">{token.name}</p>
                      <T>
                        <p className="text-[14px] text-muted">
                          <Var>{token.prefix}</Var>… · created <Var>{ago(token.created_at)}</Var> ·
                          used <Var>{ago(token.last_used_at)}</Var>
                        </p>
                      </T>
                    </div>
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => {
                        if (confirm(gt("Revoke “{name}”? Macs using it disconnect.", { name: token.name }))) {
                          void run(() => revokeToken({ data: { id: token.id } }));
                        }
                      }}
                      className={`ml-auto ${destructive}`}
                    >
                      <T>Revoke</T>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card
            title={gt("Delete account")}
            subtitle={gt("Removes your account, tokens and Mac records, and disconnects your Macs.")}
          >
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                if (confirm(gt("Delete your Mobdev account? This cannot be undone."))) {
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
              <T>Delete account…</T>
            </button>
          </Card>
        </div>
      </div>
    </Page>
  );
}
