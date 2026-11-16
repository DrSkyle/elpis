/**
 * Elpis SDK — a small typed client for the public API.
 *
 * It is deliberately thin: no clever retries, no hidden state. What it does add
 * is the things an integrator should not have to get right by hand — it makes
 * idempotency keys easy, it never claims a payment is settled when it is only
 * staged, and it ships a webhook signature verifier so a receiver can refuse a
 * forged delivery.
 *
 *   const elpis = new ElpisClient({ token: process.env.ELPIS_API_KEY! });
 *   const action = await elpis.proposePayment({ accountId, amount: "1250.00", address });
 *   if (action.recovery?.cancellable) { ...you still have time to change your mind... }
 */

export type ActionState =
  | "DETECTED"
  | "ANALYZING"
  | "PROPOSED"
  | "POLICY_CHECK"
  | "SIMULATED"
  | "APPROVAL_REQUIRED"
  | "AUTHORIZED"
  | "STAGED"
  | "EXECUTING"
  | "EXECUTED"
  | "VERIFYING"
  | "VERIFIED"
  | "FINALIZED"
  | "BLOCKED"
  | "ESCALATED"
  | "FAILED"
  | "FROZEN"
  | "ROLLBACK_PENDING"
  | "ROLLED_BACK"
  | "COMPENSATION_PENDING"
  | "COMPENSATED"
  | "CANCELLED";

export interface PublicAction {
  id: string;
  state: ActionState;
  type: string;
  amount: string;
  amountBaseUnits: string;
  destination: string;
  destinationLabel: string;
  recoverabilityClass: string | null;
  recovery: { mechanism: string; summary: string; cancellable: boolean } | null;
  requiresApproval: boolean;
  approvalReasons: string[];
  submittedAt: string;
  window: { state: string; finalizeAt: string } | null;
  transaction: { hash: string; explorerUrl: string | null; status: string } | null;
  blockedBy: { id: string; layer: string; label: string; detail: string }[];
}

export interface TreasuryState {
  organization: string;
  serverTime: string;
  executionLayer: { mode: string; warning: string | null };
  totals: Record<string, string>;
  accounts: {
    id: string;
    name: string;
    kind: string;
    balance: string;
    minReserve: string;
    autonomousLimit: string;
    approvalLimit: string;
  }[];
  settlingNow: {
    id: string;
    amount: string;
    destinationLabel: string;
    conditionHash: string | null;
    attestation: string | null;
    refundIfUnsatisfiedBy: string | null;
  }[];
}

export interface ProposeInput {
  accountId: string;
  amount: string;
  address: string;
  label?: string;
  memo?: string;
  reference?: string;
  /** Any stable id for this intent. A retry with the same key cannot create a second payment. */
  idempotencyKey?: string;
}

export interface EvidenceInput {
  /** a contradiction the treasury observed — the payment is refused and refunded */
  problem?: string;
  /** evidence that satisfies the committed condition — the payment is released */
  proof?: {
    deliverableHash?: string;
    numericValue?: string;
    signers?: string[];
    documentHash?: string;
    oracleValues?: Record<string, string>;
    witnessAttestations?: Record<string, string>;
  };
}

export interface EvaluateInput {
  accountId: string;
  amount: string;
  address: string;
  label?: string;
  counterpartyId?: string | null;
  obligationId?: string | null;
  documentRef?: string;
  reference?: string;
}

/** What a dry-run says would happen — decided by the real controls, nothing persisted. */
export interface PaymentEvaluation {
  decision: "BLOCKED" | "APPROVAL_REQUIRED" | "FROZEN" | "AUTHORIZED";
  recoverabilityClass: string | null;
  reasonSummary: string;
  wouldRaiseLiquidity: { amount: string; reason: string } | null;
  blockers: { id: string; layer: string; label: string; detail: string }[];
  rules: { id: string; layer: string; label: string; status: string; detail: string; blocking: boolean }[];
  supervisor: { verdict: string; findings: { code: string; severity: string; message: string }[]; warnings: string[] } | null;
  approval: { required: boolean; reasons: string[]; requiredBy: string[]; suggestedThreshold: string | null };
}

export class ElpisError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ElpisError";
  }
}

export class ElpisClient {
  private readonly baseUrl: string;
  private readonly token: string;

