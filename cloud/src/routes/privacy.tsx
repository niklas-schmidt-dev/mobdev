import { createFileRoute } from "@tanstack/react-router";
import { Page } from "../components/site";

export const Route = createFileRoute("/privacy")({
  head: () => ({ meta: [{ title: "Privacy — Mobdev" }] }),
  component: Privacy,
});

function Privacy() {
  return (
    <Page>
      <article className="mx-auto max-w-2xl px-5 py-20 text-[17px] leading-[1.6] text-ink/85">
        <h1 className="headline text-[48px] text-ink">Privacy</h1>
        <p className="mt-4 text-[21px] leading-[1.45] text-muted">What the hosted parts of Mobdev keep, in plain words.</p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">The Mac app</h2>
        <p className="mt-3">
          The app has no account and no telemetry. Screens, text recognition and settings stay on your Mac. What your
          agent sends to its model is up to the agent.
        </p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">Your account</h2>
        <p className="mt-3">
          Sign-in is handled by WorkOS. We store your WorkOS user ID and email address, the names and SHA-256 hashes of
          your access tokens, and when each was last used.
        </p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">The relay</h2>
        <p className="mt-3">
          The relay records which Macs are connected: a name you choose, when it connected and disconnected, and an ID
          derived from your Mac’s key. Agent requests and responses, including screenshots, only pass through memory
          and are never written to disk or logs. Cloudflare, which runs the relay, may keep standard request metadata
          such as IP addresses for security.
        </p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">Deleting your data</h2>
        <p className="mt-3">
          Revoking an access token deletes it. “Delete account” in the dashboard removes your account, tokens and Mac
          records at once and disconnects your Macs.
        </p>
      </article>
    </Page>
  );
}
