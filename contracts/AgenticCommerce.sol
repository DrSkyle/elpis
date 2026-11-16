// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AgenticCommerce — ERC-8183 Job escrow with evaluator attestation
///
/// @notice A faithful, hook-free implementation of the ERC-8183 Job primitive.
/// The spec allows a "non-hooked kernel" that ignores the optional hook field;
/// this is that kernel. It exists so Elpis can occupy the evaluator seat and
/// settle on evidence rather than a model's confidence.
///
/// Lifecycle: Open → Funded → Submitted → (Completed | Rejected | Expired).
/// The client funds; the provider submits; a single evaluator, set at creation,
/// alone may `complete` (release to the provider) or `reject` (refund the client)
/// once work is submitted. After `expiredAt`, anyone may `claimRefund`.
///
/// Checks-effects-interactions is followed throughout: state is written before
/// every token transfer, and the token is trusted. No hooks, no upgradeability,
/// no admin — the smallest thing that is a real Job.
contract AgenticCommerce {
    using SafeERC20 for IERC20;

    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        /// @dev what the provider submitted; zero until `submit`. Stored so an
        ///      evaluator can check its decision is about the delivered work.
        bytes32 deliverable;
    }

    IERC20 public immutable paymentToken;
    uint256 public jobCounter;

    mapping(uint256 => Job) private jobs;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint256 expiredAt,
        string description
    );
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ZeroBudget();
    error ProviderNotSet();
    error BudgetMismatch();
    error ExpiryTooSoon();
    error TooEarly();
    error TransferFailed();

    constructor(address token_) {
        if (token_ == address(0)) revert ZeroAddress();
        paymentToken = IERC20(token_);
    }

    /// @notice Create a job. `provider` may be zero and set later via `setProvider`.
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description
    ) external returns (uint256) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp) revert ExpiryTooSoon();
        uint256 jobId = ++jobCounter;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open,
            deliverable: bytes32(0)
        });
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, description);
        return jobId;
    }

    function setProvider(uint256 jobId, address provider_) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        job.provider = provider_;
        emit ProviderSet(jobId, provider_);
    }

    function setBudget(uint256 jobId, uint256 amount) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        job.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    function fund(uint256 jobId, uint256 expectedBudget) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget == 0) revert ZeroBudget();
        if (job.budget != expectedBudget) revert BudgetMismatch();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        // Effects before the external call.
        job.status = JobStatus.Funded;
        paymentToken.safeTransferFrom(job.client, address(this), job.budget);
        emit JobFunded(jobId, job.client, job.budget);
    }

    function submit(uint256 jobId, bytes32 deliverable) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        job.status = JobStatus.Submitted;
        job.deliverable = deliverable;
        emit JobSubmitted(jobId, job.provider, deliverable);
    }

    /// @notice Evaluator completes the job: escrow is released to the provider.
    ///         `reason` is the attestation (e.g. a hash of the evidence).
    function complete(uint256 jobId, bytes32 reason) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();
        job.status = JobStatus.Completed;
        uint256 amount = job.budget;
        emit JobCompleted(jobId, job.evaluator, reason);
        if (amount > 0) {
            paymentToken.safeTransfer(job.provider, amount);
            emit PaymentReleased(jobId, job.provider, amount);
        }
    }

    /// @notice Reject: the client may reject while Open; the evaluator may reject
    ///         while Funded or Submitted. A funded escrow is refunded to the client.
    function reject(uint256 jobId, bytes32 reason) external {
        Job storage job = _require(jobId);
        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == JobStatus.Funded || job.status == JobStatus.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }
        JobStatus previous = job.status;
        uint256 refund = job.budget;
        job.status = JobStatus.Rejected;
        emit JobRejected(jobId, msg.sender, reason);
        if ((previous == JobStatus.Funded || previous == JobStatus.Submitted) && refund > 0) {
            paymentToken.safeTransfer(job.client, refund);
            emit Refunded(jobId, job.client, refund);
        }
    }

    /// @notice After expiry, anyone may return the escrow to the client. This path
    ///         is deliberately unconditional — a refund can never be blocked.
    function claimRefund(uint256 jobId) external {
        Job storage job = _require(jobId);
        if (job.status != JobStatus.Funded && job.status != JobStatus.Submitted) revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert TooEarly();
        uint256 refund = job.budget;
        job.status = JobStatus.Expired;
        emit JobExpired(jobId);
        if (refund > 0) {
            paymentToken.safeTransfer(job.client, refund);
            emit Refunded(jobId, job.client, refund);
        }
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _require(jobId);
    }

    /// @notice The job's client — who committed the condition. Exposed so a
    ///         deterministic evaluator contract can enforce who may bind it.
    function clientOf(uint256 jobId) external view returns (address) {
        return _require(jobId).client;
    }

    function providerOf(uint256 jobId) external view returns (address) {
        return _require(jobId).provider;
    }

    /// @notice What the provider submitted (zero before `submit`).
    function deliverableOf(uint256 jobId) external view returns (bytes32) {
        return _require(jobId).deliverable;
    }

    function _require(uint256 jobId) private view returns (Job storage) {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        return job;
    }
}
