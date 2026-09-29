import { createFileRoute } from "@tanstack/react-router";
import { getSignInUrl } from "@workos/authkit-tanstack-react-start";
import { authConfigured } from "../../../server/auth-config";

/** Starts the AuthKit sign-in. Also the "Initiate login URI" in WorkOS. */
export const Route = createFileRoute("/api/auth/sign-in")({
  server: {
    handlers: {
      GET: async ({ request }: { request: Request }) => {
        if (!authConfigured()) return new Response("Sign-in is not set up yet.", { status: 503 });
        const requested = new URL(request.url).searchParams.get("returnPathname");
        // Only return to paths on this site.
        const returnPathname = requested?.startsWith("/") && !requested.startsWith("//") ? requested : "/dashboard";
        const url = await getSignInUrl({ data: { returnPathname } });
        return new Response(null, { status: 307, headers: { Location: url } });
      },
    },
  },
});
