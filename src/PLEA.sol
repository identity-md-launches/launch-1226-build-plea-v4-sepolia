// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Addresses} from "./libraries/Addresses.sol";

interface ILaunchConfig {
    function token() external view returns (address);
    function gate() external view returns (address);
    function distributor() external view returns (address);
    function hook() external view returns (address);
}

/// @notice Fixed supply. Transfer restrictions are enforced at the token, including transferFrom.
contract PLEA is ERC20 {
    error CabalIsWatching();
    error Unauthorized();
    error InvalidAddress();
    error AlreadyInitialized();
    event LauncherSet(address indexed launcher);
    event Initialized(address indexed hook, address indexed gate, address indexed distributor);
    event Allowed(address indexed account);
    event CabalKilled();

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    bytes32 private constant DEPLOYING = keccak256("PLEA.deploy.transaction");
    address public immutable owner;
    address public launcher;
    address public hook;
    address public gate;
    address public distributor;
    bool public cabalDead;
    mapping(address => bool) public allowed;

    constructor(address owner_) ERC20("PLEA", "PLEA") {
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
        bytes32 slot = DEPLOYING;
        assembly ("memory-safe") { tstore(slot, 1) }
    }

    /// @dev Deliberately usable only in the constructor transaction, once, by the launch itself.
    function setLauncher(address launcher_) external {
        bytes32 slot = DEPLOYING;
        uint256 deploying;
        assembly ("memory-safe") { deploying := tload(slot) }
        if (deploying == 0 || launcher != address(0) || launcher_ != msg.sender) revert Unauthorized();
        if (launcher_ == address(0)) revert InvalidAddress();
        launcher = launcher_;
        assembly ("memory-safe") { tstore(slot, 0) }
        emit LauncherSet(launcher_);
    }

    function init(address hook_) external {
        if (msg.sender != launcher) revert Unauthorized();
        if (hook != address(0)) revert AlreadyInitialized();
        ILaunchConfig launch = ILaunchConfig(launcher);
        if (hook_ == address(0) || hook_.code.length == 0 || hook_ != launch.hook()) revert InvalidAddress();
        hook = hook_;
        gate = launch.gate();
        distributor = launch.distributor();
        emit Initialized(hook, gate, distributor);
        _mint(hook, SUPPLY * 9 / 10);
        _mint(distributor, SUPPLY / 10);
    }

    function allow(address account) external {
        if (msg.sender != owner) revert Unauthorized();
        if (account == address(0)) revert InvalidAddress();
        allowed[account] = true;
        emit Allowed(account);
    }

    function killCabal() external {
        if (msg.sender != gate) revert Unauthorized();
        cabalDead = true;
        emit CabalKilled();
    }

    function burn(uint256 amount) external {
        if (msg.sender != hook) revert Unauthorized();
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!cabalDead && from != address(0) && to != address(0)) {
            if (to == Addresses.MANAGER && from != gate && from != hook) revert CabalIsWatching();
            if (
                from != Addresses.MANAGER && from != hook && from != gate && from != distributor && !allowed[from]
                    && !(to == gate && msg.sender == gate)
            ) revert CabalIsWatching();
        }
        super._update(from, to, value);
    }
}
