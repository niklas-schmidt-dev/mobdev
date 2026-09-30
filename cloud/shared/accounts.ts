import { AutumnError, currentSubscription, type Autumn, type Customer } from "./autumn";
import { deleteAccessToken, listAccessTokens } from "./db";
import { sha256Hex } from "./keys";
import { FEATURES, PLANS, planById, type Plan } from "./plans";

// Deleting an account, and carrying the usage it had this month over to the user's next account
// (migrations/0004_deleted_usage.sql). The dashboard runs these; they live here so the tests can
// run them against D1 and the fake Autumn.

/** The paid plan that would keep charging an account that no longer exists, or null. */
function runningPaidPlan(customer: Customer): Plan | null {
  const subscription = currentSubscription(customer, PLANS.map((plan) => plan.id));
  const plan = planById(subscription?.plan_id);
  const endsAt = subscription?.canceled_at ? subscription.current_period_end : null;
  return plan && plan.priceUsd > 0 && endsAt === null ? plan : null;
}

/**
 * Keeps what the account used this period, under a hash of the user ID, until its allowance
 * renews. It counts only once Autumn deleted the customer (removeAccount). Repeating it, as a
 * retried deletion does, keeps the larger numbers.
 */
export async function keepUsage(db: D1Database, userId: string, customer: Customer, now = Date.now()): Promise<void> {
  const requests = customer.balances[FEATURES.requests];
  const seconds = customer.balances[FEATURES.activeSeconds];
  const used = { requests: Math.ceil(requests?.usage ?? 0), seconds: Math.ceil(seconds?.usage ?? 0) };
  const resets = [requests?.next_reset_at, seconds?.next_reset_at].filter((at): at is number => typeof at === "number");
  const resetsAt = resets.length ? Math.max(...resets) : null;
  if ((used.requests <= 0 && used.seconds <= 0) || resetsAt === null || resetsAt <= now) return;
  await db
    .prepare(
      `INSERT INTO deleted_usage (user_hash, requests, active_seconds, resets_at) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(user_hash) DO UPDATE SET
         requests = MAX(requests, excluded.requests), active_seconds = MAX(active_seconds, excluded.active_seconds),
         resets_at = MAX(resets_at, excluded.resets_at), deleted_at = NULL`,
    )
    .bind(await sha256Hex(userId), used.requests, used.seconds, resetsAt)
    .run();
}

/**
 * Adds the usage kept from the user's deleted account to their current one, once. Throws when
 * Autumn cannot be reached; the usage then stays for the next call.
 */
export async function carryOverUsage(
  db: D1Database,
  autumn: Autumn,
  user: { id: string; email: string },
  now = Date.now(),
): Promise<void> {
  const hash = await sha256Hex(user.id);
  const [, found] = await db.batch<{ requests: number; active_seconds: number; deleted_at: number }>([
    db.prepare("DELETE FROM deleted_usage WHERE resets_at <= ?1").bind(now), // Those allowances renewed.
    db
      .prepare(
        "SELECT requests, active_seconds, deleted_at FROM deleted_usage WHERE user_hash = ?1 AND deleted_at IS NOT NULL",
      )
      .bind(hash),
  ]);
  const row = found?.results[0];
  if (!row) return;
  await autumn.customer(user.id, user.email); // Tracking needs the customer.
  // The same keys on every attempt, so a retry after a lost answer counts nothing twice.
  const key = `carryover-${hash.slice(0, 32)}-${row.deleted_at}`;
  if (row.requests > 0) await autumn.track(user.id, FEATURES.requests, row.requests, `${key}-requests`);
  if (row.active_seconds > 0) await autumn.track(user.id, FEATURES.activeSeconds, row.active_seconds, `${key}-seconds`);
  await db.prepare("DELETE FROM deleted_usage WHERE user_hash = ?1 AND deleted_at = ?2").bind(hash, row.deleted_at).run();
}

/**
 * Deletes an account: its Autumn customer, its tokens (disconnecting its Macs) and its D1 rows.
 * Nothing is deleted before Autumn confirms, so a failure never looks like success, and every
 * step can run again when the user retries.
 */
export async function removeAccount(
  db: D1Database,
  autumn: Autumn | null,
  user: { id: string; email: string },
  disconnect: (tokenId: string, spaceIds: string[]) => Promise<void>,
): Promise<void> {
  if (autumn) {
    let customer: Customer;
    try {
      customer = await autumn.customer(user.id, user.email);
    } catch (error) {
      console.warn("could not read the Autumn customer", error);
      throw new Error("Billing could not be reached, so nothing was deleted. Try again in a moment.");
    }
    const running = runningPaidPlan(customer);
    if (running) throw new Error(`Cancel ${running.name} under “Manage billing” first, then delete your account.`);
    await keepUsage(db, user.id, customer);
    try {
      await autumn.deleteCustomer(user.id); // Stripe keeps its invoices; tax law requires them.
    } catch (error) {
      // Not found: an earlier attempt deleted it.
      if (!(error instanceof AutumnError && error.status === 404)) {
        console.warn("could not delete the Autumn customer", error);
        throw new Error("Your billing record could not be deleted, so nothing was deleted. Try again in a moment.");
      }
    }
    await db
      .prepare("UPDATE deleted_usage SET deleted_at = ?2 WHERE user_hash = ?1")
      .bind(await sha256Hex(user.id), Date.now())
      .run();
  }
  for (const token of await listAccessTokens(db, user.id)) {
    await disconnect(token.id, await deleteAccessToken(db, user.id, token.id));
  }
  await db.batch([
    db.prepare("DELETE FROM hosts WHERE account_id = ?1").bind(user.id),
    db.prepare("DELETE FROM accounts WHERE id = ?1").bind(user.id),
  ]);
}
