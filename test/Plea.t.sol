// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Addresses} from "../src/libraries/Addresses.sol";
import {PleaText} from "../src/libraries/PleaText.sol";
import {HostileRouter} from "./fixtures/HostileRouter.sol";
import {MineSalt} from "../script/MineSalt.s.sol";
import {TestAsset, TestSIMD, MockIntake, TestOracleSigner} from "./fixtures/Mocks.sol";
import {Stacker, IStakedIMD} from "./fixtures/Stacker.sol";

import {PleaFixture} from "./fixtures/PleaFixture.sol";

contract PleaTest is PleaFixture {
    function testLaunchAllocationAndLimits() public view {
        assertEq(token.launcher(), address(launch));
        assertEq(token.hook(), address(hook));
        assertEq(token.gate(), address(gate));
        assertEq(token.distributor(), address(distributor));
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether);
        assertApproxEqAbs(hook.tokensInPool(), 900_000_000 ether, 1000);
        assertLe(address(token).code.length, 24_576);
        assertLe(address(gate).code.length, 24_576);
        assertLe(address(launch).code.length, 24_576);
        assertLe(address(hook).code.length, 24_576);
        assertEq(hook.poolKey().fee, 0);
        assertEq(hook.capFloor(), 900_000 ether);
        assertEq(hook.capDecay(), 300_000 ether);
        assertApproxEqAbs(hook.latestPrice(), 5700e18 / 1_000_000_000, 1);
    }

    function testSetLauncherOutsideConstructorTransactionFails() public {
        vm.expectRevert(PLEA.Unauthorized.selector);
        orphan.setLauncher(address(this));
    }

    function testBuyStacksAndDeliversWithoutClaims() public {
        _afterLaunch();
        uint256 beforeSupply = token.totalSupply();
        vm.recordLogs();
        uint256 out = _buy(ALICE, 10 ether);
        assertGt(out, 0);
        assertEq(token.balanceOf(ALICE), out);
        assertGt(simd.balanceOf(ALICE), 0);
        assertEq(stacker.stackedBy(address(hook), ALICE), 10 ether / 200);
        assertEq(imd.balanceOf(address(this)), 10 ether / 200);
        assertEq(hook.retainedIMD(), 10 ether / 400);
        assertEq(token.totalSupply(), beforeSupply - (out * 10000 / 9975) / 400);
        assertEq(manager.balanceOf(ALICE, uint256(uint160(address(token)))), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(stacker)
                    && logs[i].topics[0] == keccak256("Stacked(address,address,uint256,uint256)")
            ) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(hook)))));
                found = true;
            }
        }
        assertTrue(found);
    }

    function testPausedCreditPaysPlainIMDOnlyOnRevert() public {
        _afterLaunch();
        simd.setPaused(true);
        uint256 before = imd.balanceOf(ALICE);
        _buy(ALICE, 10 ether);
        assertEq(simd.balanceOf(ALICE), 0);
        assertEq(imd.balanceOf(ALICE), before - 10 ether + 0.05 ether);
    }

    function testBuyLowGasRevertsInsteadOfSkippingCashback() public {
        _afterLaunch();
        uint160 limit = _limit();
        vm.prank(ALICE);
        (bool ok,) = address(gate).call{gas: 1_800_000}(abi.encodeCall(gate.buy, (10 ether, 1, limit)));
        assertFalse(ok);
        assertEq(token.balanceOf(ALICE), 0);
        _buy(ALICE, 10 ether);
        assertGt(simd.balanceOf(ALICE), 0);
    }

    function testApproveAndExecuteUnderCallbackStipend() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 amount = balance / 10;
        uint256 id = _submit(ALICE, amount);
        _verdict(id, true);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.Approved));
        uint256 before = imd.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = gate.executeSell(0.5 ether);
        assertGt(out, 0.5 ether);
        assertEq(imd.balanceOf(ALICE) - before, out);
        assertEq(token.balanceOf(ALICE), balance - amount);
        assertEq(gate.openPlea(ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Cooldown.selector);
        gate.submitSell(amount, "Again");
    }

    function testDenyAppealAndFee() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        _verdict(id, false);
        uint256 before = hook.retainedIMD();
        vm.prank(ALICE);
        uint256 appealId = gate.appeal(id, balance / 11, "Please reconsider my rent.");
        assertEq(hook.retainedIMD() - before, 0.35 ether);
        assertTrue(gate.pleas(id).appealed);
        assertEq(gate.pleas(appealId).originalId, id);
        assertTrue(_contains(string(intake.lastBody()), "DENIED"));
        _verdict(appealId, true);
        vm.prank(ALICE);
        gate.executeSell(0);
    }

    function testCannotPassLargeFreshSale() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.CannotPass.selector);
        gate.submitSell(balance * 35 / 100, "Too soon");
    }

    function testNoVerdictCompletedAndLateCallbackIgnored() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        bytes32 request = gate.pleas(id).intakeId;
        intake.completeWithoutVerdict(request);
        vm.prank(ALICE);
        gate.clearNoVerdict();
        assertEq(gate.openPlea(ALICE), 0);
        uint256 newId = _submit(ALICE, balance / 10);
        _verdict(id, true);
        assertEq(gate.openPlea(ALICE), newId);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.NoVerdict));
    }

    function testNoVerdictTimeoutAndLateCallbackIgnored() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        vm.warp(block.timestamp + 20 minutes);
        _verdict(id, true);
        assertEq(gate.openPlea(ALICE), 0);
        _submit(ALICE, balance / 10);
    }

    function testWrongSenderUnknownReplayTamperedAndExpired() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory sig = _sig(a);
        bytes32 request = gate.pleas(id).intakeId;
        vm.expectRevert(CabalGate.Unauthorized.selector);
        gate.onOracleResult(request, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.UnknownRequest.selector);
        gate.onOracleResult(bytes32(uint256(8)), a, sig);
        a.figure = 1;
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.onOracleResult(request, a, sig);
        a.figure = 0;
        a.expiresAt = uint64(block.timestamp - 1);
        sig = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        gate.onOracleResult(request, a, sig);
        _verdict(id, true);
        a = _attestation(id, true);
        sig = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.SettledRequest.selector);
        gate.onOracleResult(request, a, sig);
    }

    function testTransferAndTransferFromCannotBypass() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        vm.startPrank(ALICE);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(BOB, 1 ether);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(address(manager), 1 ether);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(address(gate), 1 ether);
        token.approve(BOB, type(uint256).max);
        vm.stopPrank();
        vm.prank(BOB);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transferFrom(ALICE, BOB, 1 ether);
        token.allow(ALICE);
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(address(manager), 1 ether);
    }

    function testDeadmanFreesTransfers() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        vm.expectRevert(CabalGate.CabalStillAlive.selector);
        gate.killCabal();
        vm.warp(gate.lastVerdictAt() + 33 hours);
        vm.prank(BOB);
        gate.killCabal();
        assertTrue(token.cabalDead());
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        vm.prank(BOB);
        token.transfer(address(manager), 1 ether);
    }

    function testLaunchFeeDecayAndMaxBuy() public {
        assertEq(hook.launchFeeBps(), 7000);
        _buy(ALICE, 10 ether);
        assertGt(hook.retainedIMD(), 7 ether);
        vm.warp(hook.seededAt() + 45 minutes);
        assertEq(hook.launchFeeBps(), 3500);
        uint160 limit = _limit();
        vm.prank(BOB);
        vm.expectRevert();
        gate.buy(1000 ether, 0, limit);
        vm.warp(hook.seededAt() + 90 minutes);
        assertEq(hook.launchFeeBps(), 0);
    }

    function testDistributorRootOnceProofAndReplay() public {
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(ALICE, 10 ether))));
        distributor.setMerkleRoot(root);
        bytes32[] memory proof = new bytes32[](0);
        distributor.claim(ALICE, 10 ether, proof);
        assertEq(token.balanceOf(ALICE), 10 ether);
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.claim(ALICE, 10 ether, proof);
        vm.expectRevert(PleaDistributor.RootAlreadySet.selector);
        distributor.setMerkleRoot(root);
    }

    function testCheckpointAndWeightedBasis() public {
        _afterLaunch();
        uint256 first = _buy(ALICE, 10 ether);
        uint256 when = hook.averageBuyTime(ALICE);
        uint256 oldPrice = hook.latestPrice();
        _buy(BOB, 100 ether);
        assertEq(hook.latestPrice(), oldPrice);
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        hook.checkpoint();
        uint256 second = _buy(ALICE, 10 ether);
        assertEq(hook.averageBuyTime(ALICE), (when * first + vm.getBlockTimestamp() * second) / (first + second));
        assertEq(hook.costBasis(ALICE), 20 ether);
    }

    function testRebalanceRetainsLiquidityAndDoesNotPayForRecycling() public {
        _afterLaunch();
        _buy(ALICE, 500 ether);
        uint256 before = imd.balanceOf(BOB);
        vm.prank(BOB);
        hook.rebalance();
        (,, uint128 liq, uint256 principal) = hook.backstop();
        assertGt(liq, 0);
        assertGt(principal, 0);
        assertEq(imd.balanceOf(BOB), before); // Only 1.25 IMD moved: below 100 IMD.
        vm.prank(BOB);
        hook.rebalance();
        assertEq(imd.balanceOf(BOB), before);
    }

    function testDeploymentTransactionsBelowMainnetGasCeiling() public {
        uint256 gasBefore = gasleft();
        PLEA t = new PLEA(address(this));
        CabalGate g = new CabalGate(address(t));
        PleaDistributor d = new PleaDistributor(address(t), address(this));
        PleaLaunch l = new PleaLaunch(address(t), address(g), address(d), START);
        uint256 launchGas = gasBefore - gasleft();
        emit log_named_uint("four-constructor execution gas", launchGas);
        // Include conservative intrinsic calldata cost for every byte of all four initcodes.
        uint256 calldataGas =
            (type(PLEA).creationCode.length
                    + type(CabalGate).creationCode.length
                    + type(PleaDistributor).creationCode.length
                    + type(PleaLaunch).creationCode.length
                    + 512) * 16 + 21_000;
        assertLt(launchGas + calldataGas, 16_700_000);
        bytes memory initcode = miner.initcode(address(t), address(g), address(this));
        (bool found, bytes32 mined,,) = miner.run(address(l), keccak256(initcode), 0, 200_000);
        assertTrue(found);
        gasBefore = gasleft();
        l.deployHook(mined, initcode);
        uint256 hookGas = gasBefore - gasleft();
        emit log_named_uint("deployHook execution gas", hookGas);
        assertLt(hookGas + initcode.length * 16 + 21_000, 16_700_000);
        gasBefore = gasleft();
        l.seed();
        uint256 seedGas = gasBefore - gasleft();
        emit log_named_uint("seed execution gas", seedGas);
        assertLt(seedGas + 21_000, 16_700_000);
    }

    function testWrongInitcodeSaltAndNonOwnerSeedBeforeStart() public {
        PLEA t = new PLEA(address(this));
        CabalGate g = new CabalGate(address(t));
        PleaDistributor d = new PleaDistributor(address(t), address(this));
        PleaLaunch l = new PleaLaunch(address(t), address(g), address(d), START);
        bytes memory initcode = miner.initcode(address(t), address(g), address(this));
        vm.expectRevert(PleaLaunch.InvalidInitcode.selector);
        l.deployHook(bytes32(0), hex"1234");
        bytes32 wrong;
        while (uint160(l.predictHook(wrong)) & Addresses.HOOK_MASK == Addresses.HOOK_FLAGS) {
            wrong = bytes32(uint256(wrong) + 1);
        }
        vm.expectRevert(PleaLaunch.InvalidSalt.selector);
        l.deployHook(wrong, initcode);
        (bool found, bytes32 mined,,) = miner.run(address(l), keccak256(initcode), 0, 200_000);
        assertTrue(found);
        l.deployHook(mined, initcode);
        vm.prank(ALICE);
        vm.expectRevert(PleaLaunch.NotOpen.selector);
        l.seed();
        vm.warp(START);
        vm.prank(ALICE);
        l.seed();
        vm.expectRevert(PleaLaunch.AlreadyDeployed.selector);
        l.deployHook(mined, initcode);
        vm.expectRevert(PleaLaunch.NotOpen.selector);
        l.seed();
        vm.expectRevert(PLEA.Unauthorized.selector);
        t.init(address(hook));
    }

    function testPartialBuyPaysFeesOnlyOnActualFill() public {
        _afterLaunch();
        uint160 price = hook.currentSqrtPriceX96();
        uint160 limit = hook.plea0() ? uint160(uint256(price) * 1005 / 1000) : uint160(uint256(price) * 1000 / 1005);
        uint256 before = imd.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = gate.buy(1000 ether, 1, limit);
        uint256 paid = before - imd.balanceOf(ALICE);
        assertGt(out, 0);
        assertLt(paid, 1000 ether);
        assertEq(hook.costBasis(ALICE), paid);
        assertEq(stacker.stackedBy(address(hook), ALICE), paid / 200);
        assertEq(imd.balanceOf(address(this)), paid / 200);
        assertApproxEqAbs(hook.retainedIMD(), paid / 400, 3);
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(token.balanceOf(address(gate)), 0);
    }

    function testSlippageAndPartialSellFailuresAreAtomic() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        _verdict(id, true);
        uint256 supply = token.totalSupply();
        uint256 cost = hook.costBasis(ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        gate.executeSell(100 ether);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.totalSupply(), supply);
        assertEq(hook.costBasis(ALICE), cost);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.Approved));
        uint160 limit = _limit();
        vm.prank(BOB);
        vm.expectRevert(CabalGate.Slippage.selector);
        gate.buy(10 ether, 1_000_000_000 ether, limit);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(simd.balanceOf(BOB), 0);
    }

    function testAppealWindowAmountAndOnceOnly() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 amount = balance / 10;
        uint256 id = _submit(ALICE, amount);
        _verdict(id, false);
        vm.prank(BOB);
        vm.expectRevert(CabalGate.AppealUnavailable.selector);
        gate.appeal(id, amount, "Not mine");
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.AppealUnavailable.selector);
        gate.appeal(id, amount + 1, "Too much");
        vm.prank(ALICE);
        uint256 second = gate.appeal(id, amount, "Please reconsider");
        _verdict(second, false);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.AppealUnavailable.selector);
        gate.appeal(id, amount, "Twice");
        vm.warp(uint256(gate.pleas(second).verdictAt) + 4 hours);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.AppealUnavailable.selector);
        gate.appeal(second, amount, "Late");
    }

    function testApprovedWindowExpiresAndCannotExecuteTwice() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        _verdict(id, true);
        vm.warp(uint256(gate.pleas(id).expiresAt) + 1);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.SellUnavailable.selector);
        gate.executeSell(0);
        uint256 second = _submit(ALICE, balance / 10);
        _verdict(second, true);
        vm.prank(ALICE);
        gate.executeSell(0);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.SellUnavailable.selector);
        gate.executeSell(0);
    }

    function testPendingOnePerWalletAndAmountLimits() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidAmount.selector);
        gate.submitSell(0, "Zero");
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidAmount.selector);
        gate.submitSell(balance * 35 / 100 + 1, "Too big");
        _submit(ALICE, balance / 10);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.OpenPlea.selector);
        gate.submitSell(balance / 10, "Twice");
    }

    function testPanelThresholdBoolTypeAndUUIDReplay() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 id = _submit(ALICE, balance / 10);
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes32 request = gate.pleas(id).intakeId;
        a.panelSize = 29;
        bytes memory signature = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.InvalidPanel.selector);
        gate.onOracleResult(request, a, signature);
        a.panelSize = 30;
        a.quorum = 16;
        signature = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.InvalidPanel.selector);
        gate.onOracleResult(request, a, signature);
        a.quorum = 18;
        a.agreed = 17;
        signature = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.InvalidPanel.selector);
        gate.onOracleResult(request, a, signature);
        a.quorum = 17;
        a.answerType = 3;
        signature = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(0), uint8(3)));
        gate.onOracleResult(request, a, signature);
        _verdict(id, false);
        vm.warp(uint256(gate.pleas(id).verdictAt) + 4 hours);
        uint256 second = _submit(ALICE, balance / 10);
        a = _attestation(id, true);
        signature = _sig(a);
        request = gate.pleas(second).intakeId;
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        gate.onOracleResult(request, a, signature);
    }

    function testBodyMatchesProtocolAndUsesSeparateFeeAsset() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 imdBefore = imd.balanceOf(ALICE);
        uint256 feeBefore = feeToken.balanceOf(ALICE);
        uint256 id = _submit(ALICE, balance / 10);
        string memory json = string(intake.lastBody());
        assertEq(imd.balanceOf(ALICE), imdBefore);
        assertEq(feeToken.balanceOf(ALICE), feeBefore - 0.5 ether);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastAsset(), Addresses.ORACLE_ASSET);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonUint(json, ".window.hours"), 1);
        assertEq(vm.parseJsonAddress(json, ".consumer.verifyingContract"), address(gate));
        assertTrue(vm.parseJsonBool(json, ".allowAmbiguous"));
        assertTrue(_contains(vm.parseJsonString(json, ".question"), "FACT SCORE"));
        assertEq(gate.intakeToPlea(gate.pleas(id).intakeId), id);
    }

    function testFactScoreThresholdsHoldAndCheckpointNotSpot() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 fresh = gate.factScore(ALICE, balance * 15 / 100);
        assertEq(fresh - gate.factScore(ALICE, balance * 25 / 100), 7);
        assertEq(fresh - gate.factScore(ALICE, balance * 35 / 100), 13);
        uint256 boughtAt = hook.averageBuyTime(ALICE);
        vm.warp(boughtAt + 1 days);
        assertEq(gate.factScore(ALICE, balance * 15 / 100), fresh + 5);
        vm.warp(boughtAt + 3 days);
        assertEq(gate.factScore(ALICE, balance * 15 / 100), fresh + 9);
        vm.warp(boughtAt + 7 days);
        assertEq(gate.factScore(ALICE, balance * 15 / 100), fresh + 14);
        uint256 checkpointPrice = hook.latestPrice();
        _buy(BOB, 1000 ether);
        // The buy can create an hourly checkpoint before its swap, but cannot score its own new spot.
        assertEq(hook.latestPrice(), checkpointPrice);
    }

    function testCapTrimPriceNeutralAndRateLimited() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 100 ether);
        uint256 cap0 = hook.inventoryCap();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(block.number + 1);
        _buy(BOB, 1 ether);
        assertLe(cap0 - hook.inventoryCap(), 300_000 ether + 1);
        uint256 id = _submit(ALICE, balance / 10);
        _verdict(id, true);
        uint256 supply = token.totalSupply();
        vm.prank(ALICE);
        gate.executeSell(0);
        assertLt(token.totalSupply(), supply);
        assertLe(hook.tokensInPool(), hook.inventoryCap() + 1000);
        assertGe(hook.inventoryCap(), hook.capFloor());
        uint256 cap1 = hook.inventoryCap();
        _buy(BOB, 0.1 ether);
        _buy(BOB, 0.1 ether);
        assertLe(cap1 - hook.inventoryCap(), 300_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testKeeperTipWorkThresholdHourlyAndFeeBound() public {
        _afterLaunch();
        _buy(ALICE, 50_000 ether);
        uint256 before = imd.balanceOf(BOB);
        uint256 reserve = hook.tipReserve();
        vm.prank(BOB);
        hook.rebalance();
        uint256 tip = imd.balanceOf(BOB) - before;
        assertGt(tip, 0);
        assertLe(tip, 1 ether);
        assertLe(tip, reserve);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        before = imd.balanceOf(BOB);
        vm.prank(BOB);
        hook.rebalance();
        assertEq(imd.balanceOf(BOB), before);
    }

    function testVerdictsResetDeadmanNoVerdictDoesNot() public {
        _afterLaunch();
        uint256 balance = _buy(ALICE, 10 ether);
        vm.warp(gate.lastVerdictAt() + 32 hours);
        uint256 id = _submit(ALICE, balance / 10);
        _verdict(id, false);
        uint256 last = gate.lastVerdictAt();
        assertEq(last, vm.getBlockTimestamp());
        vm.warp(last + 32 hours);
        vm.expectRevert(CabalGate.CabalStillAlive.selector);
        gate.killCabal();
        id = _submit(ALICE, balance / 10);
        intake.completeWithoutVerdict(gate.pleas(id).intakeId);
        vm.prank(ALICE);
        gate.clearNoVerdict();
        assertEq(gate.lastVerdictAt(), last);
        vm.warp(last + 33 hours);
        gate.killCabal();
    }

    function testNoForbiddenRuntimeOpcodes() public view {
        address[5] memory contracts_ =
            [address(token), address(gate), address(distributor), address(launch), address(hook)];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory runtime = contracts_[i].code;
            for (uint256 j; j < runtime.length; ++j) {
                uint8 op = uint8(runtime[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function testPoolInitializationAndLiquidityRestricted() public {
        PoolKey memory key = hook.poolKey();
        uint160 price = hook.currentSqrtPriceX96();
        vm.expectRevert();
        manager.initialize(key, price);
        HostileRouter router = new HostileRouter();
        uint160 limit = _limit();
        vm.expectRevert();
        router.attack(hook, 2, abi.encode(ALICE), limit);
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.seed();
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(uint8(1)));
        vm.expectRevert(CabalGate.Unauthorized.selector);
        gate.unlockCallback("");
    }

    function testV2RouterPermit2AndHooklessFundingCannotBypass() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        HostileRouter router = new HostileRouter();
        address pair = makeAddr("v2 pair");
        address permit2 = address(router);
        vm.prank(ALICE);
        token.approve(permit2, type(uint256).max);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        router.pull(address(token), ALICE, pair, 1 ether);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        router.pull(address(token), ALICE, address(manager), 1 ether);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        router.pull(address(token), ALICE, address(gate), 1 ether);
        PoolKey memory key = hook.poolKey();
        key.hooks = IHooks(address(0));
        manager.initialize(key, hook.currentSqrtPriceX96());
        vm.prank(ALICE);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        token.transfer(address(manager), 1 ether);
    }

    function testERC6909MintAndMalformedHookDataCannotBypass() public {
        _afterLaunch();
        HostileRouter router = new HostileRouter();
        imd.mint(address(router), 100 ether);
        uint160 limit = _limit();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        router.attack(hook, 1, abi.encode(ALICE), limit);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(manager.balanceOf(address(router), uint256(uint160(address(token)))), 0);
        vm.expectRevert();
        router.attack(hook, 0, "", limit);
        vm.expectRevert();
        router.attack(hook, 0, abi.encode(ALICE, BOB), limit);
        vm.expectRevert();
        router.attack(hook, 0, abi.encode(address(manager)), limit);
        vm.expectRevert();
        router.attack(hook, 3, abi.encode(ALICE), limit);
        router.attack(hook, 0, abi.encode(ALICE), limit);
        assertGt(token.balanceOf(ALICE), 0);
    }

    function testFuzzRoundTripConservesIMDAndBurns(uint96 rawAmount) public {
        _afterLaunch();
        uint256 input = bound(uint256(rawAmount), 0.01 ether, 30 ether);
        uint256 supplyBefore = token.totalSupply();
        uint256 balance = _buy(ALICE, input);
        uint256 amount = balance / 10;
        uint256 id = _submit(ALICE, amount);
        _verdict(id, true);
        vm.prank(ALICE);
        gate.executeSell(0);
        assertEq(token.balanceOf(ALICE), balance - amount);
        assertLt(token.totalSupply(), supplyBefore);
        assertEq(
            imd.totalSupply(),
            imd.balanceOf(ALICE) + imd.balanceOf(BOB) + imd.balanceOf(address(this)) + imd.balanceOf(address(manager))
                + imd.balanceOf(address(hook)) + imd.balanceOf(address(simd))
        );
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(token.balanceOf(address(gate)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function testOppositeTokenOrderBuySellAndWall() public {
        assertFalse(hook.plea0(), "base fixture must exercise IMD first");
        bytes32 initHash = keccak256(bytes.concat(type(PLEA).creationCode, abi.encode(address(this))));
        bytes32 tokenSalt;
        for (uint256 i;; ++i) {
            tokenSalt = bytes32(i);
            bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(this), tokenSalt, initHash));
            address predicted = address(uint160(uint256(digest)));
            if (predicted < Addresses.IMD) break;
        }
        PLEA t = new PLEA{salt: tokenSalt}(address(this));
        CabalGate g = new CabalGate(address(t));
        PleaDistributor d = new PleaDistributor(address(t), address(this));
        PleaLaunch l = new PleaLaunch(address(t), address(g), address(d), START);
        bytes memory initcode = miner.initcode(address(t), address(g), address(this));
        (bool found, bytes32 mined,,) = miner.run(address(l), keccak256(initcode), 0, 200_000);
        assertTrue(found);
        l.deployHook(mined, initcode);
        l.seed();
        PleaHook h = PleaHook(l.hook());
        assertTrue(h.plea0());
        assertApproxEqAbs(h.latestPrice(), 5700e18 / 1_000_000_000, 1);
        vm.warp(h.seededAt() + 90 minutes);
        vm.roll(block.number + 1);
        vm.startPrank(ALICE);
        imd.approve(address(g), type(uint256).max);
        feeToken.approve(address(g), type(uint256).max);
        t.approve(address(g), type(uint256).max);
        uint256 bought = g.buy(10 ether, 1, TickMath.MAX_SQRT_PRICE - 1);
        uint256 id = g.submitSell(bought / 10, "Keep most, sell a little.");
        vm.stopPrank();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(SIGN_KEY, g.attestationDigest(a));
        (bool ok,) = intake.deliver(g.pleas(id).intakeId, a, abi.encodePacked(r, sigS, v));
        assertTrue(ok);
        vm.prank(ALICE);
        assertGt(g.executeSell(0.5 ether), 0.5 ether);
        h.rebalance();
        (,, uint128 liq, uint256 principal) = h.backstop();
        assertGt(liq, 0);
        assertGt(principal, 0);
        assertEq(t.balanceOf(address(g)), 0);
        assertEq(t.balanceOf(address(h)), 0);
    }

    function testMeasuredFirstCreditFitsFixedBudget() public {
        imd.mint(address(this), 1 ether);
        imd.approve(address(stacker), 1 ether);
        uint256 gasBefore = gasleft();
        stacker.credit{gas: 2_000_000}(BOB, 1 ether);
        uint256 spent = gasBefore - gasleft();
        emit log_named_uint("first-credit fixture gas", spent);
        assertGt(spent, 1_100_000);
        assertLt(spent, hook.CREDIT_GAS());
    }

    function testDistributionHoldingClockAllowsLaterPlea() public {
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(ALICE, 100 ether))));
        distributor.setMerkleRoot(root);
        distributor.claim(ALICE, 100 ether, new bytes32[](0));
        assertEq(hook.costBasis(ALICE), 0);
        uint256 receivedAt = hook.averageBuyTime(ALICE);
        assertEq(receivedAt, vm.getBlockTimestamp());
        vm.warp(receivedAt + 7 days);
        assertEq(gate.factScore(ALICE, 10 ether), 37);
        _submit(ALICE, 10 ether);
    }

    function testExactFactProfitAndTrendBoundaries() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        vm.mockCall(address(token), abi.encodeCall(token.balanceOf, (ALICE)), abi.encode(100 ether));
        vm.mockCall(address(hook), abi.encodeCall(hook.costBasis, (ALICE)), abi.encode(100 ether));
        uint256[4] memory prices = [uint256(0.99 ether), 1.5 ether, 3 ether, 3 ether + 1];
        uint256[4] memory scores = [uint256(37), 32, 28, 23];
        for (uint256 i; i < 4; ++i) {
            vm.mockCall(address(hook), abi.encodeCall(hook.latestPrice, ()), abi.encode(prices[i]));
            vm.mockCall(address(hook), abi.encodeCall(hook.price24hAgo, ()), abi.encode(prices[i]));
            assertEq(gate.factScore(ALICE, 10 ether), scores[i]);
        }
        vm.mockCall(address(hook), abi.encodeCall(hook.price24hAgo, ()), abi.encode(1 ether));
        vm.mockCall(address(hook), abi.encodeCall(hook.latestPrice, ()), abi.encode(1.02 ether));
        assertEq(gate.factScore(ALICE, 10 ether), 32);
        vm.mockCall(address(hook), abi.encodeCall(hook.latestPrice, ()), abi.encode(1.02 ether + 1));
        assertEq(gate.factScore(ALICE, 10 ether), 36);
        vm.mockCall(address(hook), abi.encodeCall(hook.latestPrice, ()), abi.encode(0.98 ether));
        assertEq(gate.factScore(ALICE, 10 ether), 37);
        vm.mockCall(address(hook), abi.encodeCall(hook.latestPrice, ()), abi.encode(0.98 ether - 1));
        assertEq(gate.factScore(ALICE, 10 ether), 32);
        vm.clearMockedCalls();
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (a.length < b.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
