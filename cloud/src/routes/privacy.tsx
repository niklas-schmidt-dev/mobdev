import { createFileRoute } from "@tanstack/react-router";
import { Page } from "../components/site";
import { pageMeta } from "../lib/meta";

export const Route = createFileRoute("/privacy")({
  head: () => ({ meta: pageMeta("Privacy — Mobdev", "/privacy") }),
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
          derived from your Mac’s key. For each Mac it also keeps the iPhones and iPads it last reported: their name,
          model, iOS version, a device ID and whether they are ready. Agent requests and responses, including
          screenshots, only pass through memory and are never written to disk or logs. Cloudflare, which runs the
          relay, may keep standard request metadata such as IP addresses for security.
        </p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">Plans and payments</h2>
        <p className="mt-3">
          Autumn keeps track of your plan and usage, and Stripe handles payments. Autumn receives your user ID and email
          address and, per Mac connection, how many requests the relay forwarded and how long the Mac was busy with
          them, never their content. Card details go straight to Stripe; we never see them.
        </p>

        <h2 className="mt-10 text-[24px] font-semibold tracking-tight text-ink">Deleting your data</h2>
        <p className="mt-3">
          Revoking an access token deletes it. “Delete account” in the dashboard removes your account, tokens and Mac
          records at once, disconnects your Macs and deletes your record at Autumn. A paid plan has to be cancelled
          first. Stripe keeps invoices as long as tax law requires.
        </p>
        <p className="mt-3">
          If you used the hosted relay that month, we keep one thing until your monthly allowance renews: a SHA-256 hash
          of your WorkOS user ID with how many requests and active seconds you used. If you sign up again before then,
          that usage counts toward your new account, so deleting and re-creating an account does not reset the free
          allowance. After the renewal we delete it.
        </p>
      </article>
    </Page>
  );
}
