// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PleaHook} from "../src/PleaHook.sol";
import {Addresses} from "../src/libraries/Addresses.sol";

/// @notice Off-chain computation only. No keys, environment, broadcast, FFI or filesystem permissions.
contract MineSalt {
    function initcode(address token, address gate, address owner) public pure returns (bytes memory) {
        return bytes.concat(type(PleaHook).creationCode, abi.encode(token, gate, owner));
    }

    /// @dev Search [start,start+attempts); resume at the returned next nonce if not found.
    function run(address launcher, bytes32 initcodeHash, uint256 start, uint256 attempts)
        public
        pure
        returns (bool found, bytes32 salt, address hook, uint256 next)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            hook = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), launcher, salt, initcodeHash)))));
            if (uint160(hook) & Addresses.HOOK_MASK == Addresses.HOOK_FLAGS) return (true, salt, hook, start + i + 1);
        }
        return (false, bytes32(0), address(0), start + attempts);
    }
}
