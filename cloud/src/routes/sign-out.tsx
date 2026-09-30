import { createFileRoute } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { signOut } from "@workos/authkit-tanstack-react-start";
import { useState } from "react";
import { Page, buttonPrimary } from "../components/site";
import { pageMeta } from "../lib/meta";

// Opening this page signs no one out, so a link from another site cannot either. The button posts
// to AuthKit's signOut server function, which the CSRF check in start.ts covers.
export const Route = createFileRoute("/sign-out")({
  head: () => ({ meta: pageMeta("Sign out — Mobdev", "/sign-out") }),
  component: SignOut,
});

function SignOut() {
  const signOutNow = useServerFn(signOut);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <Page tone="mist">
      <div className="mx-auto max-w-xl px-5 py-32 text-center">
        <h1 className="headline text-[40px]">Sign out of Mobdev?</h1>
        <p className="mt-4 text-[19px] leading-[1.45] text-muted">
          Your Macs stay connected. Sign in again any time to manage them.
        </p>
        {error && (
          <p role="alert" className="mt-8 rounded-2xl bg-alert px-5 py-4 text-[15px] text-alert-ink">
            {error}
          </p>
        )}
        <button
          type="button"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            setError(null);
            signOutNow({ data: { returnTo: "/" } }).catch((reason: unknown) => {
              setError(reason instanceof Error ? reason.message : String(reason));
              setBusy(false);
            });
          }}
          className={`${buttonPrimary} mt-8`}
        >
          Sign out
        </button>
      </div>
    </Page>
  );
}
