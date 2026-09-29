import { createCsrfMiddleware, createStart } from "@tanstack/react-start";
import { authkitMiddleware } from "@workos/authkit-tanstack-react-start";
import { authConfigured } from "./server/auth-config";

// Reject cross-site calls to server functions before any session work runs.
const csrfMiddleware = createCsrfMiddleware({
  filter: (ctx) => ctx.handlerType === "serverFn",
});

// AuthKit rejects every request when its settings are missing, so it only runs once they are set.
export const startInstance = createStart(() => ({
  requestMiddleware: authConfigured() ? [csrfMiddleware, authkitMiddleware()] : [csrfMiddleware],
}));
