// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PleaDistributor} from "./PleaDistributor.sol";
import {PLEA} from "./PLEA.sol";
import {PleaHook} from "./PleaHook.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {Addresses} from "./libraries/Addresses.sol";
import {PleaText} from "./libraries/PleaText.sol";
import {MarketMath} from "./libraries/MarketMath.sol";

contract CabalGate is OracleAttestationConsumer, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    error Unauthorized();
    error NotReady();
    error InvalidAmount();
    error OpenPlea();
    error Cooldown();
    error CannotPass();
    error UnknownRequest();
    error SettledRequest();
    error InvalidPanel();
    error AppealUnavailable();
    error SellUnavailable();
    error PartialFill();
    error Slippage();
    error CabalStillAlive();
    event Submitted(
        uint256 indexed pleaId,
        address indexed seller,
        bytes32 indexed intakeId,
        uint256 amount,
        uint256 score,
        uint256 originalId,
        string text
    );
    event Verdict(uint256 indexed pleaId, bool approved, uint256 expiresAt);
    event NoVerdict(uint256 indexed pleaId);
    event Sold(uint256 indexed pleaId, address indexed seller, uint256 amount, uint256 imdOut);
    event Bought(address indexed trader, uint256 maxInput, uint256 pleaOut);
    event CabalKilled(uint256 timestamp);

    uint256 public constant ORACLE_FEE = 0.5 ether;
    uint256 public constant APPEAL_FEE = 0.35 ether;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    uint256 public constant MAX_SELL = 2_500_000 ether;
    uint256 public constant NO_VERDICT_DELAY = 20 minutes;
    uint256 public constant SELL_WINDOW = 7 minutes;
    uint256 public constant COOLDOWN = 4 hours;
    uint256 public constant DEADMAN = 33 hours;
    address public constant intake = Addresses.INTAKE;
    address public constant oracleAsset = Addresses.ORACLE_ASSET;
    IPoolManager public constant MANAGER = IPoolManager(Addresses.MANAGER);
    PLEA public immutable token;
    uint256 public lastVerdictAt;
    uint256 public nextPleaId = 1;

    enum Status {
        None,
        Pending,
        Approved,
        Denied,
        NoVerdict,
        Executed,
        Expired
    }

    struct Plea {
        address seller;
        Status status;
        bool appealed;
        uint64 submittedAt;
        uint64 verdictAt;
        uint64 expiresAt;
        uint8 score;
        uint256 amount;
        uint256 originalId;
        bytes32 intakeId;
        string text;
    }
    mapping(uint256 => Plea) private _pleas;
    mapping(bytes32 => uint256) public intakeToPlea;
    mapping(address => uint256) public openPlea;
    mapping(address => uint256) public nextAllowedAt;
    mapping(address => uint256) public lastExecutedAt;

    struct ActiveTrade {
        address trader;
        uint256 amount;
        uint256 minOut;
        uint160 limit;
        bool buy;
    }
    ActiveTrade private activeTrade;
    bool private callbackExpected;

    constructor(address token_) OracleAttestationConsumer(Addresses.SIGNER) {
        if (token_ == address(0)) revert Unauthorized();
        token = PLEA(token_);
        lastVerdictAt = block.timestamp;
    }

    function pleas(uint256 id) external view returns (Plea memory) {
        return _pleas[id];
    }

    function hook() public view returns (PleaHook) {
        address h = token.hook();
        if (h == address(0)) revert NotReady();
        return PleaHook(h);
    }

    function factScore(address seller, uint256 amount) public view returns (uint256 score) {
        uint256 balance = token.balanceOf(seller);
        if (amount == 0 || amount > MAX_SELL || amount > balance * 35 / 100) revert InvalidAmount();
        score = amount * 100 <= balance * 15 ? 18 : amount * 100 <= balance * 25 ? 11 : 5;
        PleaHook h = hook();
        uint256 average = h.averageBuyTime(seller);
        uint256 held = average == 0 || average > block.timestamp ? 0 : block.timestamp - average;
        score += held >= 7 days ? 14 : held >= 3 days ? 9 : held >= 1 days ? 5 : 0;
        uint256 basis = h.costBasis(seller);
        uint256 value = Math.mulDiv(balance, h.latestPrice(), 1e18);
        if (basis != 0) {
            score += value < basis ? 14 : value <= basis * 150 / 100 ? 9 : value <= basis * 300 / 100 ? 5 : 0;
        }
        uint256 oldPrice = h.price24hAgo();
        uint256 price = h.latestPrice();
        if (oldPrice != 0) score += price * 100 > oldPrice * 102 ? 9 : price * 100 >= oldPrice * 98 ? 5 : 0;
    }

    function submitSell(uint256 amount, string calldata text) external nonReentrant returns (uint256 id) {
        _ready(msg.sender);
        if (block.timestamp < nextAllowedAt[msg.sender]) revert Cooldown();
        id = _submit(amount, text, 0);
    }

    function _ready(address seller) private {
        if (token.cabalDead() || hook().seededAt() == 0) revert NotReady();
        _refresh(seller);
        if (openPlea[seller] != 0) revert OpenPlea();
        if (lastExecutedAt[seller] != 0 && block.timestamp < lastExecutedAt[seller] + COOLDOWN) revert Cooldown();
    }

    function _submit(uint256 amount, string memory text, uint256 original) private returns (uint256 id) {
        PleaText.validate(text);
        // Fact scoring reads the most recent stored checkpoint and never promotes spot itself.
        uint256 score = factScore(msg.sender, amount);
        if (70 - score > 45) revert CannotPass();
        id = nextPleaId++;
        Plea storage p = _pleas[id];
        p.seller = msg.sender;
        p.status = Status.Pending;
        p.submittedAt = uint64(block.timestamp);
        p.amount = amount;
        p.score = uint8(score);
        p.text = text;
        p.originalId = original;
        openPlea[msg.sender] = id;
        bytes memory body = PleaDistributor(token.distributor())
            .oracleBody(id, msg.sender, address(this), amount, score, text, original, _pleas[original].text);
        IERC20(oracleAsset).safeTransferFrom(msg.sender, address(this), ORACLE_FEE);
        IERC20(oracleAsset).forceApprove(intake, ORACLE_FEE);
        bytes32 request = IIntake(intake)
            .request(
                ACTION, body, IIntake.Callback(address(this), this.onOracleResult.selector), oracleAsset, ORACLE_FEE
            );
        if (request == bytes32(0) || intakeToPlea[request] != 0) revert UnknownRequest();
        p.intakeId = request;
        intakeToPlea[request] = id;
        IERC20(oracleAsset).forceApprove(intake, 0);
        emit Submitted(id, msg.sender, request, amount, score, original, text);
    }

    /// @notice Intake-only; no public signed-result submission or relayer path exists.
    function onOracleResult(bytes32 intakeId, OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        if (msg.sender != intake) revert Unauthorized();
        uint256 id = intakeToPlea[intakeId];
        if (id == 0) revert UnknownRequest();
        Plea storage p = _pleas[id];
        // A retired request remains indexed to harmlessly ignore delayed deliveries.
        if (p.status == Status.NoVerdict || token.cabalDead()) return;
        if (p.status != Status.Pending) revert SettledRequest();
        if (block.timestamp >= uint256(p.submittedAt) + NO_VERDICT_DELAY) {
            _noVerdict(id, p);
            return;
        }
        if (
            block.chainid != 11155111 || a.chainId != 1 || a.panelSize < 30 || a.quorum < 17 || a.agreed < 17
                || a.agreed < a.quorum || a.agreed > a.panelSize || a.quorum > a.panelSize
        ) revert InvalidPanel();
        _verifyAttestation(a, sig);
        bool yes = decodeBool(a);
        _consume(a.requestId);
        p.verdictAt = uint64(block.timestamp);
        lastVerdictAt = block.timestamp;
        if (yes) {
            p.status = Status.Approved;
            p.expiresAt = uint64(block.timestamp + SELL_WINDOW);
        } else {
            p.status = Status.Denied;
            p.expiresAt = uint64(block.timestamp + COOLDOWN);
            nextAllowedAt[p.seller] = block.timestamp + COOLDOWN;
            openPlea[p.seller] = 0;
        }
        emit Verdict(id, yes, p.expiresAt);
    }

    function clearNoVerdict() external nonReentrant {
        _refresh(msg.sender);
    }

    function _refresh(address seller) private {
        uint256 id = openPlea[seller];
        if (id == 0) return;
        Plea storage p = _pleas[id];
        if (p.status == Status.Pending) {
            bool completed;
            if (block.timestamp < uint256(p.submittedAt) + NO_VERDICT_DELAY) {
                (,,, completed) = IIntake(intake).requests(p.intakeId);
            }
            if (completed || block.timestamp >= uint256(p.submittedAt) + NO_VERDICT_DELAY) _noVerdict(id, p);
        } else if (p.status == Status.Approved && block.timestamp > p.expiresAt) {
            p.status = Status.Expired;
            openPlea[seller] = 0;
        }
    }

    function _noVerdict(uint256 id, Plea storage p) private {
        p.status = Status.NoVerdict;
        nextAllowedAt[p.seller] = 0;
        if (openPlea[p.seller] == id) openPlea[p.seller] = 0;
        emit NoVerdict(id);
    }

    function appeal(uint256 originalId, uint256 amount, string calldata text)
        external
        nonReentrant
        returns (uint256 id)
    {
        _ready(msg.sender);
        Plea storage original = _pleas[originalId];
        if (
            original.seller != msg.sender || original.status != Status.Denied || original.appealed
                || block.timestamp >= uint256(original.verdictAt) + COOLDOWN || amount > original.amount
        ) revert AppealUnavailable();
        original.appealed = true;
        // Pull only from the authenticated caller, outside PoolManager's callback.
        IERC20(Addresses.IMD).safeTransferFrom(msg.sender, address(this), APPEAL_FEE);
        PleaHook h = hook();
        IERC20(Addresses.IMD).safeTransfer(address(h), APPEAL_FEE);
        h.fundLiquidity(APPEAL_FEE);
        id = _submit(amount, text, originalId);
    }

    function executeSell(uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 id = openPlea[msg.sender];
        Plea storage p = _pleas[id];
        if (p.seller != msg.sender || p.status != Status.Approved || block.timestamp > p.expiresAt || token.cabalDead())
        {
            revert SellUnavailable();
        }
        uint256 balanceBefore = token.balanceOf(msg.sender);
        if (balanceBefore < p.amount) revert InvalidAmount();
        p.status = Status.Executed;
        openPlea[msg.sender] = 0;
        lastExecutedAt[msg.sender] = block.timestamp;
        nextAllowedAt[msg.sender] = block.timestamp + COOLDOWN;
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), p.amount);
        PleaHook h = hook();
        uint160 limit = _sellLimit(h, p.amount, minOut);
        out = _trade(ActiveTrade(msg.sender, p.amount, minOut, limit, false));
        h.recordSell(msg.sender, p.amount, balanceBefore);
        emit Sold(id, msg.sender, p.amount, out);
    }

    /// @notice Exact-input buy, with direct PLEA delivery and same-swap cashback; input is prepaid.
    function buy(uint256 amountIn, uint256 minPleaOut, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > uint256(int256(type(int128).max))) revert InvalidAmount();
        IERC20(Addresses.IMD).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 beforeBalance = token.balanceOf(msg.sender);
        _trade(ActiveTrade(msg.sender, amountIn, minPleaOut, sqrtPriceLimitX96, true));
        out = token.balanceOf(msg.sender) - beforeBalance;
        if (out < minPleaOut) revert Slippage();
        emit Bought(msg.sender, amountIn, out);
    }

    /// @notice After the dead-man switch, use the same prepaid router without an oracle verdict.
    function sellFreely(uint256 amount, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (!token.cabalDead()) revert CabalStillAlive();
        if (amount == 0 || amount > uint256(int256(type(int128).max))) revert InvalidAmount();
        uint256 balanceBefore = token.balanceOf(msg.sender);
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);
        PleaHook h = hook();
        out = _trade(ActiveTrade(msg.sender, amount, minOut, _sellLimit(h, amount, minOut), false));
        h.recordSell(msg.sender, amount, balanceBefore);
    }

    function _sellLimit(PleaHook h, uint256 amount, uint256 minOut) private view returns (uint160) {
        if (minOut == 0) return h.plea0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 netInput = amount - amount / 400;
        // Bound marginal execution price after the 1.25% IMD fees, not only average execution.
        uint256 grossMinimum = Math.mulDiv(minOut, 10_000, 9875, Math.Rounding.Ceil);
        uint160 limit =
            h.plea0() ? MarketMath.sqrtRatio(grossMinimum, netInput) : MarketMath.sqrtRatio(netInput, grossMinimum);
        return h.plea0() ? limit + 1 : limit;
    }

    function _trade(ActiveTrade memory trade) private returns (uint256 out) {
        if (callbackExpected) revert Unauthorized();
        activeTrade = trade;
        callbackExpected = true;
        out = abi.decode(MANAGER.unlock(""), (uint256));
        delete activeTrade;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(MANAGER) || !callbackExpected) revert Unauthorized();
        callbackExpected = false;
        ActiveTrade memory t = activeTrade;
        PleaHook h = hook();
        PoolKey memory key = h.poolKey();
        address asset = t.buy ? Addresses.IMD : address(token);
        // Only this contract's already collected balance is used. No caller-supplied transferFrom.
        MANAGER.sync(Currency.wrap(asset));
        IERC20(asset).safeTransfer(address(MANAGER), t.amount);
        MANAGER.settle();
        BalanceDelta d = MANAGER.swap(
            key, IPoolManager.SwapParams(t.buy != h.plea0(), -int256(t.amount), t.limit), abi.encode(t.trader)
        );
        int128 spent = t.buy ? (h.plea0() ? d.amount1() : d.amount0()) : (h.plea0() ? d.amount0() : d.amount1());
        if (spent != -int256(t.amount)) revert PartialFill();
        uint256 out;
        if (!t.buy) {
            int128 received = h.plea0() ? d.amount1() : d.amount0();
            if (received < 0) revert Slippage();
            out = uint256(int256(received));
            if (out < t.minOut) revert Slippage();
            MANAGER.take(Currency.wrap(Addresses.IMD), t.trader, out);
        }
        return abi.encode(out);
    }

    function killCabal() external nonReentrant {
        if (token.cabalDead() || block.timestamp < lastVerdictAt + DEADMAN) revert CabalStillAlive();
        token.killCabal();
        emit CabalKilled(block.timestamp);
    }
}
