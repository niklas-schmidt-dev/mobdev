import { createFileRoute } from "@tanstack/react-router";
import { T, Var, useGT } from "gt-tanstack-start";
import { useCallback, useState } from "react";
import { LiveScreen } from "../components/live";
import { useExpiry } from "../components/share-dialog";
import { Page } from "../components/site";
import { currentLocale } from "../lib/i18n";
import { privatePageHead } from "../lib/meta";
import { loadShare, shareTicket, type SharePageState } from "../server/live";

// A share link: whoever has it watches, or watches and controls, what its owner shared until it
// expires. No account needed; the link itself is the key, so the page stays out of search results.
export const Route = createFileRoute("/live/$token")({
  head: () => privatePageHead(currentLocale() === "de" ? "Geteilte Live-Ansicht — Mobdev" : "Shared live view — Mobdev"),
  loader: ({ params }) => loadShare({ data: { token: params.token } }),
  component: SharePage,
});

function SharePage() {
  const data = Route.useLoaderData();
  const { token } = Route.useParams();
  if (data.state === "ready") return <SharedLive token={token} data={data} />;
  return (
    <Page tone="mist">
      <div className="mx-auto max-w-xl px-5 py-32 text-center">
        {data.state === "expired" ? (
          <T>
            <h1 className="headline text-[40px]">This link has expired.</h1>
            <p className="mt-4 text-[19px] leading-[1.45] text-muted">Ask whoever shared it for a new one.</p>
          </T>
        ) : (
          <T>
            <h1 className="headline text-[40px]">This link is not valid.</h1>
            <p className="mt-4 text-[19px] leading-[1.45] text-muted">
              It may have been revoked or copied incompletely. Ask whoever shared it for a new one.
            </p>
          </T>
        )}
      </div>
    </Page>
  );
}

function SharedLive({ token, data }: { token: string; data: Extract<SharePageState, { state: "ready" }> }) {
  const gt = useGT();
  const expiry = useExpiry(data.loadedAt);
  const [device, setDevice] = useState(data.devices[0]?.id ?? null);
  const getTicket = useCallback(() => shareTicket({ data: { token, device: device ?? "" } }), [token, device]);
  const current = data.devices.find((candidate) => candidate.id === device) ?? null;
  const name = (candidate: (typeof data.devices)[number]) => candidate.name || candidate.model_name || candidate.id;
  return (
    <Page tone="mist">
      <div className="mx-auto max-w-5xl px-5 pb-20 pt-10">
        <div className="text-center">
          <h1 className="headline text-[36px] sm:text-[44px]">{data.label}</h1>
          <p className="mt-2 text-[17px] text-muted">
            {[data.mac, data.mode === "control" ? gt("View and control") : gt("View only"), expiry(data.expiresAt)].join(" · ")}
          </p>
        </div>

        {data.devices.length > 1 && (
          <div role="group" aria-label={gt("Device")} className="mt-6 flex flex-wrap justify-center gap-2">
            {data.devices.map((candidate) => (
              <button
                key={candidate.id}
                type="button"
                aria-pressed={candidate.id === device}
                onClick={() => setDevice(candidate.id)}
                className={`rounded-full px-4 py-2 text-[15px] transition-colors ${candidate.id === device ? "bg-ink text-page" : "bg-card text-ink ring-1 ring-black/5 hover:bg-mist dark:ring-white/10"}`}
              >
                {name(candidate)}
              </button>
            ))}
          </div>
        )}

        <div className="mt-8">
          {current ? (
            <LiveScreen key={current.id} getTicket={getTicket} label={name(current)} deviceClass={current.device_class} />
          ) : (
            <p className="mx-auto max-w-md rounded-3xl bg-card px-6 py-10 text-center text-[17px] text-muted">
              {data.online ? (
                <T>No device is connected to this Mac right now.</T>
              ) : (
                <T>
                  <Var>{data.mac}</Var> is offline right now.
                </T>
              )}
            </p>
          )}
        </div>
      </div>
    </Page>
  );
}
