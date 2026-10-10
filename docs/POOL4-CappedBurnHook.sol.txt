// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
   ____   ___   ___  _     _  _
  |  _ \ / _ \ / _ \| |   | || |
  | |_) | | | | | | | |   | || |_
  |  __/| |_| | |_| | |___|__   _|
  |_|    \___/ \___/|_____|  |_|

  POOL4 · CappedBurnHook — a Uniswap v4 market that permanently burns what's sold into it.
*/

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice An ordinary ETH/token Uniswap v4 market that permanently retires the tokens sold into
/// it, and recycles the ETH it recovers into a wide single-sided backstop above the price.
///
/// @dev Pricing is untouched. The pool carries real full-range liquidity, quotes through standard
/// concentrated-liquidity math, charges the pool's native LP fee, and declares no delta flags, so
/// any router or aggregator that can trade a plain v4 pool can trade this one.
///
/// Three mechanisms, all enforced after the swap has settled:
///
/// 1. CAP. The market position may never hold more tokens than `inventoryCap`. Sells push tokens
///    in; anything above the cap is withdrawn and leaves permanently, split `rewardShareBps` to
///    `rewardsRecipient` and the rest to `burnSink`. Withdrawing liquidity is not a swap, so the
///    square-root price is identical before and after and nobody is quoted differently.
///
/// 2. RATCHET. Buys draw the position below the cap; the cap follows it down, so the next sell
///    burns rather than merely refilling. `capFloor` bounds this: the cap never falls below it, so
///    once the market has shrunk to that size it simply behaves as an ordinary pool - below the
///    floor nothing burns, and selling back above it resumes the cap. Without a floor the ratchet
///    compounds toward zero and the market ratchets itself out of existence.
///
/// 3. BACKSTOP. Trimming under the cap is proportional, so it pulls ETH out alongside the tokens.
///    That ETH accrues to `retainedEth` and is redeployed by a permissionless keeper as one wide
///    single-sided position above the current price, mirroring the market position's ETH side so
///    the sell side keeps behaving like an ordinary pool rather than melting. It costs no tokens to
///    place. Redeployment is batched behind an ETH threshold, so routine sells run with
///    marginally-less LP instead of paying a remove/redeploy on every trade. The band is never
///    priced off live spot: its lower tick is floored at `deploymentFloorTick`, which jumps up to
///    any tick the pool has traded at and drifts back down only at `floorDecayTicksPerDay`, so a
///    manipulated placement costs days of holding a false price rather than one block. When a dump
///    pushes price up into the backstop it fills; the next rebalance burns the tokens it bought (the
///    same burn/reward split as a trim) and redeploys the recovered ETH above the new spot.
contract CappedBurnHook is Ownable {
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    error AlreadyOpen();
    error BidNotSingleSided(uint256 tokensRequired);
    error NotSelf();
    error CallbackNotExpected();
    error IncorrectEthAmount(uint256 required, uint256 supplied);
    error InsufficientRetainedEth(uint256 requested, uint256 available);
    error InvalidConfiguration();
    error InvalidLiquidity();
    error InvalidPool();
    error InvalidPoolManagerCaller();
    error LiquidityRestrictedToHook();
    error InitializationRestrictedToHook();
    error MarketNotOpen();
    error PoolNotInitialized();
    error RebalanceDisabled();
    error RebalanceNotNeeded();
    error PriceMovedDuringLiquidityChange(uint160 before_, uint160 after_);
    error TokenAmountExceeded(uint256 required, uint256 maximum);
    error UnexpectedLiquidityDelta();

    event PoolInitialized(uint160 sqrtPriceX96, int24 tick);
    event MarketOpened(uint128 liquidity, uint256 ethDeposited, uint256 inventoryCap);
    event MarketClosed(address indexed recipient, uint256 ethReturned, uint256 tokensReturned);
    event InventoryFunded(uint128 liquidity, uint256 ethDeposited, uint256 tokensDeposited, uint256 newCap);
    event CapRatcheted(uint256 previousCap, uint256 newCap);
    event Trimmed(uint128 liquidityRemoved, uint256 tokensBurned, uint256 tokensRewarded, uint256 ethRetained);
    event BackstopDeployed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 ethDeployed);
    event BackstopSettled(uint128 liquidity, uint256 tokensBurned, uint256 tokensRewarded, uint256 ethReturned);
    event RebalanceConfigUpdated(bool enabled, uint256 ethThreshold);
    event MaxRefStepUpdated(int24 maxStep);
    event KeeperRewardUpdated(uint256 reward);
    event KeeperRewardPaid(address indexed keeper, uint256 reward);
    event Rebalanced(int24 lower);
    event DeploymentFloorUpdated(int24 previousFloor, int24 newFloor);
    event FloorDecayUpdated(uint256 ticksPerDay);
    event CapFloorUpdated(uint256 previousFloor, uint256 newFloor);
    event CapDecayUpdated(uint256 tokensPerDay);
    event RatchetUpdated(uint256 previousBps, uint256 newBps);
    event BurnSinkUpdated(address indexed previous, address indexed current);
    event RewardsRecipientUpdated(address indexed previous, address indexed current);
    event RewardShareUpdated(uint256 previousBps, uint256 newBps);
    event RetainedEthWithdrawn(address indexed recipient, uint256 amount);
    event ClaimsSettled(uint256 tokensToBurnSink, uint256 tokensToRewards, uint256 ethRedeemed);
    /// @notice The LP fee realised by one swap (or a backstop close). Emitted once per collection.
    event FeeCollected(uint256 tokenFee, uint256 ethFee);
    event FeesWithdrawn(address indexed recipient, uint256 tokenAmount, uint256 ethAmount);

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    /// @dev High enough to be effectively unlimited for any real token, low enough that
    /// `capDecayTokensPerDay * elapsed` in `_applyCap` cannot overflow. Without a bound, a large
    /// enough setting makes that checked multiplication revert - and because `_applyCap` is
    /// deliberately not wrapped in try/catch, the revert propagates to every swap and takes the
    /// whole pool offline.
    uint256 public constant MAX_CAP_DECAY_PER_DAY = type(uint128).max;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public burnSink;
    address public rewardsRecipient;
    /// @notice Share of every trim/backstop burn skimmed to `rewardsRecipient` instead of burned.
    /// Owner-tunable via `setRewardShareBps`, but capped at `MAX_REWARD_SHARE_BPS` so burning always
    /// dominates and the owner can never redirect the whole trim.
    uint256 public rewardShareBps;
    uint256 internal constant MAX_REWARD_SHARE_BPS = 3_000; // <= 30% to rewards; burn always >= 70%
    uint256 public immutable minTrimTokens;
    uint24 public immutable lpFee;
    int24 public immutable tickSpacing;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    // --- adjustable policy -------------------------------------------------
    /// @notice Share of the room a buy opens that the cap gives back. 10_000 = full ratchet.
    uint256 public ratchetBps;
    /// @notice The cap never falls below this. Below it the market behaves as an ordinary pool.
    uint256 public capFloor;
    /// @notice Maximum number of tokens that may be ratcheted off the cap per day.
    ///
    /// @dev Without this the ratchet is bounded by trading volume rather than by the protocol, and
    /// volume is something anyone can manufacture. A round trip strips its own size out of the
    /// pool while costing the trader only the LP fee, so wash trading can run the entire burn
    /// programme to the floor for a few ETH. Rate-limiting the decay decouples burn pace from
    /// volume: the ratchet still fires on every sell-after-buy, but the cap can only travel so far
    /// per day no matter how hard the market is pushed. Zero disables ratcheting entirely.
    ///
    /// @dev Absolute rather than a share of the cap: a percentage decelerates as the cap shrinks,
    /// which is the wrong shape for a programme meant to run at a steady pace. Note that wash
    /// trading is not profitable at any setting - a round trip returns the trader's tokens and
    /// costs them the LP fee - so this governs pacing, not theft.
    uint256 public capDecayTokensPerDay;
    /// @dev Clock for the decay allowance. Partial use advances it proportionally so unused time
    /// is not thrown away.
    uint256 public lastCapDecayAt;
    /// @dev Sub-quantum decay debt carried between ratchets, in token·day units. A single ratchet
    /// smaller than one clock-second of allowance would otherwise floor its clock advance to zero;
    /// accumulating the remainder here means such fragments still debit the clock once enough of
    /// them add up, so splitting a cap reduction into many tiny ratchets cannot outrun the limit.
    uint256 public capDecayRemainder;
    /// @notice The single wide single-sided ETH backstop above spot.

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The live backstop. Recovered ETH is redeployed here as one wide single-sided band
    /// spanning from just above spot to `tickUpper`, so sell-side depth is preserved rather than
    /// concentrated (see mechanism 3 in the contract doc).
    Band public backstop;
    /// @notice ETH principal originally deposited into the live backstop. Keeping this separate from
    /// the range lets the hook measure how much principal has actually converted into tokens; a tick
    /// boundary alone is not a fill and cannot justify a keeper reward.
    uint256 public backstopEthPrincipal;

    // --- rebalance policy (keeper-driven, priced off a block-lagged reference) ---
    /// @notice Owner kill switch for the keeper backstop rebalance.
    bool public rebalanceEnabled;
    /// @notice A keeper rebalance is "worth it" once newly trimmed, unbatched ETH reaches this or the
    /// backstop has converted this much ETH principal. Enforced by both `pendingRebalance()` and
    /// `rebalance()`.
    uint256 public rebalanceEthThreshold;
    /// @notice Maximum ETH tip paid to whoever calls permissionless `rebalance()` for worthwhile work.
    /// Actual payment is bounded by the pool fee on measured work, held back from deployment, and paid
    /// after the unlock. `0` disables tipping (the protocol runs its own keeper).
    uint256 public keeperReward;
    uint256 internal constant MAX_KEEPER_REWARD = 0.1 ether;

    /// @notice Rate-limited follower of the previous block's closing tick: the target the placement
    /// floor decays toward. A transaction cannot move it (it is promoted at the next block boundary),
    /// and one block can move it by at most `maxRefStep`, so a momentary price yank cannot become the
    /// decay target. Maintained in `afterSwap` by `_observeTick`.
    int24 public refTick;
    int24 internal curBlockTick; // running tick within the current block
    uint64 internal refBlock; // block `curBlockTick` belongs to
    /// @notice Max ticks `refTick` may advance per block toward the previous block's close. Owner-set
    /// within [1, ceiling]. Smaller = harder to poison but slower to track genuine moves.
    int24 public maxRefStep;
    int24 internal constant DEFAULT_MAX_REF_STEP = 200;
    int24 internal constant MAX_TICK_RATE_CEIL = 2000;

    /// @notice Lowest tick a backstop band may start at (raw; aligned up to `tickSpacing` when used).
    /// It jumps to one tick above any tick the pool trades at, immediately, because a higher floor only
    /// ever moves the bid to cheaper IMD. It comes back down only through `_updateDeploymentFloor`, at
    /// most `floorDecayTicksPerDay` toward `refTick + 1`. That asymmetry is the whole placement guard:
    /// a caller can push spot anywhere in one transaction, but relocating retained ETH to a level the
    /// market has not held costs `gap / floorDecayTicksPerDay` days of sustaining that price against
    /// every holder who wants to sell into it. Nothing lowers it faster; there is no owner reset.
    int24 public deploymentFloorTick;
    /// @notice How fast the floor may follow a genuine price recovery, in ticks per day. Owner-set within
    /// [1, `MAX_TICK_RATE_CEIL`]; a higher rate tracks recoveries sooner and shortens the holding period
    /// a manipulator must sustain. ~400 ticks ≈ 4% per day.
    uint256 public floorDecayTicksPerDay;
    uint256 internal constant DEFAULT_FLOOR_DECAY_PER_DAY = 400;
    /// @dev Clock and sub-tick remainder (tick·seconds) for the floor decay, same shape as the cap
    /// decay: fragments smaller than one tick still add up, so continuous trading cannot starve the decay
    /// by rounding, and the allowance is evaluated over at most one day so idle time is not banked.
    uint256 internal lastFloorDecayAt;
    uint256 internal floorDecayRemainder;

    // --- market state ------------------------------------------------------
    uint256 public inventoryCap;
    uint128 public positionLiquidity;
    uint256 public retainedEth;
    uint256 public totalBurned;
    uint256 public totalRewarded;
    bool public marketOpen;

    // --- deferred settlement ----------------------------------------------
    // v4 settles a swap only when the unlock closes, so while `afterSwap` runs the swapper's
    // tokens have not physically reached the PoolManager. `take` would move tokens that are not
    // there yet. Everything the cap removes is therefore claimed as ERC-6909 instead, and anyone
    // may convert those claims to real transfers afterwards via `settleClaims`.
    /// @notice Tokens owed to `burnSink`, held as claims until redeemed.
    uint256 public burnClaims;
    /// @notice Tokens owed to `rewardsRecipient`, held as claims until redeemed.
    uint256 public rewardClaims;
    /// @notice Recovered ETH still held as claims rather than as a real balance.
    uint256 public ethClaims;
    /// @dev Block in which claims were last added. Claims only become redeemable in a later block,
    /// because the swap that produced them settles when its own unlock closes.
    uint256 public lastClaimBlock;

    // --- trading-fee ledger -----------------------------------------------
    // The pool's 1% LP fee is the protocol's revenue. It is collected on every swap and held here,
    // fully separate from the burn/reward/retained ledgers, until the owner withdraws it. Kept as
    // ERC-6909 claims for the same deferred-settlement reason as the burn ledger.
    /// @notice Token-side trading fees held as claims, awaiting `withdrawFees`.
    uint256 public feeTokenClaims;
    /// @notice ETH-side trading fees held as claims, awaiting `withdrawFees`.
    uint256 public feeEthClaims;
    /// @notice Lifetime trading fees collected, for reporting (never decreases).
    uint256 public totalFeeToken;
    uint256 public totalFeeEth;

    uint8 private constant ACTION_OPEN = 1;
    uint8 private constant ACTION_REBALANCE = 2;
    uint8 private constant ACTION_CLOSE_BACKSTOP = 3;
    uint8 private constant ACTION_CLOSE_MARKET = 4;
    uint8 private constant ACTION_SETTLE_CLAIMS = 5;
    uint8 private constant ACTION_WITHDRAW_FEES = 6;
    uint8 private constant ACTION_SETTLE_ETH = 7;
    bool private _callbackExpected;

    constructor(
        address owner_,
        IPoolManager poolManager_,
        address token_,
        address burnSink_,
        address rewardsRecipient_,
        uint256 rewardShareBps_,
        uint256 minTrimTokens_,
        uint24 lpFee_,
        int24 tickSpacing_
    ) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || token_ == address(0)
                || burnSink_ == address(0) || rewardsRecipient_ == address(0) || rewardShareBps_ > MAX_REWARD_SHARE_BPS
                || lpFee_ > 1_000_000 || tickSpacing_ <= 0 || tickSpacing_ > TickMath.MAX_TICK_SPACING
        ) revert InvalidConfiguration();

        _initializeOwner(owner_);
        poolManager = poolManager_;
        token = token_;
        burnSink = burnSink_;
        rewardsRecipient = rewardsRecipient_;
        rewardShareBps = rewardShareBps_;
        minTrimTokens = minTrimTokens_;
        lpFee = lpFee_;
        tickSpacing = tickSpacing_;
        tickLower = TickMath.minUsableTick(tickSpacing_);
        tickUpper = TickMath.maxUsableTick(tickSpacing_);

        ratchetBps = BPS_DENOMINATOR;
        rebalanceEnabled = true;
        rebalanceEthThreshold = 0.1 ether;
        keeperReward = 0.002 ether; // small default tip; owner tunes (≤ threshold, ≤ MAX_KEEPER_REWARD)
        maxRefStep = DEFAULT_MAX_REF_STEP;
        floorDecayTicksPerDay = DEFAULT_FLOOR_DECAY_PER_DAY;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert InvalidPoolManagerCaller();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function poolKey() public view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    function currentSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId());
    }

    function currentTick() public view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId());
    }

    /// @notice Tokens held by the market position. The bid is accounted separately.
    function tokensInPool() public view returns (uint256) {
        if (positionLiquidity == 0) return 0;
        return SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(tickLower), currentSqrtPriceX96(), positionLiquidity, false
        );
    }

    /// @notice ETH held by the market position.
    function ethInPool() public view returns (uint256) {
        if (positionLiquidity == 0) return 0;
        return SqrtPriceMath.getAmount0Delta(
            currentSqrtPriceX96(), TickMath.getSqrtPriceAtTick(tickUpper), positionLiquidity, false
        );
    }

    function pendingTrim() public view returns (uint256) {
        uint256 held = tokensInPool();
        uint256 excess = held > inventoryCap ? held - inventoryCap : 0;
        // Mirror _applyCap: an excess below minTrimTokens is not trimmed by the next swap, so report 0.
        return excess < minTrimTokens ? 0 : excess;
    }

    /// @notice ETH principal the live backstop has actually converted into tokens at the current
    /// price. Accrued LP fees are separate and are not included. At the exact lower boundary this is
    /// zero apart from at most rounding dust, unlike a tick-only fill predicate.
    function backstopConvertedEth() public view returns (uint256 converted) {
        Band memory b = backstop;
        uint256 principal = backstopEthPrincipal;
        if (b.liquidity == 0 || principal == 0) return 0;

        uint160 sqrtPriceX96 = currentSqrtPriceX96();
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(b.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(b.tickUpper);
        uint256 ethRemaining;

        if (sqrtPriceX96 <= sqrtLowerX96) {
            ethRemaining = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, b.liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            ethRemaining = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, b.liquidity, false);
        }

        // Adding liquidity rounds principal up while removing it rounds down, so an untouched band may
        // differ by a wei. The material-fill threshold below makes that dust non-rewardable.
        return principal > ethRemaining ? principal - ethRemaining : 0;
    }

    /// @notice Minimum converted ETH that makes the current backstop permissionlessly settleable.
    /// A band smaller than the global threshold must be fully converted rather than becoming stuck.
    function backstopFillThreshold() public view returns (uint256) {
        uint256 principal = backstopEthPrincipal;
        if (principal == 0) return 0;
        uint256 threshold = rebalanceEthThreshold;
        return threshold < principal ? threshold : principal;
    }

    /// @notice True only after a material amount of backstop principal has converted into tokens.
    function backstopIsFilled() public view returns (bool) {
        uint256 threshold = backstopFillThreshold();
        return threshold != 0 && backstopConvertedEth() >= threshold;
    }

    // -------------------------------------------------------------------------
    // Policy
    // -------------------------------------------------------------------------

    /// @notice Sets the floor the cap may never ratchet below.
    function setCapFloor(uint256 newFloor) external onlyOwner {
        emit CapFloorUpdated(capFloor, newFloor);
        capFloor = newFloor;
        if (inventoryCap < newFloor) inventoryCap = newFloor;
    }

    /// @notice Configures the keeper backstop rebalance: kill switch + the "worth a poke" ETH floor.
    function setRebalance(bool enabled, uint256 ethThreshold) external onlyOwner {
        // Keep the useful-work threshold strictly above the flat reward. Equality could consume the
        // entire qualifying idle balance without deploying any backstop liquidity.
        if (ethThreshold == 0 || ethThreshold <= keeperReward) revert InvalidConfiguration();
        rebalanceEnabled = enabled;
        rebalanceEthThreshold = ethThreshold;
        emit RebalanceConfigUpdated(enabled, ethThreshold);
    }

    /// @notice Sets the maximum ETH tip for permissionless keeper work. Actual payment is additionally
    /// bounded by `lpFee` applied to measured idle/converted ETH. `0` turns tipping off.
    function setKeeperReward(uint256 reward) external onlyOwner {
        if (reward > MAX_KEEPER_REWARD || reward >= rebalanceEthThreshold) revert InvalidConfiguration();
        keeperReward = reward;
        emit KeeperRewardUpdated(reward);
    }

    /// @notice Tunes how far `refTick` may advance per block toward the previous block's close. Lower =
    /// the reference is harder to poison (a distant move takes more blocks) but tracks genuine price moves
    /// more slowly; bounded so it can never be set to jump arbitrarily far in one block.
    function setMaxRefStep(int24 maxStep) external onlyOwner {
        if (maxStep <= 0 || maxStep > MAX_TICK_RATE_CEIL) revert InvalidConfiguration();
        maxRefStep = maxStep;
        emit MaxRefStepUpdated(maxStep);
    }

    /// @notice Sets how fast the placement floor may follow a price recovery, in ticks per day. Bounded
    /// away from zero (a frozen floor would strand the backstop above every recovery with no way back)
    /// and from above (a floor that can drop thousands of ticks a day is a block-paced follower again).
    function setFloorDecay(uint256 ticksPerDay) external onlyOwner {
        if (ticksPerDay == 0 || ticksPerDay > uint256(uint24(MAX_TICK_RATE_CEIL))) revert InvalidConfiguration();
        // Re-seat the clock so the new rate paces from now, as setCapDecay does for the cap.
        lastFloorDecayAt = block.timestamp;
        floorDecayRemainder = 0;
        floorDecayTicksPerDay = ticksPerDay;
        emit FloorDecayUpdated(ticksPerDay);
    }

    /// @notice Sets how fast the cap may ratchet down, in tokens per day.
    function setCapDecay(uint256 tokensPerDay) external onlyOwner {
        if (tokensPerDay > MAX_CAP_DECAY_PER_DAY) revert InvalidConfiguration();
        // Re-seat the clock so the new rate paces from now on. Without this, the whole idle backlog
        // accrued under the old rate would be spendable at the new rate on the very next ratchet.
        lastCapDecayAt = block.timestamp;
        capDecayRemainder = 0;
        capDecayTokensPerDay = tokensPerDay;
        emit CapDecayUpdated(tokensPerDay);
    }

    function setRatchetBps(uint256 newRatchetBps) external onlyOwner {
        if (newRatchetBps > BPS_DENOMINATOR) revert InvalidConfiguration();
        emit RatchetUpdated(ratchetBps, newRatchetBps);
        ratchetBps = newRatchetBps;
    }

    /// @notice Redirects the burn destination for future trims.
    /// @dev Only future settlements are affected; already-accrued `burnClaims` settle to whatever
    /// `burnSink` is at settlement time, so `settleClaims()` first if the old sink must receive them.
    function setBurnSink(address newBurnSink) external onlyOwner {
        if (newBurnSink == address(0)) revert InvalidConfiguration();
        emit BurnSinkUpdated(burnSink, newBurnSink);
        burnSink = newBurnSink;
    }

    /// @notice Redirects the reward-share destination (e.g. to a new staking dripper) for future trims.
    /// @dev Only future settlements are affected; already-accrued `rewardClaims` settle to whatever
    /// `rewardsRecipient` is at settlement time, so `settleClaims()` first if the old recipient must
    /// receive them.
    function setRewardsRecipient(address newRewardsRecipient) external onlyOwner {
        if (newRewardsRecipient == address(0)) revert InvalidConfiguration();
        emit RewardsRecipientUpdated(rewardsRecipient, newRewardsRecipient);
        rewardsRecipient = newRewardsRecipient;
    }

    /// @notice Tunes the burn/reward split — the share of each trim skimmed to `rewardsRecipient` instead
    /// of burned (e.g. 2000 = 20% reward / 80% burn). Capped at `MAX_REWARD_SHARE_BPS` (30%) so burning
    /// always dominates and no owner can turn the deflation off or redirect the whole trim. Only future
    /// trims are affected; `settleClaims()` first to settle already-accrued claims under the old split.
    function setRewardShareBps(uint256 bps) external onlyOwner {
        if (bps > MAX_REWARD_SHARE_BPS) revert InvalidConfiguration();
        emit RewardShareUpdated(rewardShareBps, bps);
        rewardShareBps = bps;
    }

    // -------------------------------------------------------------------------
    // Launch and teardown
    // -------------------------------------------------------------------------

    function initializePool(uint160 sqrtPriceX96) external onlyOwner {
        int24 tick = poolManager.initialize(poolKey(), sqrtPriceX96);
        emit PoolInitialized(sqrtPriceX96, tick);
    }

    /// @notice Adds the market position and freezes the starting cap at the tokens deposited.
    /// @dev Send at least the ETH v4 requires; the surplus is refunded.
    function openMarket(uint128 liquidity, uint256 maximumTokenAmount, uint256 capFloor_, uint256 capDecayTokensPerDay_)
        external
        payable
        onlyOwner
    {
        if (marketOpen) revert AlreadyOpen();
        if (liquidity == 0) revert InvalidLiquidity();
        if (capDecayTokensPerDay_ > MAX_CAP_DECAY_PER_DAY) revert InvalidConfiguration();
        if (currentSqrtPriceX96() == 0) revert PoolNotInitialized();

        bytes memory result =
            _unlock(abi.encode(ACTION_OPEN, abi.encode(msg.sender, liquidity, msg.value, maximumTokenAmount)));
        (uint256 ethDeposited, uint256 tokensDeposited) = abi.decode(result, (uint256, uint256));

        marketOpen = true;
        positionLiquidity = liquidity;
        refTick = currentTick(); // seed the rebalance reference at the opening price
        curBlockTick = currentTick();
        refBlock = uint64(block.number);
        deploymentFloorTick = _tickAbove(currentTick());
        lastFloorDecayAt = block.timestamp;
        floorDecayRemainder = 0;
        inventoryCap = tokensDeposited;
        capFloor = capFloor_;
        // Keep inventoryCap >= capFloor at open, exactly as setCapFloor does. Without this, a
        // capFloor_ above the deposited inventory opens the market already violating the invariant,
        // leaving capFloor dead: it neither raises the cap nor gates the ratchet.
        if (inventoryCap < capFloor_) inventoryCap = capFloor_;
        capDecayTokensPerDay = capDecayTokensPerDay_;
        // Reseat the decay clock and clear any carried remainder, the same reset setCapDecay and
        // fundInventory perform. On a fresh deploy the remainder is already zero; this matters only if
        // a closed market is ever reopened, so it inherits no stale sub-quantum decay debt.
        lastCapDecayAt = block.timestamp;
        capDecayRemainder = 0;
        if (msg.value > ethDeposited) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethDeposited);
        emit MarketOpened(liquidity, ethDeposited, tokensDeposited);
    }

    /// @notice Adds inventory to a shrunken market and raises the cap to match.
    /// @dev The counterpart to the ratchet. Without this the cap only ever falls, so a market that
    /// has burned its way down can never be re-seeded without closing and redeploying. Liquidity is
    /// proportional, so this consumes both tokens and ETH; send at least what v4 asks for and the
    /// surplus is refunded.
    function fundInventory(uint128 liquidity, uint256 maximumTokenAmount) external payable onlyOwner {
        if (!marketOpen) revert MarketNotOpen();
        if (liquidity == 0) revert InvalidLiquidity();

        bytes memory result =
            _unlock(abi.encode(ACTION_OPEN, abi.encode(msg.sender, liquidity, msg.value, maximumTokenAmount)));
        (uint256 ethDeposited, uint256 tokensDeposited) = abi.decode(result, (uint256, uint256));

        positionLiquidity += liquidity;
        inventoryCap += tokensDeposited;
        // Re-seat the decay clock the way openMarket does. Without this, allowance accrued while the
        // market sat at the old (smaller) cap would apply to the freshly funded inventory, letting
        // one swap ratchet the re-seeded tokens straight back down toward capFloor.
        lastCapDecayAt = block.timestamp;
        capDecayRemainder = 0;
        if (msg.value > ethDeposited) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethDeposited);
        emit InventoryFunded(liquidity, ethDeposited, tokensDeposited, inventoryCap);
    }

    /// @notice Withdraws the market position and any live bid, returning both legs to `recipient`.
    ///
    /// @dev Deliberately unrestricted, and deliberately the one privileged escape hatch. The hook
    /// holds the protocol's entire market position inside a v4 pool it cannot upgrade: if a defect
    /// is found in the cap, ladder or claim accounting, or in the PoolManager itself, this is the
    /// only way to move funds to safety and redeploy. Gating it on exhaustion or a timelock would
    /// make it useless in precisely the situation it exists for.
    ///
    /// The trade is explicit and must be disclosed: the owner can withdraw the entire position at
    /// any moment, including from a healthy market. Holders are trusting the owner not to, not the
    /// contract to prevent it. Mitigation belongs at the ownership layer - a multisig or timelocked
    /// owner - not in this function.
    ///
    /// Terminal: `marketOpen` cannot return to true, so a closed market is redeployed, not reopened.
    function closeMarket(address recipient) external onlyOwner {
        if (!marketOpen) revert MarketNotOpen();
        if (recipient == address(0)) revert InvalidConfiguration();
        // Escape-hatch resilience: a stuck claim (e.g. a blacklisting token to burnSink/rewardsRecipient)
        // must not brick this recovery. Settle best-effort, and cap the final ETH payout at the balance
        // actually held so an unredeemed ETH claim cannot revert the withdrawal of the position itself.
        try this.settleClaims() {} catch {}

        try this.closeBackstopSelf() {} catch {} // wrapped so a close revert can't brick the recovery

        try this.settleClaims() {} catch {} // unwinding the backstop may have claimed more
        // Guarantee the retained ETH is realised even if a blacklisting token reverted the settles above
        // (F5): the ETH-only settle can never be blocked by a token, so retainedEth is fully backed by
        // real balance before the payout — no orphaned ETH.
        try this.settleEthClaims() {} catch {}
        bytes memory result = _unlock(abi.encode(ACTION_CLOSE_MARKET, abi.encode(recipient)));
        (uint256 ethOut, uint256 tokensOut) = abi.decode(result, (uint256, uint256));

        marketOpen = false;
        positionLiquidity = 0;

        uint256 ethToSend = ethOut + retainedEth;
        retainedEth = 0;
        uint256 bal = address(this).balance;
        if (ethToSend > bal) ethToSend = bal;
        if (ethToSend != 0) SafeTransferLib.safeTransferETH(recipient, ethToSend);
        emit MarketClosed(recipient, ethToSend, tokensOut);
    }

    function withdrawRetainedEth(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        if (amount == 0 || amount > retainedEth) revert InvalidConfiguration();
        try this.settleClaims() {} catch {} // a stuck claim must not block a retained-ETH withdrawal
        try this.settleEthClaims() {} catch {} // and realise the ETH leg even if a token settle reverted (F5)
        retainedEth -= amount;
        SafeTransferLib.safeTransferETH(recipient, amount);
        emit RetainedEthWithdrawn(recipient, amount);
    }

    /// @notice Sends the accumulated trading-fee revenue (token + ETH) to `recipient`. The fee ledger
    /// is entirely separate from the burn/reward/retained ledgers, so this touches nothing else.
    function withdrawFees(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        if (feeTokenClaims == 0 && feeEthClaims == 0) return;
        _unlock(abi.encode(ACTION_WITHDRAW_FEES, abi.encode(recipient)));
    }

    // -------------------------------------------------------------------------
    // Backstop
    // -------------------------------------------------------------------------

    /// @notice Permissionless keeper entry, and the only rebalance path (the owner uses it too). It runs
    /// only when idle retained ETH reaches the configured threshold or the live backstop has materially
    /// converted principal into tokens. Idle ETH cannot re-qualify: a rebalance deploys all of it, so
    /// the gate is only re-armed by fresh trims (or an owner `closeBackstop`, which is real work).
    /// Every deployment is floored at `deploymentFloorTick`, so nothing a caller does to spot in this
    /// transaction can relocate retained ETH below a level the market has held.
    function rebalance() external {
        if (!marketOpen) revert MarketNotOpen();
        uint256 idle = retainedEth;
        uint256 converted = backstopConvertedEth();
        bool idleReady = idle >= rebalanceEthThreshold;
        if (!idleReady && !_materiallyFilled(converted)) revert RebalanceNotNeeded();

        // The configured reward is a ceiling, not an unconditional flat payment. Both idle deployment
        // and fill settlement are bounded by the pool fee on measured work, so manufacturing either
        // trigger cannot earn more than the fee paid to create it.
        uint256 tip = _keeperRewardDue(idleReady ? idle : 0, converted);
        if (_rebalanceGuarded(tip) && tip != 0) _payKeeper(msg.sender, tip);
    }

    /// @notice Closes the backstop by hand: the tokens it bought are burned, its ETH returns to
    /// `retainedEth`. Removing liquidity is price-neutral, so this needs no reference guard.
    function closeBackstop() external onlyOwner {
        if (backstop.liquidity == 0) return;
        _unlock(abi.encode(ACTION_CLOSE_BACKSTOP, bytes("")));
    }

    /// @notice Whether a keeper `rebalance()` would currently do useful work. The checker for an
    /// automation task: call `rebalance()` whenever this is true.
    function pendingRebalance() external view returns (bool) {
        if (!rebalanceEnabled || !marketOpen || positionLiquidity == 0) return false;
        return retainedEth >= rebalanceEthThreshold || _materiallyFilled(backstopConvertedEth());
    }

    /// @dev Brings the placement floor up to date, then deploys the band no lower than it. Live spot only
    /// ever pushes the band UP (the safe direction); the floor is what stops it going down.
    function _rebalanceGuarded(uint256 rewardHoldback) internal returns (bool worked) {
        if (!rebalanceEnabled) revert RebalanceDisabled();
        int24 spot = currentTick();
        _updateDeploymentFloor(spot);
        int24 lower = spot + 1;
        if (lower < deploymentFloorTick) lower = deploymentFloorTick;
        lower = _alignUp(lower);
        bytes memory res = _unlock(abi.encode(ACTION_REBALANCE, abi.encode(lower, rewardHoldback)));
        return abi.decode(res, (bool));
    }

    function _materiallyFilled(uint256 converted) internal view returns (bool) {
        uint256 threshold = backstopFillThreshold();
        return threshold != 0 && converted >= threshold;
    }

    /// @dev The keeper tip for an already-qualified rebalance. The configured flat value is only a
    /// ceiling: actual payment is capped by the LP fee on measured useful work. This makes a
    /// self-manufactured idle balance or fill fee-dominated even before gas, and safely reduces the tip
    /// to zero for a zero-fee pool.
    function _keeperRewardDue(uint256 qualifyingIdleEth, uint256 converted) internal view returns (uint256) {
        if (keeperReward == 0 || !rebalanceEnabled) return 0;
        if (positionLiquidity == 0) return 0; // degenerate (capFloor==0): _rebalanceTo no-ops, so no tip

        uint256 workValue = converted;
        if (qualifyingIdleEth > workValue) workValue = qualifyingIdleEth;
        uint256 feeBound = workValue.fullMulDiv(lpFee, FEE_DENOMINATOR);
        return feeBound < keeperReward ? feeBound : keeperReward;
    }

    /// @dev Pays the held-back keeper tip out of retained ETH, CEI-safe: realise the ETH, debit the
    /// backing, then transfer last. Capped at `retainedEth` so it can never over-pay.
    function _payKeeper(address keeper, uint256 reward) internal {
        if (reward > retainedEth) reward = retainedEth;
        if (reward == 0) return;
        settleEthClaims(); // realise ETH so a real transfer is funded (no-op if already realised)
        retainedEth -= reward;
        emit KeeperRewardPaid(keeper, reward);
        SafeTransferLib.safeTransferETH(keeper, reward);
    }

    /// @dev Settles the current backstop (burning what it bought), then redeploys all retained ETH as
    /// one fresh single-sided band with lower tick `lower` (computed by `_rebalanceGuarded`). Runs
    /// inside an unlock.
    function _rebalanceTo(int24 lower, uint256 rewardHoldback) internal returns (bool worked) {
        if (positionLiquidity == 0) return false;
        bool closed = _closeBackstop(); // re-credits the old band's ETH into retainedEth
        // Hold back the keeper tip (capped at what's actually retained) so the deploy leaves it behind;
        // `_payKeeper` transfers it after the unlock closes.
        uint256 hold = rewardHoldback;
        if (hold > retainedEth) hold = retainedEth;
        uint256 ethUsed = _deployBackstop(retainedEth - hold, lower);
        emit Rebalanced(lower);
        // "Worked" = something actually happened (a band was closed or ETH was deployed). A pure no-op
        // (nothing to close and nothing deployable — e.g. lower >= tickUpper) earns no keeper tip.
        return closed || ethUsed != 0;
    }

    /// @dev Removes the whole backstop: its ETH accrues to `retainedEth`, the tokens it bought are
    /// burned. Removing liquidity is not a swap, so the price is untouched.
    function _closeBackstop() internal returns (bool) {
        Band memory b = backstop;
        if (b.liquidity == 0) return false;
        uint160 priceBefore = currentSqrtPriceX96();

        // Route the backstop's own LP fees to the fee ledger first, so the removal below returns pure
        // principal (the tokens the backstop bought), which is what gets burned.
        _collectFees(b.tickLower, b.tickUpper);
        (uint256 ethOut, uint256 tokensOut) = _removeLiquidity(b.tickLower, b.tickUpper, b.liquidity);
        delete backstop;
        backstopEthPrincipal = 0;

        _claimEth(ethOut);
        (uint256 burned, uint256 rewarded) = _disperse(tokensOut);

        _requirePriceUnchanged(priceBefore);
        emit BackstopSettled(b.liquidity, burned, rewarded, ethOut);
        return true;
    }

    /// @dev Deploys `ethAmount` of retained ETH as one single-sided ETH band `[lower, tickUpper]`, and
    /// returns the ETH actually consumed (0 on a no-op). The caller (`_rebalanceGuarded`) has already
    /// floored `lower` at the reference, so this never prices off unclamped live spot. Whatever the
    /// inversion cannot place stays in `retainedEth`.
    function _deployBackstop(uint256 ethAmount, int24 lower) internal returns (uint256) {
        if (ethAmount == 0) return 0;
        if (lower >= tickUpper) return 0;

        (uint128 liquidity, uint256 ethUsed) = _addBandLiquidity(lower, tickUpper, ethAmount);
        backstop = Band({tickLower: lower, tickUpper: tickUpper, liquidity: liquidity});
        backstopEthPrincipal = ethUsed;
        emit BackstopDeployed(lower, tickUpper, liquidity, ethUsed);
        return ethUsed;
    }

    /// @dev Adds single-sided ETH over `[lower, upper]`. Must run inside an unlock. Reverts unless
    /// the range sits entirely above the current price, the invariant that makes it cost no tokens.
    function _addBandLiquidity(int24 lower, int24 upper, uint256 ethAmount)
        internal
        returns (uint128 liquidity, uint256 ethUsed)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);

        // Invert amount0 = L * (sqrtB - sqrtA) * 2^96 / (sqrtA * sqrtB) for L.
        uint256 product = uint256(sqrtLower).fullMulDiv(uint256(sqrtUpper), 1 << 96);
        uint256 computed = ethAmount.fullMulDiv(product, uint256(sqrtUpper) - uint256(sqrtLower));
        if (computed == 0 || computed > type(uint128).max) revert InvalidLiquidity();
        liquidity = uint128(computed);

        uint160 priceBefore = currentSqrtPriceX96();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey(),
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        if (delta.amount0() > 0 || delta.amount1() > 0) revert UnexpectedLiquidityDelta();

        ethUsed = uint256(-int256(delta.amount0()));
        uint256 tokensRequired = uint256(-int256(delta.amount1()));
        if (tokensRequired != 0) revert BidNotSingleSided(tokensRequired);
        if (ethUsed > ethAmount) revert IncorrectEthAmount(ethUsed, ethAmount);
        _payEth(ethUsed);
        _requirePriceUnchanged(priceBefore);
        retainedEth -= ethUsed;
    }

    /// @dev Settles an ETH debit from claims first, then from the real balance.
    function _payEth(uint256 amount) internal {
        if (amount == 0) return;
        uint256 fromClaims = amount < ethClaims ? amount : ethClaims;
        if (fromClaims != 0) {
            ethClaims -= fromClaims;
            poolManager.burn(address(this), _currencyId(address(0)), fromClaims);
        }
        uint256 rest = amount - fromClaims;
        if (rest != 0) poolManager.settle{value: rest}();
    }

    function _alignUp(int24 tick) internal view returns (int24) {
        int24 aligned = (tick / tickSpacing) * tickSpacing;
        if (aligned < tick) aligned += tickSpacing;
        return aligned;
    }

    /// @dev The tick strictly above `tick`, capped at the market position's upper bound so a band at the
    /// extreme degrades to a no-op deploy rather than an invalid range.
    function _tickAbove(int24 tick) internal view returns (int24 above) {
        above = tick + 1;
        if (above > tickUpper) above = tickUpper;
    }

    /// @dev Moves the placement floor. Up: instantly, to one tick above any observed tick (a higher floor
    /// only ever moves the bid to cheaper IMD, so it may follow spot at once). Down: toward `refTick + 1`
    /// at most `floorDecayTicksPerDay`, paced by wall-clock time. Down is the only direction a
    /// manipulated placement needs, so it is the only one that costs time: dragging the floor D ticks
    /// below fair means sustaining a false price for D / floorDecayTicksPerDay days, exposed to every
    /// seller the whole way. Evaluated on every swap and every rebalance. Elapsed time is clipped to one
    /// day so an idle stretch cannot be spent in one step, and the sub-tick remainder is carried so
    /// per-block fragments (a fraction of a tick each) still add up under continuous trading.
    function _updateDeploymentFloor(int24 observedTick) internal {
        int24 previous = deploymentFloorTick;
        int24 floor = previous;
        uint256 elapsed = block.timestamp - lastFloorDecayAt;
        if (elapsed != 0) {
            lastFloorDecayAt = block.timestamp;
            int24 target = _tickAbove(refTick);
            if (target < floor) {
                if (elapsed > 1 days) elapsed = 1 days;
                uint256 numerator = floorDecayTicksPerDay * elapsed + floorDecayRemainder;
                uint256 allowed = numerator / 1 days; // <= floorDecayTicksPerDay
                floorDecayRemainder = numerator % 1 days;
                uint256 gap = uint256(int256(floor) - int256(target));
                floor = allowed >= gap ? target : floor - int24(int256(allowed));
            } else {
                floorDecayRemainder = 0; // nothing to decay toward: the allowance is not banked
            }
        }
        int24 raise = _tickAbove(observedTick);
        if (raise > floor) floor = raise;
        if (floor != previous) {
            deploymentFloorTick = floor;
            emit DeploymentFloorUpdated(previous, floor);
        }
    }

    // -------------------------------------------------------------------------
    // Hooks
    // -------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Restricts pool initialization to this hook, i.e. to the owner via `initializePool`.
    /// @dev `PoolManager.initialize` is otherwise permissionless, and this hook's pool key is fixed
    /// entirely by its immutables, so without this guard anyone could front-run the owner and stamp
    /// a launch price of their choosing into the single pool this hook can ever use. When the owner
    /// calls `initializePool`, the hook is the caller of `poolManager.initialize`, so `sender` is
    /// this contract; a direct external `initialize` presents any other `sender` and is rejected.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert InitializationRestrictedToHook();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert LiquidityRestrictedToHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Applies the cap, then rebalances the backstop. Declares no delta, so the swap the
    /// router quoted is exactly the swap the trader gets.
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _requirePoolManagerAndPool(key);
        _maybeRedeemMaturedClaims();
        // Realise this swap's LP fee into the fee ledger BEFORE the cap runs. Collecting every swap
        // means each collection is exactly this trade's fee, and it also leaves the position with no
        // accrued fees for the trim below to fold into principal.
        if (positionLiquidity != 0) _collectFees(tickLower, tickUpper);
        // The cap is the load-bearing invariant, left unwrapped. The backstop rebalance is no longer on
        // the swap path at all — a keeper drives it (`rebalance()`) off a manipulation-resistant
        // reference — so nothing here prices off live spot.
        _applyCap();
        // Load-bearing placement floor: raised here, before the swap's PoolManager unlock can finish, so a
        // later rebalance cannot forget an upward price the pool just observed; decayed here too, so it
        // follows a genuine recovery without anyone having to poke it. Runs before `_observeTick` so the
        // decay target is the previous block's reference, which this transaction cannot have moved.
        _updateDeploymentFloor(currentTick());
        _observeTick(); // maintain the block-lagged reference; no backstop touch on this path
        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @dev Advances `refTick` toward the previous block's closing tick, by at most `maxRefStep` (the
    /// rebalance reference the current transaction cannot influence), then records this swap's tick as the
    /// running block tick. Rate-limiting the step bounds how far one manipulated block can drag the
    /// reference — a distant poison then costs many consecutive block-edge captures. Pure snapshot — no
    /// liquidity op, no external call.
    function _observeTick() internal {
        if (block.number != refBlock) {
            int24 target = curBlockTick;
            int24 step = maxRefStep;
            int24 delta = target - refTick; // both are valid ticks; diff fits in int24
            if (delta > step) target = refTick + step;
            else if (delta < -step) target = refTick - step;
            refTick = target; // stays a valid tick: |target - refTick| <= |curBlockTick - refTick|
            refBlock = uint64(block.number);
        }
        curBlockTick = currentTick();
    }

    // -------------------------------------------------------------------------
    // Cap
    // -------------------------------------------------------------------------

    /// @dev Runs inside the PoolManager's existing swap unlock; it must not call `unlock` again.
    function _applyCap() internal {
        uint128 liquidity = positionLiquidity;
        if (liquidity == 0) return;

        uint160 priceBefore = currentSqrtPriceX96();
        uint256 held =
            SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), priceBefore, liquidity, false);

        if (held < inventoryCap) {
            // A buy opened room under the cap. Give back `ratchetBps` of it, but never faster than
            // the daily decay allowance and never below the floor.
            uint256 next = inventoryCap - ((inventoryCap - held) * ratchetBps) / BPS_DENOMINATOR;

            uint256 elapsed = block.timestamp - lastCapDecayAt;
            uint256 allowance = (capDecayTokensPerDay * elapsed) / 1 days;
            uint256 rateFloor = inventoryCap > allowance ? inventoryCap - allowance : 0;
            if (next < rateFloor) next = rateFloor;
            if (next < capFloor) next = capFloor;

            if (next < inventoryCap) {
                uint256 used = inventoryCap - next;
                // Advance the clock by the exact time-equivalent of the tokens spent:
                // used * 1 days / capDecayTokensPerDay, carrying the sub-quantum remainder. The old
                // form `(elapsed * used) / allowance` floored every ratchet independently, so a
                // ratchet smaller than one clock-second of allowance advanced the clock by zero
                // while still lowering the cap - letting many tiny ratchets bypass the rate limit.
                // The carried remainder guarantees total decay over any window stays within
                // capDecayTokensPerDay no matter how the reduction is fragmented.
                if (capDecayTokensPerDay != 0) {
                    uint256 numerator = used * 1 days + capDecayRemainder;
                    lastCapDecayAt += numerator / capDecayTokensPerDay;
                    capDecayRemainder = numerator % capDecayTokensPerDay;
                }
                emit CapRatcheted(inventoryCap, next);
                inventoryCap = next;
            }
            return;
        }

        uint256 excess = held - inventoryCap;
        if (excess == 0 || excess < minTrimTokens) return;

        // Withdrawals are proportional at a fixed price, so removing this share removes `excess`
        // tokens and leaves the position at the cap. The division rounds down, so a wei-scale
        // residue can sit above the cap; that rounds in the pool's favour and does not compound.
        uint256 liquidityToRemove = FixedPointMathLib.fullMulDiv(liquidity, excess, held);
        if (liquidityToRemove == 0) return;

        (uint256 ethRemoved, uint256 tokensRemoved) = _removeLiquidity(tickLower, tickUpper, liquidityToRemove);
        positionLiquidity = liquidity - uint128(liquidityToRemove);

        _claimEth(ethRemoved);
        (uint256 burned, uint256 rewarded) = _disperse(tokensRemoved);

        _requirePriceUnchanged(priceBefore);
        emit Trimmed(uint128(liquidityToRemove), burned, rewarded, ethRemoved);
    }

    function _removeLiquidity(int24 lower, int24 upper, uint256 liquidity)
        internal
        returns (uint256 ethOut, uint256 tokensOut)
    {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey(),
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: -int256(liquidity),
                salt: bytes32(0)
            }),
            bytes("")
        );
        if (delta.amount0() < 0 || delta.amount1() < 0) revert UnexpectedLiquidityDelta();
        ethOut = uint256(int256(delta.amount0()));
        tokensOut = uint256(int256(delta.amount1()));
    }

    /// @dev Claims the tokens leaving the pool, splitting them between the sink and the rewards
    /// recipient. Counted as burned immediately; the physical transfer happens on `settleClaims`.
    function _disperse(uint256 tokensRemoved) internal returns (uint256 burned, uint256 rewarded) {
        if (tokensRemoved == 0) return (0, 0);
        rewarded = FixedPointMathLib.fullMulDiv(tokensRemoved, rewardShareBps, BPS_DENOMINATOR);
        burned = tokensRemoved - rewarded;
        poolManager.mint(address(this), _currencyId(token), tokensRemoved);
        lastClaimBlock = block.number;
        totalRewarded += rewarded;
        rewardClaims += rewarded;
        totalBurned += burned;
        burnClaims += burned;
    }

    function _claimEth(uint256 amount) internal {
        if (amount == 0) return;
        poolManager.mint(address(this), _currencyId(address(0)), amount);
        lastClaimBlock = block.number;
        ethClaims += amount;
        retainedEth += amount;
    }

    /// @dev Converts outstanding claims into real transfers. Must run inside an unlock.
    function _redeemClaims() internal {
        uint256 toBurn = burnClaims;
        uint256 toReward = rewardClaims;
        uint256 toEth = ethClaims;
        uint256 tokens = toBurn + toReward;
        if (tokens != 0) {
            burnClaims = 0;
            rewardClaims = 0;
            poolManager.burn(address(this), _currencyId(token), tokens);
            if (toReward != 0) poolManager.take(Currency.wrap(token), rewardsRecipient, toReward);
            if (toBurn != 0) poolManager.take(Currency.wrap(token), burnSink, toBurn);
        }
        if (toEth != 0) {
            ethClaims = 0;
            poolManager.burn(address(this), _currencyId(address(0)), toEth);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), toEth);
        }
        if (tokens != 0 || toEth != 0) emit ClaimsSettled(toBurn, toReward, toEth);
    }

    /// @dev The ETH leg of `_redeemClaims`, standalone. `take` to `address(this)` (via the PM-only
    /// `receive()`) can never be blocked by a token, so this always succeeds — it is the escape hatch's
    /// guarantee that a blacklisting/reverting token cannot strand retained ETH. Must run inside unlock.
    function _redeemEthClaims() internal {
        uint256 toEth = ethClaims;
        if (toEth == 0) return;
        ethClaims = 0;
        poolManager.burn(address(this), _currencyId(address(0)), toEth);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), toEth);
        emit ClaimsSettled(0, 0, toEth);
    }

    /// @dev Realises the fee ledger into real transfers to `recipient`. Must run inside an unlock.
    /// Fee claims are only ever minted by a prior transaction's swap, so they are always fully backed
    /// by the time this owner call runs.
    function _withdrawFees(address recipient) internal {
        uint256 tokenAmount = feeTokenClaims;
        uint256 ethAmount = feeEthClaims;
        if (tokenAmount != 0) {
            feeTokenClaims = 0;
            poolManager.burn(address(this), _currencyId(token), tokenAmount);
            poolManager.take(Currency.wrap(token), recipient, tokenAmount);
        }
        if (ethAmount != 0) {
            feeEthClaims = 0;
            poolManager.burn(address(this), _currencyId(address(0)), ethAmount);
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, ethAmount);
        }
        emit FeesWithdrawn(recipient, tokenAmount, ethAmount);
    }

    function _currencyId(address currency) internal pure returns (uint256) {
        return uint256(uint160(currency));
    }

    /// @notice Redeem entry point for the automatic path. Self-only, and always wrapped in
    /// try/catch so realising a burn can never revert somebody's trade.
    function redeemClaimsSelf() external {
        if (msg.sender != address(this)) revert NotSelf();
        _redeemClaims();
    }

    /// @notice Self-only backstop close, so `closeMarket` can unwind the band in a try/catch and keep the
    /// escape hatch's defensive posture: a revert here recovers the main position + retained ETH anyway,
    /// leaving the band for a later `closeBackstop()`, instead of bricking the whole recovery.
    function closeBackstopSelf() external {
        if (msg.sender != address(this)) revert NotSelf();
        if (backstop.liquidity == 0) return;
        _unlock(abi.encode(ACTION_CLOSE_BACKSTOP, bytes("")));
    }

    /// @dev Realises claims left by an earlier block. Claims minted in this block are skipped: the
    /// tokens backing them have not reached the PoolManager yet, and several swaps can share one
    /// transaction.
    function _maybeRedeemMaturedClaims() internal {
        if (block.number <= lastClaimBlock) return;
        if (burnClaims == 0 && rewardClaims == 0 && ethClaims == 0) return;
        try this.redeemClaimsSelf() {} catch {}
    }

    /// @notice Converts everything the cap has claimed into real transfers. Permissionless: the
    /// anyone may push it through; it always pays the current burnSink/rewardsRecipient (owner-settable).
    function settleClaims() public {
        if (burnClaims == 0 && rewardClaims == 0 && ethClaims == 0) return;
        _unlock(abi.encode(ACTION_SETTLE_CLAIMS, bytes("")));
    }

    /// @notice Realises only the ETH claims into real balance — used as the escape hatch's fallback so a
    /// stuck token settlement (blacklisting sink) can never strand retained ETH. Permissionless.
    function settleEthClaims() public {
        if (ethClaims == 0) return;
        _unlock(abi.encode(ACTION_SETTLE_ETH, bytes("")));
    }

    function _requirePriceUnchanged(uint160 priceBefore) internal view {
        uint160 priceAfter = currentSqrtPriceX96();
        if (priceAfter != priceBefore) revert PriceMovedDuringLiquidityChange(priceBefore, priceAfter);
    }

    // -------------------------------------------------------------------------
    // Unlock plumbing
    // -------------------------------------------------------------------------

    function _unlock(bytes memory data) internal returns (bytes memory) {
        _callbackExpected = true;
        return poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidPoolManagerCaller();
        if (!_callbackExpected) revert CallbackNotExpected();
        _callbackExpected = false;

        (uint8 action, bytes memory payload) = abi.decode(rawData, (uint8, bytes));

        if (action == ACTION_OPEN) {
            (address payer, uint128 liquidity, uint256 suppliedEth, uint256 maxTokens) =
                abi.decode(payload, (address, uint128, uint256, uint256));
            return _addPosition(payer, tickLower, tickUpper, liquidity, suppliedEth, maxTokens);
        }
        if (action == ACTION_SETTLE_ETH) {
            _redeemEthClaims();
            return "";
        }
        if (action == ACTION_SETTLE_CLAIMS) {
            _redeemClaims();
            return "";
        }
        if (action == ACTION_WITHDRAW_FEES) {
            _withdrawFees(abi.decode(payload, (address)));
            return "";
        }
        if (action == ACTION_REBALANCE) {
            (int24 lower, uint256 rewardHoldback) = abi.decode(payload, (int24, uint256));
            return abi.encode(_rebalanceTo(lower, rewardHoldback));
        }
        if (action == ACTION_CLOSE_BACKSTOP) {
            _closeBackstop();
            return "";
        }
        if (action == ACTION_CLOSE_MARKET) {
            address recipient = abi.decode(payload, (address));
            uint160 priceBefore = currentSqrtPriceX96();
            // Realise LP fees into the fee ledger first, so they are not folded into the principal paid
            // to `recipient` — keeps the fee ledger separate, as at every other liquidity-touching path.
            if (positionLiquidity != 0) _collectFees(tickLower, tickUpper);
            (uint256 ethOut, uint256 tokensOut) = _removeLiquidity(tickLower, tickUpper, positionLiquidity);
            if (ethOut != 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), ethOut);
            if (tokensOut != 0) poolManager.take(Currency.wrap(token), recipient, tokensOut);
            _requirePriceUnchanged(priceBefore);
            return abi.encode(ethOut, tokensOut);
        }
        revert CallbackNotExpected();
    }

    /// @dev Realises the LP fees accrued on the [lower, upper] position into the trading-fee ledger,
    /// kept fully separate from the burn/reward/retained ledgers. Poking with a zero delta also
    /// resets the position's fee checkpoint, so a subsequent add or trim in the same transaction sees
    /// pure principal - which is why this must run before those (a re-add would otherwise fold the
    /// fees into its caller delta and under-credit `inventoryCap`; a trim would burn them).
    function _collectFees(int24 lower, int24 upper) internal {
        (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            poolKey(),
            IPoolManager.ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 0, salt: bytes32(0)}),
            bytes("")
        );
        int128 ethFees = feesAccrued.amount0();
        int128 tokenFees = feesAccrued.amount1();
        uint256 tokenFee = tokenFees > 0 ? uint256(uint128(tokenFees)) : 0;
        uint256 ethFee = ethFees > 0 ? uint256(uint128(ethFees)) : 0;
        if (tokenFee != 0) {
            poolManager.mint(address(this), _currencyId(token), tokenFee);
            feeTokenClaims += tokenFee;
            totalFeeToken += tokenFee;
        }
        if (ethFee != 0) {
            poolManager.mint(address(this), _currencyId(address(0)), ethFee);
            feeEthClaims += ethFee;
            totalFeeEth += ethFee;
        }
        if (tokenFee != 0 || ethFee != 0) {
            lastClaimBlock = block.number;
            emit FeeCollected(tokenFee, ethFee);
        }
    }

    function _addPosition(
        address payer,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 ethBudget,
        uint256 maxTokens
    ) internal returns (bytes memory) {
        // A re-add to a position that already earned fees would fold those fees into the caller delta
        // below, under-crediting inventoryCap. Realise them first so the add's delta is pure
        // principal. A fresh open (no existing liquidity) has nothing to collect.
        if (positionLiquidity != 0) _collectFees(lower, upper);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey(),
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            bytes("")
        );
        if (delta.amount0() > 0 || delta.amount1() > 0) revert UnexpectedLiquidityDelta();

        uint256 ethRequired = uint256(-int256(delta.amount0()));
        uint256 tokensRequired = uint256(-int256(delta.amount1()));
        if (ethBudget < ethRequired) revert IncorrectEthAmount(ethRequired, ethBudget);
        if (tokensRequired > maxTokens) revert TokenAmountExceeded(tokensRequired, maxTokens);

        if (ethRequired != 0) poolManager.settle{value: ethRequired}();
        if (tokensRequired != 0) {
            poolManager.sync(Currency.wrap(token));
            if (payer == address(0)) {
                SafeTransferLib.safeTransfer(token, address(poolManager), tokensRequired);
            } else {
                SafeTransferLib.safeTransferFrom(token, payer, address(poolManager), tokensRequired);
            }
            poolManager.settle();
        }
        return abi.encode(ethRequired, tokensRequired);
    }

    function _requirePoolManagerAndPool(PoolKey calldata key) internal view {
        if (msg.sender != address(poolManager)) revert InvalidPoolManagerCaller();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId())) revert InvalidPool();
    }
}
