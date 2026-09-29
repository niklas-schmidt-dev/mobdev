/**
 * Whether WorkOS AuthKit has everything it needs. Without it the public pages still work;
 * only sign-in and the dashboard are unavailable. AuthKit reads these from process.env.
 */
export function authConfigured(): boolean {
  const env = process.env;
  return Boolean(
    env.WORKOS_CLIENT_ID &&
      env.WORKOS_API_KEY &&
      env.WORKOS_REDIRECT_URI &&
      (env.WORKOS_COOKIE_PASSWORD?.length ?? 0) >= 32,
  );
}
