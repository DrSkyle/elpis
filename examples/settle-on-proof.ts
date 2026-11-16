import { commit, settle, type AcceptanceCheck } from "@/core/settle";

/**
 * settle-on-proof — the demo that makes it undeniable.
 *
 * An OUTSIDE agent does a job. No human is in the payment path. No model decides
 * whether it was done. The money moves on EVIDENCE alone:
 *
 *   1. The payer commits what "done" means — BEFORE the work starts.
 *   2. The agent delivers.
 *   3. A deliverable that satisfies the committed condition releases the payment,
 *      instantly. A contradiction refunds it. Silence past the deadline refunds.
 *
 * No clock releases money. No cancel button. No LLM in the release path. The
 * condition decides — and anyone can re-run the same inputs and get the same
 * answer, because the decision is a pure function and the attestation is its hash.
 *
 *   npm run demo
 */

async function main(): Promise<void> {
  const line = "─".repeat(72);
  console.log(`\n${line}\n  settle-on-proof — was the work actually done?\n${line}\n`);

  // The one thing no other agent-payment rail has: a committed condition.
  const condition: AcceptanceCheck[] = [
    { kind: "deliverable_hash", hash: "0xDEED", label: "the agreed report" },
    { kind: "witness_attestation", witness: "0xAuditor", subject: "job-42", label: "an independent auditor vouches" },
  ];
  const commitment = await commit(condition);
  console.log(`1.  Payer commits what "done" means, before the work begins`);
  console.log(`    commitment ${commitment.slice(0, 20)}…  (fixed now — it cannot be rewritten after)\n`);

  // ── Job 1: the agent delivers exactly what was agreed. ────────────────────
  console.log("2.  Outside agent delivers the agreed report + the auditor vouches…");
  const good = await settle({
    condition,
    proof: { deliverableHash: "0xDEED", witnessAttestations: { "0xAuditor": "job-42 done" } },
  });
  report(good);

  // ── Job 2: the agent delivers garbage. ───────────────────────────────────
  console.log("3.  Second job — the agent delivers garbage…");
  const bad = await settle({ condition, proof: { deliverableHash: "0xGARBAGE" } });
  report(bad);

  // ── Job 3: the agent goes silent past the deadline. ──────────────────────
  console.log("4.  Third job — the agent goes silent, the deadline passes…");
  const silent = await settle({
    condition,
    proof: {},
    deadline: new Date(Date.now() - 1000), // already past
  });
  report(silent);

  console.log(`${line}`);
  console.log("  No model. No clock released the money. No cancel button.");
  console.log("  The condition decided — evidence releases, a contradiction refunds,");
  console.log("  and time can only ever return money, never pay it out.");
  console.log(`${line}\n`);
}

function report(out: Awaited<ReturnType<typeof settle>>): void {
  const arrow = out.decision === "release" ? "→ RELEASE" : out.decision === "refund" ? "→ REFUND " : "→ HOLD   ";
  const tone = out.decision === "release" ? "✓" : out.decision === "refund" ? "↩" : "…";
  console.log(`    ${arrow}  ${tone} ${out.reasons[0]}`);
  if (out.reasons.length > 1) console.log(`              ${out.reasons.slice(1).join(" · ")}`);
  console.log(`              attestation ${out.attestation.slice(0, 20)}…  (reproducible)\n`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
