"""Elpis Python SDK — settle-on-proof, and a client for the API.

Two things live here:

* the **canonicalization** (``elpis-canon/1``, see ``docs/canonicalization.md``),
  so a Python agent can compute the same commitment and attestation hashes the
  server does — and verify them independently; and
* a **client** for the settlement-job API, so an agent can commit a condition,
  verify a proof, and settle, in a handful of lines.

It is stdlib-only on purpose: an agent should be able to adopt this by copying one
file, not by adding a dependency graph. The canonicalization is a *second*
implementation of the spec, and its tests reproduce the reference hashes from the
TypeScript one — which is what makes "anyone can replay our decisions" true rather
than a slogan.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
import urllib.error
import urllib.request
from typing import Any, Iterable, Mapping, Optional, Sequence

__all__ = [
    "ElpisError",
    "commitment_hash",
    "attestation_reason",
    "settlement_attestation",
    "verify_webhook_signature",
    "ElpisClient",
]

DEFAULT_BASE_URL = "https://elpis.devilabs.dev"


class ElpisError(Exception):
    """An error returned by the API, carrying its machine-readable code."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message


# ── canonicalization — elpis-canon/1 ────────────────────────────────────────


def _canonical_check(check: Mapping[str, Any]) -> dict:
    # ``label`` is presentation only; it never affects the commitment.
    return {key: value for key, value in check.items() if key != "label"}


def _digest(payload: str) -> str:
    return "0x" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def commitment_hash(condition: Iterable[Mapping[str, Any]]) -> str:
    """``commitmentHash(condition)`` — fix "done" before the work begins."""
    canonical = [_canonical_check(check) for check in condition]
    # No whitespace, sorted keys, non-ASCII left as-is: the same bytes the
    # reference implementation produces.
    body = json.dumps(canonical, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
    return _digest(body)


_DECISION_TO_VERDICT = {"release": "complete", "refund": "reject", "hold": "hold"}


def attestation_reason(decision: str, rationale: Iterable[str]) -> str:
    """``attestationReason`` over a raw verdict (``complete``/``reject``/``hold``)."""
    body = json.dumps(
        {"decision": decision, "rationale": list(rationale)},
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return _digest(body)


def settlement_attestation(decision: str, reasons: Iterable[str]) -> str:
    """The attestation for a settlement decision: ``release`` | ``refund`` | ``hold``."""
    try:
        verdict = _DECISION_TO_VERDICT[decision]
    except KeyError:
        raise ValueError(f"unknown settlement decision: {decision!r}") from None
    return attestation_reason(verdict, reasons)


def verify_webhook_signature(
    body: str | bytes,
    header: str,
    secret: str,
    tolerance_seconds: int = 300,
    now: Optional[float] = None,
) -> bool:
    """Verify an ``Elpis-Signature: t=<unix>,v1=<hmac>`` header.

    The HMAC is over ``f"{timestamp}.{body}"``. A stale timestamp is refused, so a
    captured delivery cannot be replayed.
    """
    body_bytes = body.encode("utf-8") if isinstance(body, str) else bytes(body)
    parts: dict[str, str] = {}
    for piece in header.split(","):
        key, sep, value = piece.partition("=")
        if sep:
            parts[key.strip()] = value.strip()

    try:
        timestamp = int(parts["t"])
    except (KeyError, ValueError):
        return False
    signature = parts.get("v1")
    if not signature:
        return False

    current = time.time() if now is None else now
    if abs(current - timestamp) > tolerance_seconds:
        return False

    expected = hmac.new(
        secret.encode("utf-8"),
        f"{timestamp}.".encode("utf-8") + body_bytes,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


# ── the client ──────────────────────────────────────────────────────────────


class ElpisClient:
    """A thin client for the settlement-job API.

    Deliberately thin: no hidden retries, no magic. It makes idempotency keys easy
    and it never reports a job as released when it merely holds.
    """

    def __init__(
        self,
        token: str,
        base_url: str = DEFAULT_BASE_URL,
        timeout: float = 20.0,
    ) -> None:
        self.token = token
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def _request(
        self,
        method: str,
        path: str,
        body: Optional[Mapping[str, Any]] = None,
        idempotency_key: Optional[str] = None,
    ) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(f"{self.base_url}{path}", data=data, method=method)
        request.add_header("authorization", f"Bearer {self.token}")
        if data is not None:
            request.add_header("content-type", "application/json")
        if idempotency_key:
            request.add_header("idempotency-key", idempotency_key)

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8") if error.fp else ""
            try:
                detail = json.loads(raw).get("error", {})
            except json.JSONDecodeError:
                detail = {}
            raise ElpisError(
                error.code,
                detail.get("code", "error"),
                detail.get("message", raw or str(error)),
            ) from None
        return payload.get("data", payload)

    # ── jobs: commit → verify → settle ──────────────────────────────────────

    def commit_job(
        self,
        condition: Sequence[Mapping[str, Any]],
        provider: Optional[str] = None,
        deadline: Optional[str] = None,
        description: Optional[str] = None,
        idempotency_key: Optional[str] = None,
    ) -> Mapping[str, Any]:
        """Commit what "done" means before the work begins. Returns the job."""
        body: dict[str, Any] = {"condition": list(condition)}
        if provider is not None:
            body["provider"] = provider
        if deadline is not None:
            body["deadline"] = deadline
        if description is not None:
            body["description"] = description
        return self._request("POST", "/api/v1/jobs", body, idempotency_key)

    def list_jobs(self, limit: int = 50, status: Optional[str] = None) -> Sequence[Mapping[str, Any]]:
        query = f"?limit={int(limit)}" + (f"&status={status}" if status else "")
        return self._request("GET", f"/api/v1/jobs{query}")

    def get_job(self, job_id: str) -> Mapping[str, Any]:
        return self._request("GET", f"/api/v1/jobs/{job_id}")

    def verify(self, job_id: str, proof: Mapping[str, Any]) -> Mapping[str, Any]:
        """Dry-run a proof — what *would* happen, recording nothing."""
        return self._request("POST", f"/api/v1/jobs/{job_id}/verify", {"proof": dict(proof)})

    def settle(self, job_id: str, proof: Optional[Mapping[str, Any]] = None) -> Mapping[str, Any]:
        """Settle on the committed condition: release, refund, or hold."""
        body = {"proof": dict(proof)} if proof is not None else {}
        return self._request("POST", f"/api/v1/jobs/{job_id}/settle", body)

    def refund(self, job_id: str, reason: Optional[str] = None) -> Mapping[str, Any]:
        """Refund on demand — the safe direction: money returns, never releases."""
        body = {"reason": reason} if reason is not None else {}
        return self._request("POST", f"/api/v1/jobs/{job_id}/refund", body)

    def get_attestation(self, job_id: str) -> Mapping[str, Any]:
        return self._request("GET", f"/api/v1/attestations/{job_id}")

    def replay(self, job_id: str) -> Mapping[str, Any]:
        return self._request("POST", f"/api/v1/attestations/{job_id}/replay")
