// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PLEA} from "./PLEA.sol";
import {Addresses} from "./libraries/Addresses.sol";
import {MarketMath} from "./libraries/MarketMath.sol";
import {IStacker} from "./interfaces/IIntake.sol";

/// @notice POOL4's cap, rate-limited ratchet and guarded single-sided backstop, adapted to TestIMD.
/// @dev Liquidity has no withdrawal, close, rescue or owner reconfiguration path. See docs/POOL4-CappedBurnHook.sol.txt.
contract PleaHook {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    error Unauthorized();
    error InvalidPool();
    error InvalidTrader();
    error ExactInputOnly();
    error PrepayRequired();
    error NotEnoughGas();
    error LaunchBuyLimit();
    error NoFill();
    error ReentrantSwap();
    error NoWork();
    error AlreadySeeded();
    event Seeded(uint256 timestamp, uint160 sqrtPriceX96, uint256 inventory);
    event Trade(address indexed trader, bool buy, uint256 imd, uint256 plea, uint256 cashback, uint256 liquidityFee);
    event Cashback(address indexed trader, uint256 amount, bool stacked);
    event CapRatcheted(uint256 previous, uint256 current);
    event Trimmed(uint256 tokensBurned, uint256 imdRetained);
    event Rebalanced(uint256 work, uint256 imdDeployed, uint256 tokensBurned, uint256 tip);
    event Checkpoint(uint256 indexed hour, uint256 price);

    IPoolManager public constant MANAGER = IPoolManager(Addresses.MANAGER);
    uint256 public constant CREDIT_GAS = 2_000_000;
    uint256 public constant RESERVE = 200_000;
    uint256 public constant capFloor = 900_000 ether;
    uint256 public constant capDecay = 300_000 ether;
    uint256 public constant LAUNCH_WINDOW = 90 minutes;
    uint256 public constant MAX_LAUNCH_BUY = 5_000_000 ether;
    int24 public constant SPACING = 60;
    int24 private constant MIN_TICK = -887220;
    int24 private constant MAX_TICK = 887220;
    uint256 private constant BPS = 10_000;
    bytes32 private constant SWAPPING = keccak256("plea.hook.swap");
    bytes32 private constant BUY_INPUT = keccak256("plea.hook.input");
    bytes32 private constant BUY_GROSS = keccak256("plea.hook.gross");
    bytes32 private constant BUY_FILL = keccak256("plea.hook.fill");
    bytes32 private constant BUY_OUTPUT = keccak256("plea.hook.output");

    PLEA public immutable token;
    address public immutable gate;
    address public immutable owner;
    address public immutable launcher;
    bool public immutable plea0;
    uint256 public seededAt;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public positionLiquidity;
    uint256 public inventoryCap;
    uint256 public lastCapDecayAt;
    uint256 public capDecayRemainder;
    uint256 public totalBurned;
    uint256 public retainedIMD;
    uint256 public tipReserve;
    uint256 public lastTipAt;
    uint256 public totalLiquidityFees;
    uint256 public totalOwnerFees;
    uint256 public totalCashback;

    struct Band {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 principal;
    }
    Band public backstop;

    // POOL4 placement policy is expressed in an oriented tick: larger = cheaper PLEA.
    int24 public refTick;
    int24 public deploymentFloorTick;
    int24 private blockTick;
    uint256 private refBlock;
    uint256 private lastFloorAt;
    uint256 private floorRemainder;
    bool private callbackExpected;

    struct PriceCheckpoint {
        uint64 hour;
        uint192 price;
    }
    PriceCheckpoint[25] public checkpoints;
    uint256 public latestCheckpointHour;
    uint256 public latestPrice;
    uint256 private observedPrice;
    uint256 private observedBlock;
    uint256 private confirmedPrice;
    mapping(address => uint256) public costBasis;
    mapping(address => uint256) public averageBuyTime;

    constructor(address token_, address gate_, address owner_) {
        if (token_ == address(0) || gate_ == address(0) || owner_ == address(0)) revert Unauthorized();
        if (uint160(address(this)) & Addresses.HOOK_MASK != Addresses.HOOK_FLAGS) revert InvalidPool();
        token = PLEA(token_);
        gate = gate_;
        owner = owner_;
        launcher = msg.sender;
        plea0 = token_ < Addresses.IMD;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(plea0 ? address(token) : Addresses.IMD),
            currency1: Currency.wrap(plea0 ? Addresses.IMD : address(token)),
            fee: 0,
            tickSpacing: SPACING,
            hooks: IHooks(address(this))
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    function currentSqrtPriceX96() public view returns (uint160 p) {
        (p,,,) = MANAGER.getSlot0(poolId());
    }

    function currentTick() public view returns (int24 t) {
        (, t,,) = MANAGER.getSlot0(poolId());
    }

    function _orientedTick() private view returns (int24) {
        int24 t = currentTick();
        return plea0 ? -t : t;
    }

    function launchFeeBps() public view returns (uint256) {
        if (seededAt == 0 || block.timestamp >= seededAt + LAUNCH_WINDOW) return 0;
        return 7000 * (seededAt + LAUNCH_WINDOW - block.timestamp) / LAUNCH_WINDOW;
    }

    function seed() external {
        if (msg.sender != launcher) revert Unauthorized();
        if (seededAt != 0) revert AlreadySeeded();
        // Tick-align away from the sale range so the initial LP is strictly PLEA-only.
        uint160 target = plea0 ? MarketMath.sqrtRatio(5700, 1_000_000_000) : MarketMath.sqrtRatio(1_000_000_000, 5700);
        int24 tick = TickMath.getTickAtSqrtPrice(target);
        int24 boundary = plea0 ? _alignUp(tick) : _alignDown(tick);
        uint160 start = target;
        tickLower = plea0 ? boundary : MIN_TICK;
        tickUpper = plea0 ? MAX_TICK : boundary;
        seededAt = block.timestamp;
        MANAGER.initialize(poolKey(), start);
        refTick = _orientedTick();
        blockTick = refTick;
        refBlock = block.number;
        deploymentFloorTick = refTick + 1;
        lastFloorAt = block.timestamp;
        lastCapDecayAt = block.timestamp;
        callbackExpected = true;
        MANAGER.unlock(abi.encode(uint8(1)));
        latestPrice = MarketMath.priceWad(start, plea0);
        observedPrice = latestPrice;
        confirmedPrice = latestPrice;
        observedBlock = block.number;
        latestCheckpointHour = block.timestamp / 1 hours;
        _writeCheckpoint(latestCheckpointHour, latestPrice);
        emit Seeded(block.timestamp, start, inventoryCap);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != address(MANAGER) || !callbackExpected) revert Unauthorized();
        callbackExpected = false;
        uint8 action = abi.decode(data, (uint8));
        if (action == 1) {
            uint256 amount = token.balanceOf(address(this));
            uint160 a = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 b = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liq = plea0 ? MarketMath.liquidity0(a, b, amount) : MarketMath.liquidity1(a, b, amount);
            (uint256 p,) = _add(tickLower, tickUpper, liq, bytes32(0));
            positionLiquidity = liq;
            inventoryCap = p;
            // Liquidity inversion dust is permanently retired, never recoverable by the owner.
            _burn(token.balanceOf(address(this)));
        } else if (action == 2) {
            result = abi.encode(_rebalance());
        } else {
            revert Unauthorized();
        }
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        _check(key);
        if (sender != address(this)) revert Unauthorized();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        _check(key);
        if (sender != address(this)) revert Unauthorized();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        _check(key);
        if (sender != address(this)) revert Unauthorized();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        _check(key);
        address trader = _trader(data);
        if (seededAt == 0) revert Unauthorized();
        if (params.amountSpecified >= 0 || params.amountSpecified < -int256(type(int128).max)) revert ExactInputOnly();
        if (_load(SWAPPING) != 0) revert ReentrantSwap();
        _store(SWAPPING, 1);
        checkpoint();
        uint256 input = uint256(-params.amountSpecified);
        bool buy = params.zeroForOne != plea0;
        // Only the gate authenticates the buy recipient whose holding time and basis we update.
        if ((buy || !token.cabalDead()) && sender != gate) revert Unauthorized();
        Currency inputCurrency = Currency.wrap(buy ? Addresses.IMD : address(token));
        if (MANAGER.currencyDelta(sender, inputCurrency) < int256(input)) revert PrepayRequired();
        if (buy) {
            uint256 denominator = BPS - 125 - launchFeeBps();
            uint256 budget = input * denominator / BPS;
            if (budget == 0) revert NoFill();
            // The priced swap is self-initiated: v4 skips this hook recursively. The outer swap is zeroed.
            BalanceDelta fill = MANAGER.swap(
                key, IPoolManager.SwapParams(params.zeroForOne, -int256(budget), params.sqrtPriceLimitX96), ""
            );
            uint256 imd = _negative(plea0 ? fill.amount1() : fill.amount0());
            uint256 output = _positive(plea0 ? fill.amount0() : fill.amount1());
            if (imd == 0 || output == 0) revert NoFill();
            if (block.timestamp < seededAt + LAUNCH_WINDOW && output > MAX_LAUNCH_BUY) revert LaunchBuyLimit();
            uint256 gross = Math.ceilDiv(imd * BPS, denominator);
            _store(BUY_INPUT, input);
            _store(BUY_GROSS, gross);
            _store(BUY_FILL, imd);
            _store(BUY_OUTPUT, output);
            // Take only actual-fill fees/refund in afterSwap; never create claims for the output.
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(input)), 0), 0);
        }
        uint256 burnAmount = input / 400;
        if (burnAmount != 0) {
            MANAGER.take(Currency.wrap(address(token)), address(this), burnAmount);
            _burn(burnAmount);
        }
        // Trader is decoded even on sells. The gate authenticates it against its active caller.
        if (trader == address(this)) revert InvalidTrader();
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(burnAmount)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external returns (bytes4, int128 hookDelta) {
        _check(key);
        if (_load(SWAPPING) != 1) revert Unauthorized();
        address trader = _trader(data);
        bool buy = params.zeroForOne != plea0;
        uint256 imd;
        uint256 plea;
        uint256 cashback;
        uint256 liquidityFee;
        if (buy) {
            uint256 gross = _load(BUY_GROSS);
            imd = _load(BUY_FILL);
            uint256 output = _load(BUY_OUTPUT);
            uint256 burnAmount = output / 400;
            plea = output - burnAmount;
            cashback = gross / 200;
            liquidityFee = gross - imd - cashback * 2;
            uint256 oldBalance = token.balanceOf(trader);
            averageBuyTime[trader] = oldBalance == 0 || averageBuyTime[trader] == 0
                ? block.timestamp
                : (averageBuyTime[trader] * oldBalance + block.timestamp * plea) / (oldBalance + plea);
            costBasis[trader] += gross;
            MANAGER.take(Currency.wrap(address(token)), trader, plea);
            if (burnAmount != 0) {
                MANAGER.take(Currency.wrap(address(token)), address(this), burnAmount);
                _burn(burnAmount);
            }
            uint256 refund = _load(BUY_INPUT) - gross;
            if (refund != 0) MANAGER.take(Currency.wrap(Addresses.IMD), trader, refund);
            _payFees(trader, cashback, liquidityFee, gross / 400);
            imd = gross;
        } else {
            imd = _positive(plea0 ? delta.amount1() : delta.amount0());
            plea = _negative(plea0 ? delta.amount0() : delta.amount1());
            if (imd == 0) revert NoFill();
            uint256 requested = uint256(-params.amountSpecified);
            if (plea != requested - requested / 400) revert NoFill();
            cashback = imd / 200;
            liquidityFee = imd / 400;
            _payFees(trader, cashback, liquidityFee, liquidityFee);
            hookDelta = int128(int256(cashback * 2 + liquidityFee));
        }
        _applyCap();
        _observe();
        _store(SWAPPING, 0);
        emit Trade(trader, buy, imd, plea, cashback, liquidityFee);
        return (IHooks.afterSwap.selector, hookDelta);
    }

    function _payFees(address trader, uint256 cashback, uint256 liquidityFee, uint256 tipEligible) private {
        Currency imd = Currency.wrap(Addresses.IMD);
        if (cashback != 0) {
            totalCashback += cashback;
            totalOwnerFees += cashback;
            MANAGER.take(imd, owner, cashback);
            MANAGER.take(imd, address(this), cashback);
            IERC20(Addresses.IMD).forceApprove(Addresses.STACKER, cashback);
            // This check precedes the try: estimation cannot succeed by starving credit of gas.
            if (gasleft() < CREDIT_GAS + RESERVE) revert NotEnoughGas();
            try IStacker(Addresses.STACKER).credit{gas: CREDIT_GAS}(trader, cashback) returns (uint256) {
                emit Cashback(trader, cashback, true);
            } catch {
                IERC20(Addresses.IMD).safeTransfer(trader, cashback);
                emit Cashback(trader, cashback, false);
            }
            IERC20(Addresses.IMD).forceApprove(Addresses.STACKER, 0);
        }
        if (liquidityFee != 0) {
            totalLiquidityFees += liquidityFee;
            retainedIMD += liquidityFee;
            tipReserve += tipEligible;
            MANAGER.take(imd, address(this), liquidityFee);
        }
    }

    /// @notice A distribution has zero cost basis; its holding clock begins at receipt.
    function recordDistribution(address trader, uint256 amount) external {
        if (msg.sender != token.distributor()) revert Unauthorized();
        uint256 balance = token.balanceOf(trader);
        uint256 oldBalance = balance - amount;
        averageBuyTime[trader] = oldBalance == 0 || averageBuyTime[trader] == 0
            ? block.timestamp
            : (averageBuyTime[trader] * oldBalance + block.timestamp * amount) / balance;
    }

    function recordSell(address trader, uint256 amount, uint256 balanceBefore) external {
        if (msg.sender != gate) revert Unauthorized();
        costBasis[trader] = FullMath.mulDiv(costBasis[trader], balanceBefore - amount, balanceBefore);
        if (amount == balanceBefore) averageBuyTime[trader] = 0;
    }

    function fundLiquidity(uint256 amount) external {
        if (msg.sender != gate || seededAt == 0 || _load(SWAPPING) != 0) revert Unauthorized();
        // Gate transferred its own freshly-collected appeal fee before this call.
        if (IERC20(Addresses.IMD).balanceOf(address(this)) < retainedIMD + amount) revert PrepayRequired();
        retainedIMD += amount;
    }

    function tokensInPool() public view returns (uint256) {
        (uint256 a, uint256 b) =
            MarketMath.amounts(currentSqrtPriceX96(), tickLower, tickUpper, positionLiquidity, false);
        return plea0 ? a : b;
    }

    function _applyCap() private {
        uint256 held = tokensInPool();
        if (held < inventoryCap) {
            uint256 accrued = capDecay * (block.timestamp - lastCapDecayAt);
            uint256 allowance = accrued > capDecayRemainder ? (accrued - capDecayRemainder) / 1 days : 0;
            uint256 next = Math.max(capFloor, Math.max(held, inventoryCap > allowance ? inventoryCap - allowance : 0));
            if (next < inventoryCap) {
                uint256 numerator = (inventoryCap - next) * 1 days + capDecayRemainder;
                lastCapDecayAt += numerator / capDecay;
                capDecayRemainder = numerator % capDecay;
                emit CapRatcheted(inventoryCap, next);
                inventoryCap = next;
            }
        } else if (held > inventoryCap) {
            uint128 remove = MarketMath.narrow(FullMath.mulDiv(positionLiquidity, held - inventoryCap, held));
            if (remove != 0) {
                positionLiquidity -= remove;
                (uint256 p, uint256 imd) = _remove(tickLower, tickUpper, remove, bytes32(0));
                retainedIMD += imd;
                _burn(p);
                emit Trimmed(p, imd);
            }
        }
    }

    function backstopConvertedIMD() public view returns (uint256) {
        Band memory b = backstop;
        if (b.liquidity == 0) return 0;
        // Match the rounding used when v4 charged the principal; deposit dust is not a fill.
        (uint256 a0, uint256 a1) = MarketMath.amounts(currentSqrtPriceX96(), b.lower, b.upper, b.liquidity, true);
        uint256 remaining = plea0 ? a1 : a0;
        return b.principal > remaining ? b.principal - remaining : 0;
    }

    function rebalance() external {
        if (seededAt == 0 || callbackExpected || _load(SWAPPING) != 0) revert Unauthorized();
        checkpoint();
        callbackExpected = true;
        uint256 tip = abi.decode(MANAGER.unlock(abi.encode(uint8(2))), (uint256));
        if (tip != 0) IERC20(Addresses.IMD).safeTransfer(msg.sender, tip);
    }

    function _rebalance() private returns (uint256 tip) {
        // As in POOL4, the cap runs on swaps. Rebalancing only moves the backstop.
        _updateFloor(_orientedTick());
        uint256 idle = retainedIMD;
        uint256 converted = backstopConvertedIMD();
        if (idle == 0 && converted == 0) revert NoWork();
        uint256 burned;
        Band memory old = backstop;
        if (old.liquidity != 0) {
            uint256 recovered;
            (burned, recovered) = _remove(old.lower, old.upper, old.liquidity, bytes32(uint256(1)));
            retainedIMD += recovered;
            _burn(burned);
            delete backstop;
        }
        uint256 work = idle + converted;
        if (work >= 100 ether && block.timestamp >= lastTipAt + 1 hours) {
            tip = Math.min(1 ether, Math.min(work / 400, Math.min(tipReserve, retainedIMD)));
        }
        uint256 budget = retainedIMD - tip;
        int24 orientedLower = _alignUp(deploymentFloorTick);
        uint256 deployed;
        if (budget != 0 && orientedLower < MAX_TICK && orientedLower > MIN_TICK) {
            int24 lower = plea0 ? MIN_TICK : orientedLower;
            int24 upper = plea0 ? -orientedLower : MAX_TICK;
            uint160 a = TickMath.getSqrtPriceAtTick(lower);
            uint160 b = TickMath.getSqrtPriceAtTick(upper);
            uint128 liq = plea0 ? MarketMath.liquidity1(a, b, budget) : MarketMath.liquidity0(a, b, budget);
            if (liq != 0) {
                (uint256 p, uint256 used) = _add(lower, upper, liq, bytes32(uint256(1)));
                if (p != 0 || used > budget) revert InvalidPool();
                retainedIMD -= used;
                deployed = used;
                backstop = Band(lower, upper, liq, used);
            }
        }
        // Merely recycling an unfilled band never counts as new work.
        uint256 moved = Math.min(idle, deployed) + converted;
        if (moved < 100 ether) tip = 0;
        if (tip != 0) {
            retainedIMD -= tip;
            tipReserve -= tip;
            lastTipAt = block.timestamp;
        }
        emit Rebalanced(moved, deployed, burned, tip);
    }

    function _observe() private {
        int24 current = _orientedTick();
        _updateFloor(current);
        if (block.number != refBlock) {
            int24 diff = blockTick - refTick;
            refTick += diff > 200 ? int24(200) : diff < -200 ? int24(-200) : diff;
            refBlock = block.number;
        }
        blockTick = current;
        observedPrice = MarketMath.priceWad(currentSqrtPriceX96(), plea0);
        observedBlock = block.number;
    }

    function _updateFloor(int24 current) private {
        uint256 elapsed = Math.min(block.timestamp - lastFloorAt, 1 days);
        lastFloorAt = block.timestamp;
        int24 target = refTick + 1;
        if (target < deploymentFloorTick) {
            uint256 numerator = 400 * elapsed + floorRemainder;
            uint256 step = numerator / 1 days;
            floorRemainder = numerator % 1 days;
            uint256 gap = uint256(int256(deploymentFloorTick - target));
            deploymentFloorTick = step >= gap ? target : deploymentFloorTick - int24(int256(step));
        } else {
            floorRemainder = 0;
        }
        if (current + 1 > deploymentFloorTick) deploymentFloorTick = current + 1;
    }

    /// @notice Snapshot only a previous block's close; same-hour checkpoints cannot be overwritten.
    function checkpoint() public {
        if (seededAt == 0) return;
        if (observedBlock < block.number) confirmedPrice = observedPrice;
        uint256 hour = block.timestamp / 1 hours;
        if (hour <= latestCheckpointHour) return;
        uint256 from = latestCheckpointHour + 1;
        if (hour - from >= 25) from = hour - 24;
        for (uint256 h = from; h <= hour; ++h) {
            _writeCheckpoint(h, confirmedPrice);
        }
        latestCheckpointHour = hour;
        latestPrice = confirmedPrice;
    }

    function _writeCheckpoint(uint256 hour, uint256 price) private {
        require(price <= type(uint192).max, "price overflow");
        checkpoints[hour % 25] = PriceCheckpoint(uint64(hour), uint192(price));
        emit Checkpoint(hour, price);
    }

    function price24hAgo() external view returns (uint256) {
        if (latestCheckpointHour < 24) return latestPrice;
        uint256 hour = latestCheckpointHour - 24;
        PriceCheckpoint memory p = checkpoints[hour % 25];
        return p.hour == hour ? p.price : latestPrice;
    }

    function _add(int24 lower, int24 upper, uint128 liq, bytes32 salt) private returns (uint256 p, uint256 imd) {
        (BalanceDelta d,) = MANAGER.modifyLiquidity(
            poolKey(), IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liq)), salt), ""
        );
        uint256 a0 = _negative(d.amount0());
        uint256 a1 = _negative(d.amount1());
        p = plea0 ? a0 : a1;
        imd = plea0 ? a1 : a0;
        if (p != 0) _pay(address(token), p);
        if (imd != 0) _pay(Addresses.IMD, imd);
    }

    function _remove(int24 lower, int24 upper, uint128 liq, bytes32 salt) private returns (uint256 p, uint256 imd) {
        (BalanceDelta d,) = MANAGER.modifyLiquidity(
            poolKey(), IPoolManager.ModifyLiquidityParams(lower, upper, -int256(uint256(liq)), salt), ""
        );
        uint256 a0 = _positive(d.amount0());
        uint256 a1 = _positive(d.amount1());
        p = plea0 ? a0 : a1;
        imd = plea0 ? a1 : a0;
        if (p != 0) MANAGER.take(Currency.wrap(address(token)), address(this), p);
        if (imd != 0) MANAGER.take(Currency.wrap(Addresses.IMD), address(this), imd);
    }

    function _pay(address asset, uint256 amount) private {
        MANAGER.sync(Currency.wrap(asset));
        IERC20(asset).safeTransfer(address(MANAGER), amount);
        MANAGER.settle();
    }

    function _burn(uint256 amount) private {
        if (amount != 0) {
            totalBurned += amount;
            token.burn(amount);
        }
    }

    function _check(PoolKey calldata key) private view {
        if (msg.sender != address(MANAGER)) revert Unauthorized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId())) revert InvalidPool();
    }

    function _trader(bytes calldata data) private view returns (address trader) {
        if (data.length != 32) revert InvalidTrader();
        trader = abi.decode(data, (address));
        if (trader == address(0) || trader == address(MANAGER) || trader == address(this) || trader == gate) {
            revert InvalidTrader();
        }
    }

    function _positive(int128 v) private pure returns (uint256) {
        require(v >= 0, "wrong delta");
        return uint256(int256(v));
    }

    function _negative(int128 v) private pure returns (uint256) {
        require(v <= 0, "wrong delta");
        return uint256(-int256(v));
    }

    function _alignUp(int24 t) private pure returns (int24 a) {
        a = (t / SPACING) * SPACING;
        if (a < t) a += SPACING;
    }

    function _alignDown(int24 t) private pure returns (int24 a) {
        a = (t / SPACING) * SPACING;
        if (a > t) a -= SPACING;
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }
}
