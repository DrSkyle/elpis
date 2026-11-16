"""A settle-on-proof loop, in Python.

Commit what "done" means, check a proof before acting on it, then settle. Run it
against a sandbox — `POST /api/v1/sandbox` returns a key with no signup.

    ELPIS_API_KEY=elp_... python3 example_agent.py
"""

import os

from elpis import ElpisClient

client = ElpisClient(token=os.environ.get("ELPIS_API_KEY", "elp_replace_me"))

# 1. Commit the acceptance condition before the work begins.
job = client.commit_job(
    condition=[{"kind": "deliverable_hash", "hash": "0xDEED", "label": "the agreed report"}],
    provider="agent-9",
    idempotency_key="report-2026-q1",
)
print(f"committed {job['id']}  commitment={job['commitmentHash']}")

# 2. The agent does the work, and checks before acting — a dry run records nothing.
preview = client.verify(job["id"], {"deliverableHash": "0xDEED"})
print(f"would settle: {preview['decision']}")

# 3. Settle on the evidence. Release on proof, refund on a contradiction, hold if
#    the proof is missing — time can only ever return the money.
settled = client.settle(job["id"], {"deliverableHash": "0xDEED"})
print(f"settled: {settled['status']}  attestation={settled['attestation']}")

# 4. Anyone can reproduce the decision from its attestation.
print("replay:", client.replay(job["id"])["matches"])
