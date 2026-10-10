// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PLEA} from "./PLEA.sol";
import {PleaHook} from "./PleaHook.sol";
import {PleaDistributor} from "./PleaDistributor.sol";
import {CabalGate} from "./CabalGate.sol";
import {Addresses} from "./libraries/Addresses.sol";

/// @notice Constructor commits to the hook code; anyone may deploy that exact code using a mined salt.
contract PleaLaunch {
    error InvalidConfiguration();
    error InvalidInitcode();
    error InvalidSalt();
    error AlreadyDeployed();
    error NotOpen();
    event HookDeployed(address indexed hook, bytes32 salt);
    event Seeded(uint256 timestamp);
    address public immutable token;
    address public immutable gate;
    address public immutable distributor;
    address public immutable owner;
    uint256 public immutable START;
    bytes32 public immutable hookInitcodeHash;
    address public hook;
    bool public seeded;

    constructor(address token_, address gate_, address distributor_, uint256 start_) {
        if (token_ == address(0) || gate_ == address(0) || distributor_ == address(0) || start_ == 0) {
            revert InvalidConfiguration();
        }
        token = token_;
        gate = gate_;
        distributor = distributor_;
        START = start_;
        owner = PLEA(token_).owner();
        if (
            address(CabalGate(gate_).token()) != token_ || address(PleaDistributor(distributor_).token()) != token_
                || PleaDistributor(distributor_).owner() != owner
        ) revert InvalidConfiguration();
        PLEA(token_).setLauncher(address(this));
        hookInitcodeHash = keccak256(abi.encodePacked(type(PleaHook).creationCode, abi.encode(token_, gate_, owner)));
    }

    function deployHook(bytes32 salt, bytes calldata initcode) external returns (address deployed) {
        if (hook != address(0)) revert AlreadyDeployed();
        if (keccak256(initcode) != hookInitcodeHash) revert InvalidInitcode();
        address predicted = predictHook(salt);
        if (uint160(predicted) & Addresses.HOOK_MASK != Addresses.HOOK_FLAGS) revert InvalidSalt();
        bytes memory code = initcode;
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        if (deployed == address(0) || deployed != predicted) revert InvalidSalt();
        hook = deployed;
        emit HookDeployed(deployed, salt);
        PLEA(token).init(deployed);
    }

    function predictHook(bytes32 salt) public view returns (address) {
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitcodeHash));
        return address(uint160(uint256(digest)));
    }

    function seed() external {
        if (seeded || hook == address(0)) revert NotOpen();
        if (msg.sender != owner && block.timestamp < START) revert NotOpen();
        seeded = true;
        PleaHook(hook).seed();
        emit Seeded(block.timestamp);
    }
}