  constructor(opts: { token: string; baseUrl?: string }) {
    this.token = opts.token;
    this.baseUrl = (opts.baseUrl ?? "https://elpis.devilabs.dev").replace(/\/$/, "");
  }

  private async call<T>(path: string, init: RequestInit & { idempotencyKey?: string } = {}): Promise<T> {
    const { idempotencyKey, ...rest } = init;
    const response = await fetch(`${this.baseUrl}${path}`, {
      ...rest,
      headers: {
        authorization: `Bearer ${this.token}`,
        ...(rest.body ? { "content-type": "application/json" } : {}),
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
        ...(rest.headers ?? {}),
      },
    });
    const json = (await response.json().catch(() => ({}))) as { data?: T; error?: { code: string; message: string } };
    if (!response.ok) {
      throw new ElpisError(
        json.error?.message ?? `Request failed with ${response.status}`,
        json.error?.code ?? "http_error",
        response.status,
      );
    }
    return json.data as T;
  }

  /** Balances, limits, and what is cancellable right now. */
  getState(): Promise<TreasuryState> {
    return this.call<TreasuryState>("/api/v1/state");
  }

  listActions(limit = 25): Promise<PublicAction[]> {
    return this.call<PublicAction[]>(`/api/v1/actions?limit=${limit}`);
  }

  getAction(id: string): Promise<PublicAction> {
    return this.call<PublicAction>(`/api/v1/actions/${encodeURIComponent(id)}`);
  }

  /**
   * Propose a payment. This never sends money by itself: the result tells you
   * whether it was staged (and what condition it settles against), held for a
   * human, or refused.
   */
  proposePayment(input: ProposeInput): Promise<PublicAction> {
    return this.call<PublicAction>("/api/v1/actions", {
      method: "POST",
      body: JSON.stringify(input),
      idempotencyKey: input.idempotencyKey,
    });
  }

  /**
   * Dry-run a payment before proposing it: run every deterministic control and
   * return what WOULD happen — blocked, held for a human, frozen, or proceed on
   * its own, and why — without persisting anything or moving money.
   */
  evaluatePayment(input: EvaluateInput): Promise<PaymentEvaluation> {
    return this.call<PaymentEvaluation>("/api/v1/actions/evaluate", {
      method: "POST",
      body: JSON.stringify(input),
    });
  }

  /**
   * Settle a staged payment against its committed condition.
   *
   * Pass a `proof` that satisfies the condition to release the payment to the
   * recipient; pass a `problem` (a genuine contradiction) to refund it to the
   * treasury. This is the only way a staged payment resolves — it is settled by
   * its condition, not recalled.
   */
  submitEvidence(id: string, evidence: EvidenceInput): Promise<PublicAction> {
    return this.call<PublicAction>(`/api/v1/actions/${encodeURIComponent(id)}/evidence`, {
      method: "POST",
      body: JSON.stringify(evidence),
    });
  }

  /**
   * Cancel a payment that has not staged yet — one still waiting for a human or
   * a wallet signature. A staged payment cannot be recalled; submit evidence
   * for it instead.
   */
  cancelPayment(id: string, reason?: string): Promise<PublicAction> {
    return this.call<PublicAction>(`/api/v1/actions/${encodeURIComponent(id)}/cancel`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    });
  }

  /** Release a payment that is waiting for a human. Needs the `approve` scope. */
  approvePayment(id: string, note?: string): Promise<PublicAction> {
    return this.call<PublicAction>(`/api/v1/actions/${encodeURIComponent(id)}/approve`, {
      method: "POST",
      body: JSON.stringify({ note }),
    });
  }
}

/**
 * Verify an Elpis webhook signature.
 *
 * Reject anything that fails. The timestamp check is what stops a captured
 * delivery from being replayed later.
 */
export async function verifyWebhookSignature(input: {
  secret: string;
  header: string;
  body: string;
  toleranceSeconds?: number;
}): Promise<boolean> {
  const parts = Object.fromEntries(
    input.header.split(",").map((piece) => piece.split("=").map((s) => s.trim()) as [string, string]),
  );
  const timestamp = Number(parts.t);
  const signature = parts.v1;
  if (!Number.isFinite(timestamp) || !signature) return false;
  if (Math.abs(Date.now() / 1000 - timestamp) > (input.toleranceSeconds ?? 300)) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(input.secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${input.body}`));
  const expected = Array.from(new Uint8Array(mac), (b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i += 1) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}
