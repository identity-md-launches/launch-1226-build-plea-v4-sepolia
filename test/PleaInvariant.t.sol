// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PleaFixture} from "./fixtures/PleaFixture.sol";
import {TestAsset, TestSIMD, MockIntake} from "./fixtures/Mocks.sol";
import {Stacker} from "./fixtures/Stacker.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

/// @dev Only this handler is a fuzz target. No calls to mint, etch or storage writes occur during a campaign.
contract PleaHandler is Test {
    PLEA public token;
    CabalGate public gate;
    PleaHook public hook;
    PleaDistributor public distributor;
    TestAsset public imd;
    TestAsset public oracleAsset;
    TestSIMD public simd;
    MockIntake public intake;
    address[4] public actors;
    bytes32[4] private leaves;
    uint256 private constant SIGN_KEY = 0x12345;
    uint256 public constant ENTITLEMENT = 1000 ether;

    // Ghosts are updated from successful user actions, independently of protocol aggregates.
    uint256[4] public expectedPLEA;
    bool[4] public didClaim;
    uint256[4] public lastDenied;
    uint256 public paidRequests;
    uint256 public paidAppeals;
    uint256 public plainCashback;
    uint256 public keeperTips;
    uint256 public donatedIMD;
    uint256 public burned;
    uint256 public buys;
    uint256 public executedSells;
    uint256 public freeSells;
    uint256 public verdicts;
    uint256 public expirations;
    uint256 public claims;
    uint256 public previousCap;
    uint256 public previousSupply;
    bool public dead;

    constructor(PLEA t, CabalGate g, PleaHook h, PleaDistributor d, TestSIMD vault, address[4] memory wallets) {
        token = t;
        gate = g;
        hook = h;
        distributor = d;
        imd = TestAsset(Addresses.IMD);
        oracleAsset = TestAsset(Addresses.ORACLE_ASSET);
        intake = MockIntake(Addresses.INTAKE);
        simd = vault;
        actors = wallets;
        burned = t.SUPPLY() - t.totalSupply(); // Initial seeding retires inversion dust.
        previousCap = h.inventoryCap();
        previousSupply = t.totalSupply();
        for (uint256 i; i < 4; ++i) {
            expectedPLEA[i] = t.balanceOf(wallets[i]);
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(wallets[i], ENTITLEMENT))));
        }
    }

    function root() external view returns (bytes32) {
        return _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _begin() private {
        vm.recordLogs();
    }

    function _end() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j; j < logs.length; ++j) {
            Vm.Log memory entry = logs[j];
            if (
                entry.emitter == address(token) && entry.topics.length == 3
                    && entry.topics[0] == keccak256("Transfer(address,address,uint256)")
                    && entry.topics[2] == bytes32(0)
            ) {
                burned += abi.decode(entry.data, (uint256));
            }
            if (entry.emitter == address(hook) && entry.topics[0] == keccak256("Cashback(address,uint256,bool)")) {
                (uint256 amount, bool stacked) = abi.decode(entry.data, (uint256, bool));
                if (!stacked) plainCashback += amount;
                assertEq(stacked, !simd.paused(), "cashback may fall back only on a vault failure");
            }
        }
        assertLe(token.totalSupply(), previousSupply, "no mint after init");
        assertLe(hook.inventoryCap(), previousCap, "cap must never grow");
        previousSupply = token.totalSupply();
        previousCap = hook.inventoryCap();
    }

    function buy(uint256 who, uint256 rawAmount, bool paused) external {
        uint256 i = who % 4;
        uint256 budget = imd.balanceOf(actors[i]);
        if (budget < 0.01 ether) return;
        uint256 amount = bound(rawAmount, 0.01 ether, budget < 1000 ether ? budget : 1000 ether);
        simd.setPaused(paused);
        uint160 limit = hook.plea0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        _begin();
        vm.prank(actors[i]);
        uint256 out = gate.buy(amount, 1, limit);
        expectedPLEA[i] += out;
        ++buys;
        _end();
    }

    function submit(uint256 who, uint256 fraction) external {
        uint256 i = who % 4;
        address seller = actors[i];
        if (dead) return;
        vm.prank(seller);
        gate.clearNoVerdict();
        if (gate.openPlea(seller) != 0 || block.timestamp < gate.nextAllowedAt(seller)) return;
        uint256 maxAmount = token.balanceOf(seller) * 15 / 100;
        if (maxAmount > gate.MAX_SELL()) maxAmount = gate.MAX_SELL();
        if (maxAmount < 1 ether || oracleAsset.balanceOf(seller) < 0.5 ether) return;
        uint256 amount = bound(fraction, 1 ether, maxAmount);
        if (gate.factScore(seller, amount) < 25) return;
        vm.prank(seller);
        uint256 id = gate.submitSell(amount, "Rent is due; I am keeping the rest.");
        ++paidRequests;
        assertEq(gate.openPlea(seller), id);
        assertEq(gate.pleas(id).amount, amount);
    }

    function verdict(uint256 who, bool approved) external {
        address seller = actors[who % 4];
        uint256 id = gate.openPlea(seller);
        if (dead || id == 0) return;
        CabalGate.Plea memory p = gate.pleas(id);
        if (p.status != CabalGate.Status.Pending) return;
        if (block.timestamp >= uint256(p.submittedAt) + 20 minutes) {
            vm.prank(seller);
            gate.clearNoVerdict();
            ++expirations;
            return;
        }
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invariant oracle UUID", id));
        a.chainId = 1;
        a.questionHash = keccak256(abi.encode(id, "resolved window"));
        a.answer = abi.encode(approved);
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 17;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGN_KEY, gate.attestationDigest(a));
        (bool ok,) = intake.deliver(p.intakeId, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "valid verdict must finish within 200k");
        assertTrue(gate.consumed(a.requestId));
        ++verdicts;
        if (!approved) lastDenied[who % 4] = id;
    }

    function execute(uint256 who, bool paused) external {
        uint256 i = who % 4;
        address seller = actors[i];
        uint256 id = gate.openPlea(seller);
        if (dead || id == 0) return;
        CabalGate.Plea memory p = gate.pleas(id);
        if (p.status != CabalGate.Status.Approved || block.timestamp > p.expiresAt) return;
        simd.setPaused(paused);
        _begin();
        vm.prank(seller);
        uint256 received = gate.executeSell(0);
        assertGt(received, 0);
        expectedPLEA[i] -= p.amount;
        ++executedSells;
        _end();
        assertEq(gate.openPlea(seller), 0);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.Executed));
    }

    function appeal(uint256 who) external {
        uint256 i = who % 4;
        address seller = actors[i];
        uint256 id = lastDenied[i];
        if (dead || id == 0 || gate.openPlea(seller) != 0) return;
        CabalGate.Plea memory p = gate.pleas(id);
        if (p.appealed || block.timestamp >= uint256(p.verdictAt) + 4 hours) return;
        if (oracleAsset.balanceOf(seller) < 0.5 ether || imd.balanceOf(seller) < 0.35 ether) return;
        if (gate.factScore(seller, p.amount) < 25) return;
        vm.prank(seller);
        uint256 next = gate.appeal(id, p.amount, "Please reconsider; the rent is still due.");
        ++paidRequests;
        ++paidAppeals;
        assertTrue(gate.pleas(id).appealed);
        assertEq(gate.pleas(next).originalId, id);
    }

    function completeWithoutVerdict(uint256 who) external {
        address seller = actors[who % 4];
        uint256 id = gate.openPlea(seller);
        if (id == 0 || gate.pleas(id).status != CabalGate.Status.Pending) return;
        uint256 last = gate.lastVerdictAt();
        intake.completeWithoutVerdict(gate.pleas(id).intakeId);
        vm.prank(seller);
        gate.clearNoVerdict();
        assertEq(gate.openPlea(seller), 0);
        assertEq(gate.lastVerdictAt(), last);
        ++expirations;
    }

    function elapse(uint256 secondsForward, uint256 blocksForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 0, 6 hours));
        vm.roll(block.number + bound(blocksForward, 1, 100));
        hook.checkpoint();
    }

    function clear(uint256 who) external {
        vm.prank(actors[who % 4]);
        gate.clearNoVerdict();
    }

    function claim(uint256 who) external {
        uint256 i = who % 4;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[i ^ 1];
        proof[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
        if (didClaim[i]) {
            vm.expectRevert(PleaDistributor.InvalidClaim.selector);
            distributor.claim(actors[i], ENTITLEMENT, proof);
            return;
        }
        distributor.claim(actors[i], ENTITLEMENT, proof);
        expectedPLEA[i] += ENTITLEMENT;
        didClaim[i] = true;
        ++claims;
    }

    function rebalance(uint256 who) external {
        if (hook.retainedIMD() == 0 && hook.backstopConvertedIMD() == 0) return;
        address keeper = actors[who % 4];
        uint256 beforeBalance = imd.balanceOf(keeper);
        uint256 beforeTip = hook.lastTipAt();
        uint256 beforeReserve = hook.tipReserve();
        _begin();
        vm.prank(keeper);
        hook.rebalance();
        uint256 tip = imd.balanceOf(keeper) - beforeBalance;
        keeperTips += tip;
        assertLe(tip, 1 ether);
        assertLe(tip, beforeReserve);
        if (tip != 0) assertGe(block.timestamp, beforeTip + 1 hours);
        _end();
    }

    function donate(uint256 who, uint256 rawAmount) external {
        address donor = actors[who % 4];
        uint256 balance = imd.balanceOf(donor);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 1 ether ? balance : 1 ether);
        vm.prank(donor);
        imd.transfer(address(hook), amount);
        donatedIMD += amount;
    }

    function transfer(uint256 from, uint256 to, uint256 rawAmount) external {
        uint256 i = from % 4;
        uint256 j = (i + 1 + to % 3) % 4;
        uint256 balance = token.balanceOf(actors[i]);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        vm.prank(actors[i]);
        if (!dead) vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(actors[j], amount);
        if (dead) {
            expectedPLEA[i] -= amount;
            expectedPLEA[j] += amount;
        }
    }

    function kill() external {
        if (dead || block.timestamp < gate.lastVerdictAt() + 33 hours) {
            vm.expectRevert(CabalGate.CabalStillAlive.selector);
            gate.killCabal();
            return;
        }
        gate.killCabal();
        dead = true;
    }

    function sellFreely(uint256 who, uint256 rawAmount) external {
        uint256 i = who % 4;
        if (!dead || token.balanceOf(actors[i]) < 1 ether) return;
        // Stay inside the available IMD depth, including when actors received distributions.
        uint256 amount = bound(rawAmount, 1 ether, token.balanceOf(actors[i]) / 10 + 1 ether);
        if (amount > token.balanceOf(actors[i])) amount = token.balanceOf(actors[i]);
        _begin();
        vm.prank(actors[i]);
        assertGt(gate.sellFreely(amount, 0), 0);
        expectedPLEA[i] -= amount;
        ++freeSells;
        _end();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PleaInvariantTest is PleaFixture {
    using TransientStateLibrary for IPoolManager;
    PleaHandler internal handler;
    address[4] internal wallets;

    function setUp() public override {
        super.setUp();
        _afterLaunch();
        wallets = [ALICE, BOB, makeAddr("invariant carol"), makeAddr("invariant dave")];
        _fund(wallets[2]);
        _fund(wallets[3]);
        handler = new PleaHandler(token, gate, hook, distributor, simd, wallets);
        distributor.setMerkleRoot(handler.root());
        // Guarantee meaningful funded actors; these buys are included in the ghost ledger.
        for (uint256 i; i < 4; ++i) {
            handler.buy(i, 20 ether, false);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.submit.selector;
        selectors[2] = handler.verdict.selector;
        selectors[3] = handler.execute.selector;
        selectors[4] = handler.appeal.selector;
        selectors[5] = handler.completeWithoutVerdict.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.clear.selector;
        selectors[8] = handler.claim.selector;
        selectors[9] = handler.rebalance.selector;
        selectors[10] = handler.donate.selector;
        selectors[11] = handler.transfer.selector;
        selectors[12] = handler.kill.selector;
        selectors[13] = handler.sellFreely.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantConservationCustodyAndPleaLifecycle() public view {
        uint256 balances = token.balanceOf(address(manager)) + token.balanceOf(address(hook))
            + token.balanceOf(address(distributor)) + token.balanceOf(address(gate));
        uint256 imdBalances = imd.balanceOf(address(manager)) + imd.balanceOf(address(hook))
            + imd.balanceOf(address(gate)) + imd.balanceOf(address(this)) + imd.balanceOf(address(simd))
            + imd.balanceOf(address(stacker));
        uint256 feeBalances = feeToken.balanceOf(address(intake)) + feeToken.balanceOf(address(gate));
        for (uint256 i; i < 4; ++i) {
            balances += token.balanceOf(wallets[i]);
            imdBalances += imd.balanceOf(wallets[i]);
            feeBalances += feeToken.balanceOf(wallets[i]);
            assertEq(token.balanceOf(wallets[i]), handler.expectedPLEA(i), "actor ledger");
            assertEq(distributor.claimed(wallets[i]), handler.didClaim(i), "claim ledger");
            assertEq(manager.balanceOf(wallets[i], uint160(address(token))), 0, "no user PLEA claims");
            uint256 open = gate.openPlea(wallets[i]);
            if (open != 0) {
                CabalGate.Plea memory p = gate.pleas(open);
                assertEq(p.seller, wallets[i]);
                assertTrue(p.status == CabalGate.Status.Pending || p.status == CabalGate.Status.Approved);
            }
        }
        assertEq(balances, token.totalSupply(), "PLEA conservation");
        assertEq(token.totalSupply() + handler.burned(), token.SUPPLY(), "only observed burns change supply");
        assertEq(hook.totalBurned(), handler.burned());
        assertEq(imdBalances, imd.totalSupply(), "IMD conservation");
        assertEq(feeBalances, feeToken.totalSupply(), "oracle asset conservation");
        assertEq(feeToken.balanceOf(address(intake)), handler.paidRequests() * 0.5 ether, "exact paid requests");
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether - handler.claims() * handler.ENTITLEMENT());
        assertEq(imd.balanceOf(address(hook)), hook.retainedIMD() + handler.donatedIMD(), "retained cash is backed");
        assertEq(imd.balanceOf(address(this)), hook.totalOwnerFees(), "owner fees paid immediately");
        assertEq(stacker.projectStacked(address(hook)) + handler.plainCashback(), hook.totalCashback());
        assertLe(handler.keeperTips(), hook.totalLiquidityFees());
        assertGe(hook.inventoryCap(), hook.capFloor());
        assertEq(token.cabalDead(), handler.dead());
        assertEq(token.balanceOf(address(hook)), 0, "hook cannot warehouse PLEA");
        assertEq(token.balanceOf(address(gate)), 0, "gate cannot warehouse PLEA");
        assertEq(imd.balanceOf(address(gate)), 0, "gate settles all cash");
        assertEq(imd.balanceOf(address(stacker)), 0, "stacker settles all cash");
        assertEq(feeToken.balanceOf(address(gate)), 0);
        assertEq(feeToken.allowance(address(gate), address(intake)), 0);
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(imd))), 0);
        assertEq(pm.currencyDelta(address(gate), Currency.wrap(address(token))), 0);
        assertEq(pm.currencyDelta(address(gate), Currency.wrap(address(imd))), 0);
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(gate), uint160(address(token))), 0);
        for (uint256 id = 1; id < gate.nextPleaId(); ++id) {
            CabalGate.Plea memory p = gate.pleas(id);
            assertEq(gate.intakeToPlea(p.intakeId), id);
            bool receivedVerdict = p.status == CabalGate.Status.Approved || p.status == CabalGate.Status.Denied
                || p.status == CabalGate.Status.Executed || p.status == CabalGate.Status.Expired;
            assertEq(gate.consumed(keccak256(abi.encode("invariant oracle UUID", id))), receivedVerdict);
            if (p.status == CabalGate.Status.Pending || p.status == CabalGate.Status.Approved) {
                assertEq(gate.openPlea(p.seller), id, "one open plea per wallet");
            }
        }
    }

    function testHandlerExercisesAllValueMovingBranches() public {
        handler.claim(0);
        handler.submit(0, 1 ether);
        handler.verdict(0, false);
        handler.appeal(0);
        handler.verdict(0, true);
        handler.execute(0, false);
        handler.submit(1, 1 ether);
        handler.completeWithoutVerdict(1);
        handler.buy(2, 100 ether, true);
        handler.donate(2, 1 ether);
        handler.rebalance(3);
        for (uint256 i; i < 6; ++i) {
            handler.elapse(6 hours, 1);
        }
        handler.kill();
        handler.transfer(0, 1, 1 ether);
        handler.sellFreely(0, 1 ether);
        assertGt(handler.buys(), 4);
        assertEq(handler.paidRequests(), 3);
        assertEq(handler.paidAppeals(), 1);
        assertEq(handler.executedSells(), 1);
        assertEq(handler.freeSells(), 1);
        assertEq(handler.verdicts(), 2);
        assertEq(handler.expirations(), 1);
        assertGt(handler.plainCashback(), 0);
        invariantConservationCustodyAndPleaLifecycle();
    }
}
