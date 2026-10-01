/**
 * An error the dashboard shows to the user. The message is English; the dashboard translates it by
 * `reason` (src/server/dashboard.ts), with `value` for the name or number in the sentence.
 */
export class UserError extends Error {
  constructor(
    readonly reason: "billing-unreachable" | "billing-record" | "paid-plan" | "token-limit",
    message: string,
    readonly value?: string | number,
  ) {
    super(message);
  }
}
