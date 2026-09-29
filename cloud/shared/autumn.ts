// A small client for the Autumn billing API (https://docs.useautumn.com), shared by the relay and
// the dashboard. Autumn holds the plans and each account's balances; Stripe takes the payments.
// The customer ID is the account's WorkOS user ID.

const BASE_URL = "https://api.useautumn.com";
const API_VERSION = "2.4.0";

/** An account's allowance for one feature in the current period. */
export interface Balance {
  feature_id: string;
  granted: number;
  remaining: number;
  usage: number;
  unlimited: boolean;
  /** When the allowance renews, in milliseconds; null if it never does. */
  next_reset_at: number | null;
}

export interface Subscription {
  plan_id: string;
  status: "active" | "scheduled";
  add_on: boolean;
  past_due: boolean;
  canceled_at: number | null;
  current_period_end: number | null;
}

export interface Customer {
  id: string;
  subscriptions: Subscription[];
  balances: Record<string, Balance | undefined>;
}

export class AutumnError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export class Autumn {
  constructor(
    private readonly secretKey: string,
    private readonly timeoutMs = 5000,
  ) {}

  /** Returns the customer, creating it on the auto-enabled Free plan the first time. */
  customer(id: string, email?: string): Promise<Customer> {
    return this.call<Customer>("customers.get_or_create", { customer_id: id, ...(email ? { email } : {}) });
  }

  /**
   * Records usage and returns the feature's balance afterwards. Retrying with the same key is safe:
   * Autumn rejects the repeat with 409, and this returns null because nothing new was recorded.
   */
  async track(customerId: string, featureId: string, value: number, idempotencyKey: string): Promise<Balance | null> {
    try {
      const result = await this.call<{ balance?: Balance | null }>(
        "balances.track",
        { customer_id: customerId, feature_id: featureId, value },
        { "Idempotency-Key": idempotencyKey },
      );
      return result.balance ?? null;
    } catch (error) {
      if (error instanceof AutumnError && error.status === 409) return null;
      throw error;
    }
  }

  /** Starts a plan change. Returns a Stripe Checkout URL when the customer has to pay first. */
  async attach(customerId: string, planId: string, successUrl: string): Promise<string | null> {
    const result = await this.call<{ payment_url?: string | null }>("billing.attach", {
      customer_id: customerId,
      plan_id: planId,
      success_url: successUrl,
    });
    return result.payment_url ?? null;
  }

  /** A Stripe billing portal session for invoices, payment methods and cancelling. */
  async portal(customerId: string, returnUrl: string): Promise<string> {
    const result = await this.call<{ url: string }>("billing.open_customer_portal", {
      customer_id: customerId,
      return_url: returnUrl,
    });
    return result.url;
  }

  /** Deletes the customer in Autumn. Stripe keeps its records, including invoices. */
  async deleteCustomer(customerId: string): Promise<void> {
    await this.call("customers.delete", { customer_id: customerId, delete_in_stripe: false });
  }

  private async call<T>(route: string, body: unknown, headers: Record<string, string> = {}): Promise<T> {
    const response = await fetch(`${BASE_URL}/v1/${route}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.secretKey}`,
        "Content-Type": "application/json",
        "x-api-version": API_VERSION,
        ...headers,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!response.ok) {
      const detail = (await response.text().catch(() => "")).slice(0, 300);
      throw new AutumnError(response.status, `Autumn ${route} answered ${response.status}: ${detail}`);
    }
    return (await response.json()) as T;
  }
}

/** The customer's current base plan, if it is one of ours. */
export function currentSubscription(customer: Customer, planIds: readonly string[]): Subscription | null {
  return (
    customer.subscriptions.find(
      (subscription) => subscription.status === "active" && !subscription.add_on && planIds.includes(subscription.plan_id),
    ) ?? null
  );
}
