# Elpis — Contracts, SDKs & Agent Integration

**The control layer for money an AI agent spends.**

An agent proposes a payment; Elpis decides whether it may proceed — using deterministic spending rules, pre-committed deliverable verification, and human approval for irreversible actions. Every decision is recorded and replayable.

- **Website:** [https://elpis.devilabs.dev](https://elpis.devilabs.dev)
- **Get a 1-click API key:** [https://elpis.devilabs.dev/get-key](https://elpis.devilabs.dev/get-key)
- **Interactive Playground (no account):** [https://elpis.devilabs.dev/playground](https://elpis.devilabs.dev/playground)
- **Documentation:** [https://elpis.devilabs.dev/docs](https://elpis.devilabs.dev/docs)
- **OpenAPI 3.0 Spec:** [`openapi.json`](./openapi.json) (`https://elpis.devilabs.dev/openapi.json`)
- **AI Agent Setup Guide:** [`AGENTS.md`](./AGENTS.md) (`https://elpis.devilabs.dev/AGENTS.md`)

---

## Quickstart: Get a Working Key in One Call

No signup form, no wallet required to start, and no card needed:

```bash
curl -X POST https://elpis.devilabs.dev/api/v1/keys \
  -H 'content-type: application/json' \
  -d '{"name":"my-agent"}'
```

Returns a scoped `elp_...` API key (`read` + `propose`) with starter credits and a referral code (`?ref=<code>`). An agent key can propose and dry-run payments, but can never approve its own irreversible spend.

### 1. Dry-run a payment policy decision (`POST /api/v1/actions/evaluate`)

```bash
curl -X POST https://elpis.devilabs.dev/api/v1/actions/evaluate \
  -H "Authorization: Bearer $ELPIS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "amount": "45.00",
    "address": "0x1111111111111111111111111111111111111111",
    "label": "Compute provider invoice"
  }'
```

### 2. Commit & verify a deliverable before releasing payment (`POST /api/v1/jobs`)

```bash
curl -X POST https://elpis.devilabs.dev/api/v1/jobs \
  -H "Authorization: Bearer $ELPIS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Audit report delivery",
    "condition": [
      {
        "kind": "deliverable_hash",
        "hash": "0xbfb0c59be7146dc7bcac41c0edfdf49ef65caee08498e9076ee42b99ac3b26bf"
      }
    ]
  }'
```

### 3. Connect as an MCP Server (`POST /api/mcp`)

Point any MCP-compatible agent at `https://elpis.devilabs.dev/api/mcp` with `Authorization: Bearer <ELPIS_API_KEY>` to expose `get_state`, `evaluate_payment`, `propose_payment`, `draft_condition`, `settle_job`, and `replay_decision`.

---

## Repository Contents (MIT Licensed)

This repository contains the open-source on-chain contracts, client SDKs, and machine-readable schemas for Elpis:

| Directory / File | Description |
| --- | --- |
| [`contracts/LazarusVault.sol`](./contracts/LazarusVault.sol) | Self-custodied on-chain USDC escrow vault with cancellable Lazarus windows, daily spend caps, recipient allowlists, and M-of-N guardian recovery on Arc. |
| [`contracts/AgenticCommerce.sol`](./contracts/AgenticCommerce.sol) | ERC-8183 agentic commerce job escrow and attestation settlement contract. |
| [`contracts/Evaluator.sol`](./contracts/Evaluator.sol) | On-chain attestation verifier for committed job conditions. |
| [`sdk/typescript/elpis.ts`](./sdk/typescript/elpis.ts) | Zero-dependency TypeScript client + webhook signature verifier. |
| [`sdk/python/elpis.py`](./sdk/python/elpis.py) | Zero-dependency Python client + example autonomous agent loop. |
| [`examples/`](./examples/) | Runnable end-to-end payment evaluation and settle-on-proof scripts. |
| [`openapi.json`](./openapi.json) | Full OpenAPI 3.0 specification for REST and RapidAPI integration. |
| [`AGENTS.md`](./AGENTS.md) | Autonomous setup instructions for LLM agents. |

---

## Pricing & Non-Custodial Architecture

- **100,000 API calls / month free** on every workspace.
- **$0.0002 per standard API call** after the free monthly allowance (`$0.002` per settled payment decision).
- **Refused, blocked, or held calls are always $0.00** — safety rules never cost money when they trigger.
- **Zero custody of your funds:** On-chain vaults (`LazarusVault.sol`) are deployed and controlled by your own wallet. Elpis never holds private keys that can move your funds and never takes a percentage fee on your payments.

---

## Security Notice

The smart contracts in `contracts/` are provided under the MIT License ("as is") and have not yet completed an independent third-party security audit. Do not deposit funds you cannot afford to lose prior to independent audit verification.

## License

MIT License — see [`LICENSE`](./LICENSE). Built by [Devilabs](https://devilabs.dev).
