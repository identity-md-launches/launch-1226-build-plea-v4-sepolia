// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PleaFixture} from "./fixtures/PleaFixture.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {PleaText} from "src/libraries/PleaText.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {IIntake} from "src/interfaces/IIntake.sol";

contract CabalAdversarialTest is PleaFixture {
    function setUp() public override {
        super.setUp();
        _afterLaunch();
    }

    function _pending() internal returns (uint256 id) {
        uint256 bought = _buy(ALICE, 10 ether);
        return _submit(ALICE, bought / 10);
    }

    function _reject(uint256 id, OracleAttestation.Attestation memory a, bytes memory signature, bytes memory error)
        internal
    {
        bytes32 request = gate.pleas(id).intakeId;
        uint256 last = gate.lastVerdictAt();
        vm.prank(address(intake));
        vm.expectRevert(error);
        gate.onOracleResult(request, a, signature);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.Pending));
        assertEq(gate.openPlea(ALICE), id);
        assertFalse(gate.consumed(a.requestId));
        assertEq(gate.lastVerdictAt(), last);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzRejectInconsistentSignedPanels(uint8 raw) public {
        uint256 id = _pending();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        uint256 variant = uint256(raw) % 7;
        if (variant == 0) {
            a.panelSize = 29;
        } else if (variant == 1) {
            a.quorum = 16;
        } else if (variant == 2) {
            a.agreed = 16;
        } else if (variant == 3) {
            a.quorum = 18;
            a.agreed = 17;
        } else if (variant == 4) {
            a.agreed = 31;
        } else if (variant == 5) {
            a.quorum = 31;
            a.agreed = 31;
        } else {
            a.chainId = 11155111;
        }
        _reject(id, a, _sig(a), abi.encodeWithSelector(CabalGate.InvalidPanel.selector));
    }

    function testWrongConsumerChainAndFutureIssuedAtLeavePleaPending() public {
        uint256 id = _pending();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _sig(a);
        vm.chainId(1);
        _reject(id, a, signature, abi.encodeWithSelector(CabalGate.InvalidPanel.selector));
        vm.chainId(11155111);
        a.issuedAt = uint64(block.timestamp + 5 minutes + 1);
        _reject(
            id,
            a,
            _sig(a),
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
    }

    function testValidBoundaryAttestationAndOpaqueQuestionHash() public {
        uint256 id = _pending();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp);
        a.questionHash = keccak256("resolved relative window deliberately differs from request body");
        (bool ok,) = intake.deliver(gate.pleas(id).intakeId, a, _sig(a));
        assertTrue(ok, "valid callback must finish in 200k");
        assertTrue(gate.consumed(a.requestId));
        assertEq(gate.pleas(id).expiresAt, block.timestamp + 7 minutes);
    }

    function testColdApproveAndDenyCallbacksFinishWithinStipend() public {
        uint256 aliceId = _pending();
        uint256 bobId = _submit(BOB, _buy(BOB, 10 ether) / 10);
        uint256[2] memory ids = [aliceId, bobId];
        for (uint256 i; i < ids.length; ++i) {
            OracleAttestation.Attestation memory a = _attestation(ids[i], i == 0);
            bytes memory signature = _sig(a);
            bytes32 request = gate.pleas(ids[i]).intakeId;
            vm.cool(address(gate));
            vm.cool(address(token));
            vm.cool(Addresses.SIGNER);
            (bool ok, bytes memory reason) = intake.deliver(request, a, signature);
            assertTrue(ok, string(reason));
            assertTrue(gate.consumed(a.requestId));
        }
        assertEq(uint256(gate.pleas(aliceId).status), uint256(CabalGate.Status.Approved));
        assertEq(uint256(gate.pleas(bobId).status), uint256(CabalGate.Status.Denied));
    }

    function testMalformedBoolDoesNotConsumeOrResetDeadman() public {
        uint256 id = _pending();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        a.answer = abi.encode(uint256(2));
        bytes memory signature = _sig(a);
        bytes32 request = gate.pleas(id).intakeId;
        uint256 last = gate.lastVerdictAt();
        vm.prank(address(intake));
        vm.expectRevert();
        gate.onOracleResult(request, a, signature);
        assertFalse(gate.consumed(a.requestId));
        assertEq(gate.lastVerdictAt(), last);
        assertEq(gate.openPlea(ALICE), id);
        a.answer = hex"01";
        signature = _sig(a);
        vm.prank(address(intake));
        vm.expectRevert();
        gate.onOracleResult(request, a, signature);
        assertFalse(gate.consumed(a.requestId));
    }

    function testBadDeliveredSignatureClearsWithoutRefundAndAllowsRetry() public {
        uint256 id = _pending();
        OracleAttestation.Attestation memory a = _attestation(id, true);
        bytes memory signature = _sig(a);
        a.answer = abi.encode(false);
        uint256 last = gate.lastVerdictAt();
        uint256 paidBalance = feeToken.balanceOf(ALICE);
        (bool ok, bytes memory reason) = intake.deliver(gate.pleas(id).intakeId, a, signature);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        vm.prank(ALICE);
        gate.clearNoVerdict();
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.NoVerdict));
        assertEq(gate.lastVerdictAt(), last);
        assertEq(feeToken.balanceOf(ALICE), paidBalance, "no imaginary oracle refund");
        uint256 next = _submit(ALICE, token.balanceOf(ALICE) / 10);
        assertEq(gate.openPlea(ALICE), next);
    }

    function testTwentyMinuteBoundaryAndStaleCallbackCannotRetireNewPlea() public {
        uint256 id = _pending();
        uint256 submitted = gate.pleas(id).submittedAt;
        uint256 last = gate.lastVerdictAt();
        vm.warp(submitted + 20 minutes - 1);
        vm.prank(ALICE);
        gate.clearNoVerdict();
        assertEq(gate.openPlea(ALICE), id);
        vm.prank(BOB);
        gate.clearNoVerdict();
        assertEq(gate.openPlea(ALICE), id, "another wallet cannot clear this plea");
        vm.warp(submitted + 20 minutes);
        uint256 next = _submit(ALICE, token.balanceOf(ALICE) / 10);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.NoVerdict));
        OracleAttestation.Attestation memory stale = _attestation(id, true);
        bytes32 oldRequest = gate.pleas(id).intakeId;
        // Retired deliveries are ignored even if their signature is unusable.
        vm.prank(address(intake));
        gate.onOracleResult(oldRequest, stale, hex"01");
        assertEq(gate.openPlea(ALICE), next);
        assertFalse(gate.consumed(stale.requestId));
        assertEq(gate.lastVerdictAt(), last);
    }

    function testApproveAndDenyExactlyBeforeTimeout() public {
        uint256 id = _pending();
        vm.warp(uint256(gate.pleas(id).submittedAt) + 20 minutes - 1);
        _verdict(id, false);
        assertEq(uint256(gate.pleas(id).status), uint256(CabalGate.Status.Denied));
        uint256 nextAllowed = gate.nextAllowedAt(ALICE);
        uint256 amount = token.balanceOf(ALICE) / 10;
        vm.warp(nextAllowed - 1);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Cooldown.selector);
        gate.submitSell(amount, "One second early");
        vm.warp(nextAllowed);
        uint256 next = _submit(ALICE, token.balanceOf(ALICE) / 10);
        vm.warp(uint256(gate.pleas(next).submittedAt) + 20 minutes - 1);
        _verdict(next, true);
        assertEq(uint256(gate.pleas(next).status), uint256(CabalGate.Status.Approved));
    }

    function testSellAtLastSecondThenCooldownBoundary() public {
        uint256 id = _pending();
        _verdict(id, true);
        vm.warp(gate.pleas(id).expiresAt);
        vm.prank(ALICE);
        uint256 out = gate.executeSell(0);
        assertGt(out, 0);
        uint256 next = gate.lastExecutedAt(ALICE) + 4 hours;
        uint256 amount = token.balanceOf(ALICE) / 10;
        vm.warp(next - 1);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.Cooldown.selector);
        gate.submitSell(amount, "Early");
        vm.warp(next);
        assertGt(_submit(ALICE, amount), id);
    }

    function testAppealPaymentFailureRollsBackOriginalAndLiquidity() public {
        uint256 id = _pending();
        _verdict(id, false);
        uint256 reserve = hook.retainedIMD();
        uint256 walletIMD = imd.balanceOf(ALICE);
        uint256 nextId = gate.nextPleaId();
        vm.prank(ALICE);
        feeToken.approve(address(gate), 0);
        uint256 amount = gate.pleas(id).amount;
        vm.prank(ALICE);
        vm.expectRevert();
        gate.appeal(id, amount, "Please reconsider.");
        assertFalse(gate.pleas(id).appealed);
        assertEq(hook.retainedIMD(), reserve);
        assertEq(imd.balanceOf(ALICE), walletIMD);
        assertEq(gate.nextPleaId(), nextId);
        assertEq(gate.openPlea(ALICE), 0);
        vm.prank(ALICE);
        feeToken.approve(address(gate), 0.5 ether);
        vm.prank(ALICE);
        uint256 appealed = gate.appeal(id, amount, "Please reconsider.");
        assertEq(gate.pleas(appealed).originalId, id);
        assertEq(hook.retainedIMD(), reserve + 0.35 ether);
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(feeToken.allowance(address(gate), address(intake)), 0);
    }

    function testIntakeZeroOrReusedIdRollsBackPaymentAndPlea() public {
        uint256 id = _pending();
        bytes32 reused = gate.pleas(id).intakeId;
        uint256 bobAmount = _buy(BOB, 10 ether) / 10;
        uint256 feeBefore = feeToken.balanceOf(BOB);
        uint256 nextId = gate.nextPleaId();
        for (uint256 i; i < 2; ++i) {
            vm.mockCall(
                address(intake), abi.encodePacked(IIntake.request.selector), abi.encode(i == 0 ? bytes32(0) : reused)
            );
            vm.prank(BOB);
            vm.expectRevert(CabalGate.UnknownRequest.selector);
            gate.submitSell(bobAmount, "Rent due.");
            assertEq(gate.nextPleaId(), nextId);
            assertEq(gate.openPlea(BOB), 0);
            assertEq(feeToken.balanceOf(BOB), feeBefore);
            assertEq(feeToken.balanceOf(address(gate)), 0);
        }
        vm.clearMockedCalls();
        assertEq(_submit(BOB, bobAmount), nextId);
    }

    function testCannotPassDoesNotChargeOrCreateRequest() public {
        uint256 balance = _buy(ALICE, 10 ether);
        uint256 fees = feeToken.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.CannotPass.selector);
        gate.submitSell(balance * 35 / 100, "Too young");
        assertEq(gate.nextPleaId(), 1);
        assertEq(gate.openPlea(ALICE), 0);
        assertEq(feeToken.balanceOf(ALICE), fees);
        assertEq(intake.lastBody().length, 0);
    }

    function testMongolianSelectorRejectsSubmissionAndAppealWithoutCharging() public {
        uint256 amount = _buy(ALICE, 10 ether) / 10;
        string memory hidden = string(bytes.concat(bytes("Rent is due"), hex"e1a08f")); // U+180F
        uint256 oracleBalance = feeToken.balanceOf(ALICE);
        uint256 nextId = gate.nextPleaId();
        vm.prank(ALICE);
        vm.expectRevert(PleaText.InvalidText.selector);
        gate.submitSell(amount, hidden);
        assertEq(feeToken.balanceOf(ALICE), oracleBalance);
        assertEq(gate.nextPleaId(), nextId);
        assertEq(gate.openPlea(ALICE), 0);
        assertEq(intake.lastBody().length, 0);

        uint256 id = _submit(ALICE, amount);
        _verdict(id, false);
        uint256 cash = imd.balanceOf(ALICE);
        uint256 retained = hook.retainedIMD();
        uint256 cooldown = gate.nextAllowedAt(ALICE);
        bytes memory body = intake.lastBody();
        vm.prank(ALICE);
        vm.expectRevert(PleaText.InvalidText.selector);
        gate.appeal(id, amount, hidden);
        assertEq(feeToken.balanceOf(ALICE), oracleBalance - 0.5 ether);
        assertEq(imd.balanceOf(ALICE), cash);
        assertEq(hook.retainedIMD(), retained);
        assertEq(gate.nextAllowedAt(ALICE), cooldown);
        assertEq(gate.nextPleaId(), id + 1);
        assertEq(gate.openPlea(ALICE), 0);
        assertFalse(gate.pleas(id).appealed);
        assertEq(intake.lastBody(), body);
        vm.prank(ALICE);
        uint256 appealId = gate.appeal(id, amount, "A visible plea remains eligible.");
        assertEq(gate.pleas(appealId).originalId, id);
        assertTrue(gate.pleas(id).appealed);
    }

    function testAbsoluteSellMaximumAppliesEvenToLargeWallets() public {
        uint256 balance = _buy(ALICE, 1000 ether);
        uint256 maximum = 2_500_000 ether;
        assertGt(balance * 15 / 100, maximum);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.InvalidAmount.selector);
        gate.submitSell(maximum + 1, "Only one wei too much.");
        uint256 id = _submit(ALICE, maximum);
        assertEq(gate.pleas(id).amount, maximum);
    }

    function testExecutedSellReducesBasisProportionallyAndKeepsHoldingClock() public {
        uint256 id = _pending();
        uint256 oldBalance = token.balanceOf(ALICE);
        uint256 amount = gate.pleas(id).amount;
        uint256 oldBasis = hook.costBasis(ALICE);
        uint256 boughtAt = hook.averageBuyTime(ALICE);
        _verdict(id, true);
        vm.prank(ALICE);
        gate.executeSell(0);
        assertEq(hook.costBasis(ALICE), oldBasis * (oldBalance - amount) / oldBalance);
        assertEq(hook.averageBuyTime(ALICE), boughtAt);
        assertEq(token.balanceOf(ALICE), oldBalance - amount);
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(token.balanceOf(address(gate)), 0);
    }

    function testDeadmanBoundaryRetiresSellAuthorityAndCannotBeUndone() public {
        uint256 id = _pending();
        uint256 last = gate.lastVerdictAt();
        vm.warp(last + 33 hours - 1);
        vm.expectRevert(CabalGate.CabalStillAlive.selector);
        gate.killCabal();
        vm.warp(last + 33 hours);
        vm.prank(BOB);
        gate.killCabal();
        _verdict(id, true);
        assertTrue(token.cabalDead());
        assertEq(gate.lastVerdictAt(), last);
        assertFalse(gate.consumed(_attestation(id, true).requestId));
        vm.expectRevert(CabalGate.CabalStillAlive.selector);
        gate.killCabal();
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.SellUnavailable.selector);
        gate.executeSell(0);
        vm.prank(ALICE);
        vm.expectRevert(CabalGate.NotReady.selector);
        gate.submitSell(1 ether, "No oracle is needed");
        vm.prank(ALICE);
        assertGt(gate.sellFreely(1 ether, 0), 0);
    }

    function testUnauthorizedAccountingAndAdminCallsCannotChangeFunds() public {
        vm.startPrank(ALICE);
        vm.expectRevert(PLEA.Unauthorized.selector);
        token.allow(ALICE);
        vm.expectRevert(PLEA.Unauthorized.selector);
        token.burn(0);
        vm.expectRevert(PLEA.Unauthorized.selector);
        token.killCabal();
        vm.expectRevert(PleaDistributor.Unauthorized.selector);
        distributor.setMerkleRoot(keccak256("fake"));
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.recordDistribution(ALICE, 100 ether);
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.recordSell(ALICE, 0, 1 ether);
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.fundLiquidity(1 ether);
        vm.stopPrank();
        assertFalse(token.allowed(ALICE));
        assertFalse(token.cabalDead());
        assertEq(hook.costBasis(ALICE), 0);
        assertEq(hook.averageBuyTime(ALICE), 0);
    }
}
