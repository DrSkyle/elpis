// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AttestorSig, Eip712Lite} from "./AttestorSig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LazarusVault (version 2)
/// @notice Bounded, evidence-settled escrow for Elpis treasury operations.
///
/// @dev Three independent authorities, none of which can steal on its own:
///
///   - OPERATOR  stages and submits payments (the owner's wallet in self-custody).
///               It cannot release without evidence and cannot cancel an escrow.
///   - ATTESTOR  signs the settlement decision (EIP-712). It cannot move funds:
///               a signature is only useful to the operator (release) or as proof
///               for a refund back to the payer.
///   - GUARDIAN  the brake. It can pause, freeze, refund to the payer and veto
///               queued changes. It can never send funds anywhere else.
///
/// What this contract guarantees, in plain terms:
///   1. A release needs the operator's transaction AND the attestor's signature
///      over the exact escrow (payee, amount, condition, outcome). The payer
///      cannot pay out on a whim, and the attestor cannot pay anyone by itself.
///   2. Before the deadline an escrow can only be refunded by the guardian or by
///      an attestor-signed REFUND. The payer has no unilateral cancel, and no
///      third party can front-run a pending release by refunding it.
///   3. At or after the deadline anyone may refund it to the payer. Time never
///      releases funds; it only ever returns them. A refund is never pausable.
///   4. New payees and looser limits are queued; the guardian or operator can
///      cancel them. Removing a payee or tightening a limit is immediate.
///   5. Per-transaction and per-day ceilings bound every outflow, including the
///      direct `transfer` path, so a stolen operator key has a hard cap.
///
/// Once `release` executes the transfer is final. USDC itself can be frozen by its
/// issuer; that risk is outside this contract and is named in the docs.
contract LazarusVault is AccessControl, Pausable, ReentrancyGuard, Eip712Lite {
    using SafeERC20 for IERC20;

    uint256 public constant VERSION = 2;

    enum EscrowStatus {
        NONE,
        OPEN,
        RELEASED,
        REFUNDED,
        FROZEN
    }

    struct Escrow {
        address payee;
        uint256 amount;
        uint64 releaseAt;
        EscrowStatus status;
        bytes32 conditionHash;
        bytes32 attestation;
        /// @dev who funded it; refunds always go here, even if the operator rotates
        address payer;
        /// @dev the budget window it was counted in, so a refund only returns budget to that window
        uint256 windowStart;
    }

    /// @notice Settlement outcomes the attestor can sign.
    uint8 public constant OUTCOME_RELEASE = 1;
    uint8 public constant OUTCOME_REFUND = 2;

    bytes32 public constant SETTLEMENT_TYPEHASH = keccak256(
        "Settlement(bytes32 id,address payee,uint256 amount,bytes32 conditionHash,uint8 outcome,bytes32 attestation,uint64 validUntil)"
    );

    bytes32 internal constant OPERATOR_ROLE = keccak256("LAZARUS_VAULT_OPERATOR_ROLE");
    bytes32 internal constant GUARDIAN_ROLE = keccak256("LAZARUS_VAULT_GUARDIAN_ROLE");

    IERC20 public immutable token;
    /// @notice Whether the guardian may install a new operator while paused
    ///         (managed treasuries). False for self-custody: the guardian is a
    ///         brake only and can never take control.
    bool public immutable guardianMayRecoverOperator;

    address public operator;
    address public guardian;
    address public attestor;

    uint256 public maxPerTx;
    uint256 public maxPerDay;
    uint256 public spentToday;
    uint256 public dayStart;

    mapping(address => bool) public allowlisted;
    /// @notice payee => time it becomes usable (0 = not queued)
    mapping(address => uint64) public pendingPayee;
    mapping(bytes32 => Escrow) public escrows;

    struct PendingCeiling {
        uint256 perTx;
        uint256 perDay;
        uint64 readyAt;
    }
    PendingCeiling public pendingCeiling;

    struct PendingAttestor {
        address next;
        uint64 readyAt;
    }
    PendingAttestor public pendingAttestor;

    uint256 public ceilingDelay = 6 hours;
    uint256 public allowlistDelay;
    uint256 public constant MIN_CEILING_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 7 days;

    event EscrowCreated(bytes32 indexed id, address indexed payee, uint256 amount, uint64 releaseAt, bytes32 conditionHash);
    event EscrowReleased(bytes32 indexed id, address indexed payee, uint256 amount, bytes32 attestation);
    event EscrowRefunded(bytes32 indexed id, uint256 amount, bytes32 attestation);
    event EscrowFrozen(bytes32 indexed id);
    event EscrowUnfrozen(bytes32 indexed id);
    event AllowlistSet(address indexed account, bool allowed);
    event AllowlistQueued(address indexed account, uint64 readyAt);
    event AllowlistQueueCancelled(address indexed account);
    event AllowlistDelaySet(uint256 delay);
    event CeilingSet(uint256 maxPerTx, uint256 maxPerDay);
    event CeilingQueued(uint256 perTx, uint256 perDay, uint64 readyAt);
    event CeilingQueueCancelled();
    event CeilingDelaySet(uint256 delay);
    event OperatorSet(address indexed operator);
    event GuardianSet(address indexed guardian);
    event AttestorQueued(address indexed next, uint64 readyAt);
    event AttestorSet(address indexed attestor);
    event AttestorQueueCancelled();
    event PauseSet(bool paused);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Transferred(address indexed to, uint256 amount);

    error NotOperator();
    error NotGuardian();
    error NotAllowlisted();
    error CeilingExceeded();
    error BadState();
    error TooEarly();
    error ZeroAmount();
    error ZeroAddress();
    error MissingCondition();
    error RolesNotIndependent();
    error DelayOutOfRange();
    /// @dev The caller is not allowed to refund yet and brought no valid attestation.
    error RefundNotAuthorized();
    error BadAttestation();

    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert NotGuardian();
        _;
    }

    /// @param token_ settlement token (USDC)
    /// @param operator_ stages and submits payments
    /// @param guardian_ brake: pause, freeze, refund-to-payer, veto
    /// @param guardianMayRecoverOperator_ false for self-custody
    /// @param attestor_ signs settlement decisions (EIP-712); must be independent
    /// @param maxPerTx_ per-payment ceiling, in token base units (non-zero)
    /// @param maxPerDay_ per-day ceiling, in token base units (non-zero)
    /// @param allowlistDelay_ seconds a new payee waits before it can be paid (0 = immediate)
    /// @param initialPayees_ payees usable from the first block, so a fresh vault is not idle
    constructor(
        address token_,
        address operator_,
        address guardian_,
        bool guardianMayRecoverOperator_,
        address attestor_,
        uint256 maxPerTx_,
        uint256 maxPerDay_,
        uint256 allowlistDelay_,
        address[] memory initialPayees_
    ) Eip712Lite("LazarusVault", "2") {
        if (token_ == address(0) || operator_ == address(0) || guardian_ == address(0) || attestor_ == address(0)) {
            revert ZeroAddress();
        }
        if (operator_ == guardian_ || operator_ == attestor_ || guardian_ == attestor_) revert RolesNotIndependent();
        if (maxPerTx_ == 0 || maxPerDay_ == 0) revert ZeroAmount();
        if (allowlistDelay_ > MAX_DELAY) revert DelayOutOfRange();
        token = IERC20(token_);
        operator = operator_;
        guardian = guardian_;
        attestor = attestor_;
        guardianMayRecoverOperator = guardianMayRecoverOperator_;
        _grantRole(OPERATOR_ROLE, operator_);
        _grantRole(GUARDIAN_ROLE, guardian_);
        dayStart = block.timestamp;
        maxPerTx = maxPerTx_;
        maxPerDay = maxPerDay_;
        allowlistDelay = allowlistDelay_;
        for (uint256 i = 0; i < initialPayees_.length; i++) {
            if (initialPayees_[i] == address(0)) revert ZeroAddress();
            allowlisted[initialPayees_[i]] = true;
            emit AllowlistSet(initialPayees_[i], true);
        }
    }

    function renounceRole(bytes32, address) public pure override {
        revert BadState();
    }

    /* ───────────────────────────── funding ───────────────────────────── */

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw unencumbered tokens back to the operator. Ceiling-bound.
    function withdraw(uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _enforceCeiling(amount);
        token.safeTransfer(operator, amount);
        emit Withdrawn(operator, amount);
    }

    /* ─────────────────────── recoverable settlement ───────────────────── */

    /// @notice Stage a payment against a committed condition. The funds move
    ///         from the operator into the vault and stay governed by the
    ///         condition until the attestor's decision (or the deadline) settles.
    function createEscrow(bytes32 id, address payee, uint256 amount, uint64 releaseAt, bytes32 conditionHash)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (conditionHash == bytes32(0)) revert MissingCondition();
        if (escrows[id].status != EscrowStatus.NONE) revert BadState();
        if (!allowlisted[payee]) revert NotAllowlisted();
        if (releaseAt < block.timestamp) revert TooEarly();
        _enforceCeiling(amount);

        escrows[id] = Escrow({
            payee: payee,
            amount: amount,
            releaseAt: releaseAt,
            status: EscrowStatus.OPEN,
            conditionHash: conditionHash,
            attestation: bytes32(0),
            payer: operator,
            windowStart: dayStart
        });
        token.safeTransferFrom(operator, address(this), amount);
        emit EscrowCreated(id, payee, amount, releaseAt, conditionHash);
    }

    /// @notice Release a staged payment to the payee. Final and irreversible.
    /// @dev Needs the operator's call AND the attestor's EIP-712 signature over
    ///      this exact escrow with outcome RELEASE. Blocked while paused.
    /// @param attestation hash of the settlement decision and rationale (signed)
    /// @param validUntil the signature is void after this time (signed)
    /// @param signature attestor signature (ECDSA or ERC-1271)
    function release(bytes32 id, bytes32 attestation, uint64 validUntil, bytes calldata signature)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        Escrow storage e = escrows[id];
        if (e.status != EscrowStatus.OPEN) revert BadState();
        if (!_attested(id, e, OUTCOME_RELEASE, attestation, validUntil, signature)) revert BadAttestation();
        e.status = EscrowStatus.RELEASED;
        e.attestation = attestation;
        token.safeTransfer(e.payee, e.amount);
        emit EscrowReleased(id, e.payee, e.amount, attestation);
    }

    /// @notice Return a staged payment to the payer that funded it.
    /// @dev Allowed when ANY of these holds, and never otherwise:
    ///        - the deadline `releaseAt` has passed (anyone may call: silence refunds);
    ///        - the caller is the guardian (the brake);
    ///        - the attestor signed a REFUND outcome for this exact escrow
    ///          (anyone may relay it: a contradiction refunds at once).
    ///      The payer, as operator, has no unilateral cancel, and a third party
    ///      cannot front-run a pending release. Not pausable, so a halt can never
    ///      strand money. A FROZEN escrow can also refund.
    function refund(bytes32 id, bytes32 attestation, uint64 validUntil, bytes calldata signature)
        external
        nonReentrant
    {
        Escrow storage e = escrows[id];
        if (e.status != EscrowStatus.OPEN && e.status != EscrowStatus.FROZEN) revert BadState();
        bool allowed = block.timestamp >= e.releaseAt || hasRole(GUARDIAN_ROLE, msg.sender)
            || _attested(id, e, OUTCOME_REFUND, attestation, validUntil, signature);
        if (!allowed) revert RefundNotAuthorized();

        e.status = EscrowStatus.REFUNDED;
        e.attestation = attestation;
        // Refunded money never reached the payee, so it returns the budget it
        // consumed, but only to the window it was counted in.
        if (e.windowStart == dayStart && spentToday >= e.amount) spentToday -= e.amount;
        token.safeTransfer(e.payer, e.amount);
        emit EscrowRefunded(id, e.amount, attestation);
    }

    function freeze(bytes32 id) external onlyGuardian {
        Escrow storage e = escrows[id];
        if (e.status != EscrowStatus.OPEN) revert BadState();
        e.status = EscrowStatus.FROZEN;
        emit EscrowFrozen(id);
    }

    function unfreeze(bytes32 id) external onlyGuardian {
        Escrow storage e = escrows[id];
        if (e.status != EscrowStatus.FROZEN) revert BadState();
        e.status = EscrowStatus.OPEN;
        emit EscrowUnfrozen(id);
    }

    /// @notice Direct, irreversible transfer to an allow-listed payee, for
    ///         actions classified R4 after explicit human approval. Ceiling-bound.
    function transfer(address to, uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!allowlisted[to]) revert NotAllowlisted();
        _enforceCeiling(amount);
        token.safeTransfer(to, amount);
        emit Transferred(to, amount);
    }

    /* ─────────────────────────── allowlist (queued) ───────────────────── */

    /// @notice Add or remove a payee.
    /// @dev Removing is immediate and open to the operator or the guardian.
    ///      Adding is queued for `allowlistDelay` (the guardian or operator can
    ///      cancel); with a zero delay it applies at once. A stolen operator key
    ///      therefore cannot add an attacker as a payee and drain the vault before
    ///      the guardian can react.
    function setAllowlist(address account, bool allowed) external {
        if (!allowed) {
            if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotOperator();
            allowlisted[account] = false;
            delete pendingPayee[account];
            emit AllowlistSet(account, false);
            return;
        }
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert NotOperator();
        _requireNotPaused();
        if (account == address(0)) revert ZeroAddress();
        if (allowlisted[account]) return;
        if (allowlistDelay == 0) {
            allowlisted[account] = true;
            emit AllowlistSet(account, true);
            return;
        }
        uint64 readyAt = uint64(block.timestamp + allowlistDelay);
        pendingPayee[account] = readyAt;
        emit AllowlistQueued(account, readyAt);
    }

    /// @notice Activate a queued payee once its delay has passed. Anyone may call.
    function applyAllowlist(address account) external whenNotPaused {
        uint64 readyAt = pendingPayee[account];
        if (readyAt == 0) revert BadState();
        if (block.timestamp < readyAt) revert TooEarly();
        delete pendingPayee[account];
        allowlisted[account] = true;
        emit AllowlistSet(account, true);
    }

    function cancelAllowlist(address account) external {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotOperator();
        delete pendingPayee[account];
        emit AllowlistQueueCancelled(account);
    }

    /// @notice The guardian owns the delay, so a compromised operator cannot shorten it.
    function setAllowlistDelay(uint256 delay) external onlyGuardian {
        if (delay > MAX_DELAY) revert DelayOutOfRange();
        allowlistDelay = delay;
        emit AllowlistDelaySet(delay);
    }

    /* ───────────────────────────── ceilings ───────────────────────────── */

    /// @notice Tightening is immediate; loosening is queued and cancellable.
    function setCeiling(uint256 perTx, uint256 perDay) external onlyOperator whenNotPaused {
        if (_loosens(perTx, maxPerTx) || _loosens(perDay, maxPerDay)) {
            uint64 readyAt = uint64(block.timestamp + ceilingDelay);
            pendingCeiling = PendingCeiling({perTx: perTx, perDay: perDay, readyAt: readyAt});
            emit CeilingQueued(perTx, perDay, readyAt);
            return;
        }
        maxPerTx = perTx;
        maxPerDay = perDay;
        emit CeilingSet(perTx, perDay);
    }

    function applyCeiling() external onlyOperator whenNotPaused {
        PendingCeiling memory p = pendingCeiling;
        if (p.readyAt == 0) revert BadState();
        if (block.timestamp < p.readyAt) revert TooEarly();
        maxPerTx = p.perTx;
        maxPerDay = p.perDay;
        delete pendingCeiling;
        emit CeilingSet(p.perTx, p.perDay);
    }

    function cancelPendingCeiling() external {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotOperator();
        delete pendingCeiling;
        emit CeilingQueueCancelled();
    }

    function setCeilingDelay(uint256 delay) external onlyGuardian whenNotPaused {
        if (delay < MIN_CEILING_DELAY || delay > MAX_DELAY) revert DelayOutOfRange();
        ceilingDelay = delay;
        emit CeilingDelaySet(delay);
    }

    /* ─────────────────────────────── roles ────────────────────────────── */

    /// @notice Rotate the operator (itself, or the guardian while paused when
    ///         `guardianMayRecoverOperator`). Zero is refused.
    function setOperator(address next) external {
        bool operator_ = hasRole(OPERATOR_ROLE, msg.sender);
        bool guardianRecovery = guardianMayRecoverOperator && hasRole(GUARDIAN_ROLE, msg.sender) && paused();
        if (!operator_ && !guardianRecovery) revert NotOperator();
        if (next == address(0)) revert ZeroAddress();
        if (next == guardian || next == attestor) revert RolesNotIndependent();
        _revokeRole(OPERATOR_ROLE, operator);
        _grantRole(OPERATOR_ROLE, next);
        operator = next;
        emit OperatorSet(next);
    }

    function setGuardian(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        if (next == operator || next == attestor) revert RolesNotIndependent();
        _revokeRole(GUARDIAN_ROLE, guardian);
        _grantRole(GUARDIAN_ROLE, next);
        guardian = next;
        emit GuardianSet(next);
    }

    /// @notice Queue a new attestor. Guardian-only and delayed, so neither a
    ///         compromised operator nor a compromised guardian can swap the
    ///         evidence signer instantly.
    function queueAttestor(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        if (next == operator || next == guardian) revert RolesNotIndependent();
        uint64 readyAt = uint64(block.timestamp + ceilingDelay);
        pendingAttestor = PendingAttestor({next: next, readyAt: readyAt});
        emit AttestorQueued(next, readyAt);
    }

    function applyAttestor() external {
        PendingAttestor memory p = pendingAttestor;
        if (p.readyAt == 0) revert BadState();
        if (block.timestamp < p.readyAt) revert TooEarly();
        if (p.next == operator || p.next == guardian) revert RolesNotIndependent();
        attestor = p.next;
        delete pendingAttestor;
        emit AttestorSet(p.next);
    }

    function cancelPendingAttestor() external onlyGuardian {
        delete pendingAttestor;
        emit AttestorQueueCancelled();
    }

    /// @notice Global emergency stop. Only the guardian pauses and unpauses.
    function pause() external onlyGuardian {
        if (!paused()) _pause();
        emit PauseSet(true);
    }

    function unpause() external onlyGuardian {
        if (paused()) _unpause();
        emit PauseSet(false);
    }

    /* ───────────────────────────── internals ─────────────────────────── */

    function _loosens(uint256 next, uint256 current) internal pure returns (bool) {
        uint256 n = next == 0 ? type(uint256).max : next;
        uint256 c = current == 0 ? type(uint256).max : current;
        return n > c;
    }

    function _enforceCeiling(uint256 amount) internal {
        if (maxPerTx != 0 && amount > maxPerTx) revert CeilingExceeded();
        if (block.timestamp >= dayStart + 1 days) {
            dayStart = block.timestamp;
            spentToday = 0;
        }
        if (maxPerDay != 0 && spentToday + amount > maxPerDay) revert CeilingExceeded();
        spentToday += amount;
    }

    /// @dev True when `signature` is the attestor's EIP-712 signature over this
    ///      exact escrow and outcome, and has not expired.
    function _attested(
        bytes32 id,
        Escrow storage e,
        uint8 outcome,
        bytes32 attestation,
        uint64 validUntil,
        bytes calldata signature
    ) internal view returns (bool) {
        if (signature.length == 0 || block.timestamp > validUntil) return false;
        bytes32 digest = _hashTyped(
            keccak256(
                abi.encode(
                    SETTLEMENT_TYPEHASH, id, e.payee, e.amount, e.conditionHash, outcome, attestation, validUntil
                )
            )
        );
        return AttestorSig.isValid(attestor, digest, signature);
    }

    /// @notice Read an escrow in full.
    function escrowOf(bytes32 id)
        external
        view
        returns (
            address payee,
            uint256 amount,
            uint64 releaseAt,
            EscrowStatus status,
            bytes32 conditionHash,
            bytes32 attestation,
            address payer
        )
    {
        Escrow storage e = escrows[id];
        return (e.payee, e.amount, e.releaseAt, e.status, e.conditionHash, e.attestation, e.payer);
    }

    /// @notice The EIP-712 domain separator, so off-chain signers can be checked.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }
}
