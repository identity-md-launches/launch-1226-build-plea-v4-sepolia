// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The two vault functions the Stacker uses (ERC-4626 subset).
interface IStakedIMD {
    function asset() external view returns (address);
    function deposit(uint256 assets, address to) external returns (uint256 shares);
}

/// @title Stacker
/// @notice imd/acc cashback funnel. A project that wants to pay a trader cashback in staked IMD calls
/// `credit(trader, imdAmount)`: the Stacker pulls `imdAmount` IMD from the project (msg.sender),
/// deposits it into the sIMD vault with the trader as the share recipient, and records the totals.
/// The project funds the cashback from its own existing fees; the Stacker takes no fee, has no owner
/// or admin, and holds no IMD or sIMD between calls.
///
/// Integrators are expected to wrap `credit` in try/catch: it reverts (and moves nothing) when the
/// vault is paused, when the project's allowance or balance is short, or when the trader is zero.
///
/// Only the IMD path exists here; an ETH batch route is planned for v2.
contract Stacker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The IMD token the vault stakes (the vault's `asset()`).
    IERC20 public immutable IMD;
    /// @notice The staked-IMD ERC-4626 vault that receives every deposit.
    IStakedIMD public immutable SIMD;

    /// @notice IMD stacked for each trader, across all projects.
    mapping(address => uint256) public traderStacked;
    /// @notice IMD stacked by each project, across all traders.
    mapping(address => uint256) public projectStacked;
    /// @notice IMD stacked by `project` for `trader`.
    mapping(address => mapping(address => uint256)) public stackedBy;
    /// @notice IMD stacked through this contract in total.
    uint256 public totalStacked;
    /// @notice sIMD shares minted to each trader through this contract.
    mapping(address => uint256) public traderShares;
    /// @notice sIMD shares minted through each project.
    mapping(address => uint256) public projectShares;

    /// @notice Emitted once per successful non-zero credit.
    /// @param project The caller that funded the cashback.
    /// @param trader The address that received the sIMD shares.
    /// @param imd IMD pulled from the project and deposited.
    /// @param shares sIMD shares minted to the trader.
    event Stacked(address indexed project, address indexed trader, uint256 imd, uint256 shares);

    /// @notice `credit` was called with the zero address as trader.
    error ZeroTrader();
    /// @notice The vault's `asset()` is not the IMD address given to the constructor.
    error AssetMismatch(address vaultAsset, address imd);
    /// @notice The vault minted no shares for a non-zero deposit (would silently lose the IMD).
    error ZeroShares();

    /// @param imd The IMD token.
    /// @param sImd The staked-IMD vault; its `asset()` must equal `imd`.
    constructor(IERC20 imd, IStakedIMD sImd) {
        address vaultAsset = sImd.asset();
        if (vaultAsset != address(imd)) revert AssetMismatch(vaultAsset, address(imd));
        IMD = imd;
        SIMD = sImd;
        // One-time approval. The Stacker never holds IMD between calls (see the invariant tests), so
        // this allowance only ever covers the amount in flight inside a single `credit` call.
        imd.forceApprove(address(sImd), type(uint256).max);
    }

    /// @notice Pull `imdAmount` IMD from the caller and stake it for `trader`; the sIMD shares are
    /// minted directly to `trader`. Returns the shares minted.
    /// @dev Reverts with `ZeroTrader` for a zero trader. Returns 0 (no transfer, no event, no state
    /// change) for a zero amount. Bubbles up the vault's and token's errors unchanged, so a paused vault
    /// surfaces as the vault's `DepositMoreThanMax()` / `EnforcedPause()` and a short allowance or
    /// balance as the token's `ERC20InsufficientAllowance` / `ERC20InsufficientBalance`.
    function credit(address trader, uint256 imdAmount) external nonReentrant returns (uint256 shares) {
        if (trader == address(0)) revert ZeroTrader();
        if (imdAmount == 0) return 0;

        IMD.safeTransferFrom(msg.sender, address(this), imdAmount);
        shares = SIMD.deposit(imdAmount, trader);
        if (shares == 0) revert ZeroShares();

        traderStacked[trader] += imdAmount;
        projectStacked[msg.sender] += imdAmount;
        stackedBy[msg.sender][trader] += imdAmount;
        totalStacked += imdAmount;
        traderShares[trader] += shares;
        projectShares[msg.sender] += shares;

        emit Stacked(msg.sender, trader, imdAmount, shares);
    }
}
