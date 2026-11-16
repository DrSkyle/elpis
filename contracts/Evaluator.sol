// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AttestorSig, Eip712Lite} from "./AttestorSig.sol";

interface IJobs {
    function clientOf(uint256 jobId) external view returns (address);
    function providerOf(uint256 jobId) external view returns (address);
    function deliverableOf(uint256 jobId) external view returns (bytes32);
    function complete(uint256 jobId, bytes32 reason) external;
    function reject(uint256 jobId, bytes32 reason) external;
}

/**
 * @title Evaluator (version 2) - the ERC-8183 evaluator seat, decided by a signed attestation.
 *
 * ERC-8183 lets the evaluator be a smart contract. This one decides nothing by
 * itself: it verifies that a designated ATTESTOR signed the decision for this
 * exact job and the deliverable the provider actually submitted.
 *
 *   - The client binds the attestor and the committed condition ONCE, before the
 *     work begins. Bind-once: it cannot be rewritten after the work starts.
 *   - `settle` is permissionless to relay. The signature, not the caller, is the
 *     authority, so it does not matter who submits it.
 *   - The signed deliverable must equal the one stored by the jobs contract when
 *     the provider called `submit`. A hash read from chain state cannot be
 *     presented as proof: the attestor must have evaluated what was submitted.
 *   - The decision is bound to the job, the condition, the outcome and an expiry,
 *     and applies once.
 *
 * Why a signature and not a public hash: a hash stored on chain is readable by
 * everyone, including the provider, so "present the matching hash" proves nothing.
 * The attestor is the part that judges the work, which this contract cannot do.
 * Anyone choosing an attestor is choosing whom to trust to judge. Smart-contract
 * attestors (multisig, ERC-1271) are supported.
 */
contract Evaluator is Eip712Lite {
    IJobs public immutable jobs;

    struct Binding {
        address attestor;
        bytes32 condition;
    }

    /// jobId => who judges and the committed definition of "done"
    mapping(uint256 => Binding) public bindings;
    mapping(uint256 => bool) public settled;

    bytes32 public constant DECISION_TYPEHASH = keccak256(
        "Decision(uint256 jobId,bytes32 deliverable,bytes32 condition,bool released,bytes32 attestation,uint64 validUntil)"
    );

    event ConditionBound(uint256 indexed jobId, address indexed attestor, bytes32 condition);
    event Settled(uint256 indexed jobId, bool released, bytes32 deliverable, bytes32 attestation);

    error NotClient();
    error AlreadyBound();
    error NotBound();
    error AlreadySettled();
    error ZeroCondition();
    error ZeroAttestor();
    error AttestorNotIndependent();
    error DeliverableMismatch();
    error Expired();
    error BadSignature();

    constructor(IJobs jobs_) Eip712Lite("ElpisEvaluator", "2") {
        jobs = jobs_;
    }

    /// @notice Bind the attestor and the committed condition to a job. Client only, once.
    function bindCondition(uint256 jobId, address attestor_, bytes32 committed) external {
        if (msg.sender != jobs.clientOf(jobId)) revert NotClient();
        if (bindings[jobId].attestor != address(0)) revert AlreadyBound();
        if (committed == bytes32(0)) revert ZeroCondition();
        if (attestor_ == address(0)) revert ZeroAttestor();
        // The judge must not be a party to the deal.
        if (attestor_ == msg.sender || attestor_ == jobs.providerOf(jobId)) revert AttestorNotIndependent();
        bindings[jobId] = Binding({attestor: attestor_, condition: committed});
        emit ConditionBound(jobId, attestor_, committed);
    }

    /// @notice Settle the job with the attestor's signed decision. Applies once.
    /// @param deliverable the deliverable the attestor evaluated; must equal the submitted one
    /// @param released true = pay the provider; false = refund the client
    /// @param attestation hash of the decision and rationale, recorded as the on-chain reason
    function settle(
        uint256 jobId,
        bytes32 deliverable,
        bool released,
        bytes32 attestation,
        uint64 validUntil,
        bytes calldata signature
    ) external {
        Binding memory b = bindings[jobId];
        if (b.attestor == address(0)) revert NotBound();
        if (settled[jobId]) revert AlreadySettled();
        if (block.timestamp > validUntil) revert Expired();
        if (deliverable != jobs.deliverableOf(jobId)) revert DeliverableMismatch();
        if (released && deliverable == bytes32(0)) revert DeliverableMismatch();

        bytes32 digest = _hashTyped(
            keccak256(
                abi.encode(DECISION_TYPEHASH, jobId, deliverable, b.condition, released, attestation, validUntil)
            )
        );
        if (!AttestorSig.isValid(b.attestor, digest, signature)) revert BadSignature();

        settled[jobId] = true;
        if (released) {
            jobs.complete(jobId, attestation);
        } else {
            jobs.reject(jobId, attestation);
        }
        emit Settled(jobId, released, deliverable, attestation);
    }

    /// @notice Convenience: the committed condition for a job.
    function condition(uint256 jobId) external view returns (bytes32) {
        return bindings[jobId].condition;
    }
}
