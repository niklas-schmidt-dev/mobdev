import type { Balance, Customer } from "../shared/autumn";
import { FEATURES, PRO_PLAN, type Plan } from "../shared/plans";

interface FakeCustomer {
  id: string;
  email: string | null;
  plan: Plan;
  used: { requests: number; seconds: number };
}

/**
 * An in-memory Autumn with the parts of its API the relay and dashboard use. Tests install it in
 * place of fetch for api.useautumn.com (see setup-autumn.ts).
 */
export class FakeAutumn {
  customers = new Map<string, FakeCustomer>();
  tracked: { customer: string; feature: string; value: number; key: string }[] = [];
  idempotencyKeys = new Set<string>();
  /** Answers 503 to everything. */
  down = false;
  /** Records the next track call, then answers 503 as if the response got lost. */
  loseNextTrackResponse = false;
  /** Answers customers.delete with this status instead of deleting. */
  deleteAnswer: number | null = null;
  /** Runs before customers.get_or_create answers, e.g. to revoke a token while a Mac connects. */
  beforeCustomer: (() => Promise<void>) | null = null;
  /** New customers get this plan. Pro, so tests about other things are not limited. */
  defaultPlan: Plan = PRO_PLAN;
  /** Customers who have no plan, as when the plans were never pushed to Autumn. */
  withoutPlan = new Set<string>();
  resetsAt = Date.now() + 30 * 24 * 3600 * 1000;

  customer(id: string): FakeCustomer {
    let customer = this.customers.get(id);
    if (!customer) {
      customer = { id, email: null, plan: this.defaultPlan, used: { requests: 0, seconds: 0 } };
      this.customers.set(id, customer);
    }
    return customer;
  }

  setPlan(id: string, plan: Plan): void {
    this.customer(id).plan = plan;
  }

  trackedFor(id: string, feature: string): number {
    return this.tracked.filter((t) => t.customer === id && t.feature === feature).reduce((sum, t) => sum + t.value, 0);
  }

  private balances(customer: FakeCustomer): Record<string, Balance> {
    const metered = (feature: string, granted: number, usage: number): Balance => ({
      feature_id: feature,
      granted,
      usage,
      remaining: Math.max(0, granted - usage),
      unlimited: false,
      next_reset_at: this.resetsAt,
    });
    return {
      [FEATURES.requests]: metered(FEATURES.requests, customer.plan.requests, customer.used.requests),
      [FEATURES.activeSeconds]: metered(FEATURES.activeSeconds, customer.plan.activeHours * 3600, customer.used.seconds),
      [FEATURES.macs]: { ...metered(FEATURES.macs, customer.plan.macs, 0), next_reset_at: null },
    };
  }

  private customerBody(customer: FakeCustomer): Customer {
    if (this.withoutPlan.has(customer.id)) return { id: customer.id, subscriptions: [], balances: {} };
    return {
      id: customer.id,
      subscriptions: [
        {
          plan_id: customer.plan.id,
          status: "active",
          add_on: false,
          past_due: false,
          canceled_at: null,
          current_period_end: customer.plan.priceUsd > 0 ? this.resetsAt : null,
        },
      ],
      balances: this.balances(customer),
    };
  }

  async handle(request: Request): Promise<Response> {
    if (!request.headers.get("Authorization")?.startsWith("Bearer ") || !request.headers.get("x-api-version")) {
      return Response.json({ message: "unauthorized" }, { status: 401 });
    }
    if (this.down) return Response.json({ message: "unavailable" }, { status: 503 });
    const body = (await request.json()) as Record<string, unknown>;
    const route = new URL(request.url).pathname;
    const customerId = String(body.customer_id);
    switch (route) {
      case "/v1/customers.get_or_create": {
        await this.beforeCustomer?.();
        const customer = this.customer(customerId);
        if (typeof body.email === "string") customer.email = body.email;
        return Response.json(this.customerBody(customer));
      }
      case "/v1/balances.track": {
        const key = request.headers.get("Idempotency-Key") ?? "";
        if (key && this.idempotencyKeys.has(key)) return Response.json({ message: "duplicate" }, { status: 409 });
        if (key) this.idempotencyKeys.add(key);
        if (this.withoutPlan.has(customerId)) return Response.json({ message: "feature not found" }, { status: 404 });
        const customer = this.customer(customerId);
        const feature = String(body.feature_id);
        const value = Number(body.value);
        this.tracked.push({ customer: customerId, feature, value, key });
        const field = feature === FEATURES.requests ? "requests" : "seconds";
        const balance = this.balances(customer)[feature]!;
        customer.used[field] += Math.min(value, balance.remaining); // Autumn caps at the balance by default.
        if (this.loseNextTrackResponse) {
          this.loseNextTrackResponse = false;
          return Response.json({ message: "lost" }, { status: 503 });
        }
        return Response.json({ customer_id: customerId, value, balance: this.balances(customer)[feature] });
      }
      case "/v1/billing.attach":
        return Response.json({ customer_id: customerId, payment_url: `https://checkout.stripe.test/${body.plan_id}` });
      case "/v1/billing.open_customer_portal":
        return Response.json({ customer_id: customerId, url: "https://billing.stripe.test/session" });
      case "/v1/customers.delete":
        if (this.deleteAnswer) return Response.json({ message: "delete failed" }, { status: this.deleteAnswer });
        if (!this.customers.delete(customerId)) return Response.json({ message: "customer not found" }, { status: 404 });
        return Response.json({ success: true });
      default:
        return Response.json({ message: `no route ${route}` }, { status: 404 });
    }
  }
}

export const fakeAutumn = new FakeAutumn();
