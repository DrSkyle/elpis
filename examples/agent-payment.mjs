#!/usr/bin/env node
/**
 * Elpis — one real agent payment, settled on evidence.
 *
 * With no API key it mints a **funded sandbox** for you (no signup), then makes a
 * real payment against it. Nothing is simulated: the proposal goes through the
 * real pipeline and a staged payment is held in escrow against a committed
 * condition — release it on a proof, or refund it on a problem, on chain. Sandbox
 * assets are test USDC with no monetary value; the transactions, receipts and
 * refusals are all real.
 *
 *   node examples/agent-payment.mjs                       # auto-creates a sandbox
 *   node examples/agent-payment.mjs --to 0xPayee --amount 5 --refund
 *   ELPIS_API_KEY=elp_... node examples/agent-payment.mjs  # use your own treasury
 */

const BASE = (process.env.ELPIS_URL ?? "https://elpis.devilabs.dev").replace(/\/+$/, "");
let KEY = process.env.ELPIS_API_KEY;

const args = parseArgs(process.argv.slice(2));
const amount = String(args.amount ?? "5");
// A fresh sandbox lets anyone pay any address, so a placeholder is fine here.
const to = args.to ?? "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

async function api(method, path, body, extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (KEY) headers.authorization = `Bearer ${KEY}`;
  if (body) headers["content-type"] = "application/json";
  const res = await fetch(`${BASE}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  return { status: res.status, ok: res.ok, json };
}

function say(label, value) {
  console.log(`  ${label.padEnd(22)} ${value}`);
}

async function bootstrap() {
  console.log("No API key — creating a funded sandbox (no signup)…");
  const res = await api("POST", "/api/v1/sandbox", {});
  if (!res.ok) fail(`Could not create a sandbox (${res.status}): ${err(res.json)}`);
  KEY = res.json.data.apiKey;
  say("Sandbox treasury", res.json.data.treasuryAddress);
  say("Funded with", `${res.json.data.funded} test USDC`);
  say("Execution", res.json.data.execution);
  console.log("  (this key can propose and settle — never approve its own proposal)\n");
}

async function main() {
  console.log(`\nElpis — real execution, test assets\n${"=".repeat(44)}`);
  if (!KEY) await bootstrap();

  const state = await api("GET", "/api/v1/state");
  if (!state.ok) fail(`Could not read state (${state.status}): ${err(state.json)}`);
  const s = state.json.data;
  const mode = s.executionLayer?.mode ?? "unknown";
  console.log(`\nTreasury: ${s.organization}`);
  say("Execution layer", mode === "arc" ? "Arc testnet — real transactions" : mode);
  if (s.executionLayer?.warning) say("Warning", s.executionLayer.warning);
  say("Total assets", `${s.totals.totalAssets} USDC (testnet)`);
  say("Safe to deploy", `${s.totals.safeToDeploy} USDC`);
  say("Settling now", `${s.settlingNow.length}`);

  const account = s.accounts.find((a) => a.kind === "OPERATING") ?? s.accounts[0];
  if (!account) fail("This treasury has no accounts to pay from.");

  const reference = `quickstart:${Date.now()}`;
  console.log(`\nProposing ${amount} USDC → ${to}`);
  const proposed = await api(
    "POST",
    "/api/v1/actions",
    { accountId: account.id, amount, address: to, label: "quickstart payment", reference },
    { "idempotency-key": reference },
  );
  if (!proposed.ok) fail(`Proposal failed (${proposed.status}): ${err(proposed.json)}`);

  const action = proposed.json.data;
  say("Decision", action.state);
  say("Recoverability", action.recoverabilityClass ?? "—");
  if (action.recovery) say("Mechanism", action.recovery.mechanism);
  if (action.requiresApproval) say("Needs approval", action.approvalReasons.join("; ") || "yes");

  console.log("");
  if (action.state === "STAGED") {
    say("Settles against", action.conditionHash ? `condition ${action.conditionHash.slice(0, 12)}…` : "its deadline");
    if (action.transaction?.explorerUrl) say("Explorer", action.transaction.explorerUrl);
    console.log("  The money is held in escrow on chain. Evidence decides: a proof releases it, a problem refunds it.");
    if (args.refund) {
      console.log("\nReporting a problem, so the condition refunds it…");
      const refunded = await api("POST", `/api/v1/actions/${action.id}/evidence`, { problem: "demo: no longer needed" });
      if (!refunded.ok) fail(`Refund failed (${refunded.status}): ${err(refunded.json)}`);
      say("Outcome", refunded.json.data.state);
      if (refunded.json.data.transaction?.explorerUrl) {
        say("Refund tx", refunded.json.data.transaction.explorerUrl);
      }
      console.log("  The escrow was refunded to the treasury — a real on-chain refund.\n");
    } else {
      console.log("  Re-run with --refund to report a problem and watch the money come back.\n");
    }
  } else if (action.state === "APPROVAL_REQUIRED") {
    console.log(
      "  A new recipient needs a person's approval. The product working as designed:\n" +
        "  a key that can propose cannot release its own payment.\n",
    );
  } else if (action.state === "BLOCKED") {
    console.log("  A deterministic rule refused it:\n");
    for (const r of action.blockedBy ?? []) console.log(`    - ${r.label}: ${r.detail}`);
    console.log("");
  } else {
    console.log(`  Outcome: ${action.state}\n`);
  }
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--refund") out.refund = true;
    else if (a.startsWith("--")) out[a.slice(2)] = argv[i + 1] ?? true;
  }
  return out;
}

function err(json) {
  return json?.error?.message ?? json?.error?.code ?? JSON.stringify(json);
}

function fail(message) {
  console.error(`\n✗ ${message}\n`);
  process.exit(1);
}

main().catch((e) => fail(e?.stack ?? String(e)));
