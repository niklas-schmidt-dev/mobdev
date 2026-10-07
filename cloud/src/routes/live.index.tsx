import { Link, createFileRoute, redirect } from "@tanstack/react-router";
import { T, useGT } from "gt-tanstack-start";
import { useCallback, useState } from "react";
import { LiveScreen } from "../components/live";
import { ShareDialog } from "../components/share-dialog";
import { Page } from "../components/site";
import { currentLocale } from "../lib/i18n";
import { privatePageHead } from "../lib/meta";
import { loadLive, ownerTicket, type LivePageState } from "../server/live";

// The owner's live view of one device: /live?space=<space>&mac=<name>&device=<id>, opened from the
// dashboard's device list.
export const Route = createFileRoute("/live/")({
  head: () => privatePageHead(currentLocale() === "de" ? "Live-Ansicht — Mobdev" : "Live view — Mobdev"),
  validateSearch: (search: Record<string, unknown>): { space: string; mac: string; device: string } => ({
    space: String(search.space ?? ""),
    mac: String(search.mac ?? ""),
    device: String(search.device ?? ""),
  }),
  loaderDeps: ({ search }) => search,
  loader: async ({ deps, location }) => {
    const data = await loadLive({ data: { spaceId: deps.space, mac: deps.mac, device: deps.device } });
    if (data.state === "signed-out") {
      // A full page load, as on the dashboard: the sign-in route only exists on the server.
      throw redirect({
        href: `/api/auth/sign-in?returnPathname=${encodeURIComponent(location.href)}`,
        reloadDocument: true,
      });
    }
    return data;
  },
  component: LivePage,
});

function LivePage() {
  const data = Route.useLoaderData();
  if (data.state === "ready") return <OwnerLive data={data} />;
  return (
    <Page tone="mist">
      <div className="mx-auto max-w-xl px-5 py-32 text-center">
        {data.state === "unknown" ? (
          <T>
            <h1 className="headline text-[40px]">Mac not found.</h1>
            <p className="mt-4 text-[19px] leading-[1.45] text-muted">
              This Mac is not in your account. Open the live view from your <Link to="/dashboard">dashboard</Link>.
            </p>
          </T>
        ) : (
          <T>
            <h1 className="headline text-[40px]">Almost there.</h1>
            <p className="mt-4 text-[19px] leading-[1.45] text-muted">Accounts are being set up.</p>
          </T>
        )}
      </div>
    </Page>
  );
}

function OwnerLive({ data }: { data: Extract<LivePageState, { state: "ready" }> }) {
  const gt = useGT();
  const [sharing, setSharing] = useState(false);
  const { spaceId, mac, deviceId } = data;
  const getTicket = useCallback(() => ownerTicket({ data: { spaceId, mac, device: deviceId } }), [spaceId, mac, deviceId]);
  const name = data.device?.name || data.device?.model_name || deviceId || gt("Device");
  const details = [data.device?.model_name, mac].filter(Boolean).join(" · ");
  return (
    <Page tone="mist">
      <div className="mx-auto max-w-5xl px-5 pb-20 pt-8">
        <Link to="/dashboard" className="text-[15px] text-link hover:underline underline-offset-4">
          ‹ <T>Account</T>
        </Link>
        <div className="mt-4 text-center">
          <h1 className="headline text-[36px] sm:text-[44px]">{name}</h1>
          <p className="mt-2 text-[17px] text-muted">{details}</p>
        </div>
        <div className="mt-8">
          <LiveScreen getTicket={getTicket} label={name} deviceClass={data.device?.device_class ?? "iPhone"}>
            <button
              type="button"
              onClick={() => setSharing(true)}
              aria-haspopup="dialog"
              className="inline-flex items-center gap-2 rounded-full bg-card px-5 py-2.5 text-[15px] font-medium shadow-sm ring-1 ring-black/5 transition-colors hover:bg-mist dark:shadow-none dark:ring-white/10"
            >
              <svg viewBox="0 0 24 24" className="size-4" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true">
                <path d="M12 15V3.5M8 7.5l4-4 4 4M6 11H5v9.5h14V11h-1" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
              <T>Share…</T>
            </button>
          </LiveScreen>
        </div>
      </div>
      <ShareDialog
        open={sharing}
        onClose={() => setSharing(false)}
        spaceId={spaceId}
        mac={mac}
        device={deviceId}
        deviceName={name}
        shares={data.shares}
        loadedAt={data.loadedAt}
      />
    </Page>
  );
}
