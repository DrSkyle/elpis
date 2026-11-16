// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Signature check for the attestor: ECDSA for a key, ERC-1271 for a contract.
///
/// This is deliberately a small local library rather than OpenZeppelin's
/// `SignatureChecker`: the 5.6 release of that library needs the Cancun `MCOPY`
/// opcode, and this code must run on every chain it is deployed to without
/// assuming a hard fork. The logic is the same two cases and nothing more.
library AttestorSig {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    function isValid(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer == address(0)) return false;
        if (signer.code.length == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        }
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(0x1626ba7e, digest, signature));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == ERC1271_MAGIC;
    }
}

/// @dev Minimal EIP-712 domain handling (name, version, chainId, verifyingContract).
///      Local for the same reason as the library above: OpenZeppelin 5.6's EIP712
///      pulls in code using MCOPY. The domain separator is cached and recomputed
///      if the chain id ever changes (a fork), as the standard requires.
abstract contract Eip712Lite {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _nameHash;
    bytes32 private immutable _versionHash;
    uint256 private immutable _cachedChainId;
    bytes32 private immutable _cachedSeparator;

    constructor(string memory name_, string memory version_) {
        _nameHash = keccak256(bytes(name_));
        _versionHash = keccak256(bytes(version_));
        _cachedChainId = block.chainid;
        _cachedSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name_)), keccak256(bytes(version_)), block.chainid, address(this))
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _cachedSeparator;
        return keccak256(abi.encode(DOMAIN_TYPEHASH, _nameHash, _versionHash, block.chainid, address(this)));
    }

    function _hashTyped(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }
}
