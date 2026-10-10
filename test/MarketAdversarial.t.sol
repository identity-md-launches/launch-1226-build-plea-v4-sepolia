// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PleaFixture} from "./fixtures/PleaFixture.sol";
import {HostileRouter} from "./fixtures/HostileRouter.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";

contract MarketAdversarialTest is PleaFixture {
    function _hookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function testUnderfundedGasGuardIsExplicitAndAtomicEvenWhenVaultPaused() public {
        _afterLaunch();
        uint160 limit = _limit();
        uint256 initialCash = imd.balanceOf(ALICE);
        uint256 initialSupply = token.totalSupply();
        for (uint256 i; i < 2; ++i) {
            simd.setPaused(i == 1);
            vm.prank(ALICE);
            (bool ok, bytes memory reason) =
                address(gate).call{gas: 1_800_000}(abi.encodeCall(gate.buy, (10 ether, 1, limit)));
            assertFalse(ok);
            assertEq(reason, _hookError(IHooks.afterSwap.selector, PleaHook.NotEnoughGas.selector));
            assertEq(imd.balanceOf(ALICE), initialCash);
            assertEq(token.totalSupply(), initialSupply);
            assertEq(token.balanceOf(ALICE), 0);
            assertEq(simd.balanceOf(ALICE), 0);
            assertEq(hook.totalCashback(), 0);
            assertEq(imd.allowance(address(hook), address(stacker)), 0);
        }
    }

    function testLaunchLimitRevertsForItsOwnReasonAndCanBuyAfterWindow() public {
        uint160 limit = _limit();
        bytes memory expected = _hookError(IHooks.beforeSwap.selector, PleaHook.LaunchBuyLimit.selector);
        uint256 supply = token.totalSupply();
        vm.prank(ALICE);
        vm.expectRevert(expected);
        gate.buy(1000 ether, 1, limit);
        assertEq(token.totalSupply(), supply);
        assertEq(hook.totalOwnerFees(), 0);
        assertEq(hook.costBasis(ALICE), 0);
        _afterLaunch();
        assertGt(_buy(ALICE, 1000 ether), 5_000_000 ether);
    }

    function testMalformedTraderAndExactOutputCannotBecomeSuccessfulBuys() public {
        _afterLaunch();
        HostileRouter router = new HostileRouter();
        imd.mint(address(router), 100 ether);
        uint160 limit = _limit();
        bytes[] memory bad = new bytes[](6);
        bad[0] = "";
        bad[1] = abi.encode(ALICE, BOB);
        bad[2] = abi.encode(address(0));
        bad[3] = abi.encode(address(gate));
        bad[4] = abi.encode(address(manager));
        bad[5] = abi.encode(address(hook));
        bytes memory invalidTrader = _hookError(IHooks.beforeSwap.selector, PleaHook.InvalidTrader.selector);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(invalidTrader);
            router.attack(hook, 0, bad[i], limit);
        }
        bytes memory exactOutput = _hookError(IHooks.beforeSwap.selector, PleaHook.ExactInputOnly.selector);
        vm.expectRevert(exactOutput);
        router.attack(hook, 3, abi.encode(ALICE), limit);
        assertEq(imd.balanceOf(address(router)), 100 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(hook.costBasis(ALICE), 0);
        assertEq(manager.balanceOf(address(router), uint160(address(token))), 0);
    }

    function testHookCallbacksBindManagerPoolAndLiquidityOwner() public {
        PoolKey memory key = hook.poolKey();
        uint160 price = hook.currentSqrtPriceX96();
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(hook.tickLower(), hook.tickUpper(), 1, bytes32(0));
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.beforeInitialize(address(hook), key, price);
        vm.startPrank(address(manager));
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.beforeInitialize(ALICE, key, price);
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.beforeAddLiquidity(ALICE, key, params, "");
        params.liquidityDelta = -1;
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.beforeRemoveLiquidity(ALICE, key, params, "");
        key.fee = 1;
        vm.expectRevert(PleaHook.InvalidPool.selector);
        hook.beforeInitialize(address(hook), key, price);
        vm.stopPrank();
        assertEq(token.balanceOf(address(hook)), 0);
        assertApproxEqAbs(hook.tokensInPool(), 900_000_000 ether, 1000);
    }

    function testForgedUnlockAndAfterSwapCannotWithdrawPoolReserves() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        PoolKey memory key = hook.poolKey();
        uint160 limit = _limit();
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(!hook.plea0(), -int256(10 ether), limit);
        uint256 reserve = token.balanceOf(address(manager));
        vm.startPrank(address(manager));
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(uint8(2)));
        vm.expectRevert(CabalGate.Unauthorized.selector);
        gate.unlockCallback("");
        vm.expectRevert(PleaHook.Unauthorized.selector);
        hook.afterSwap(ALICE, key, params, BalanceDelta.wrap(0), abi.encode(ALICE));
        vm.stopPrank();
        assertEq(token.balanceOf(address(manager)), reserve);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzPartialBuyConservesCashAndPaysActualFill(uint96 raw, uint16 distance) public {
        _afterLaunch();
        uint256 input = bound(raw, 100 ether, 1000 ether);
        // The first 60-tick alignment gap has no liquidity; move past it before asking for a fill.
        uint256 scale = 10_040 + uint256(distance) % 60;
        uint160 price = hook.currentSqrtPriceX96();
        uint160 limit =
            hook.plea0() ? uint160(uint256(price) * scale / 10_000) : uint160(uint256(price) * 10_000 / scale);
        uint256 beforeCash = imd.balanceOf(ALICE);
        uint256 beforeSupply = token.totalSupply();
        vm.prank(ALICE);
        uint256 output = gate.buy(input, 1, limit);
        uint256 spent = beforeCash - imd.balanceOf(ALICE);
        assertGt(output, 0);
        assertGt(spent, 0);
        assertLt(spent, input, "price limit must force partial input fill");
        assertEq(hook.costBasis(ALICE), spent);
        assertEq(stacker.stackedBy(address(hook), ALICE), spent / 200);
        assertEq(imd.balanceOf(address(this)), spent / 200);
        assertApproxEqAbs(hook.totalLiquidityFees(), spent / 400, 3);
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(hook)) + imd.balanceOf(address(this))
                + imd.balanceOf(address(simd)),
            spent
        );
        uint256 burned = beforeSupply - token.totalSupply();
        assertEq(burned, (output + burned) / 400);
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(manager.balanceOf(ALICE, uint160(address(token))), 0);
        assertEq(manager.balanceOf(address(gate), uint160(address(token))), 0);
    }

    function testDistributionInvalidProofsDoNotConsumeClaimAndSponsorCannotRedirect() public {
        uint256 amount = 100 ether;
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(ALICE, amount))));
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.setMerkleRoot(bytes32(0));
        distributor.setMerkleRoot(leaf);
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.claim(BOB, amount, empty);
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.claim(ALICE, amount + 1, empty);
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.claim(ALICE, 0, empty);
        bytes32[] memory overlong = new bytes32[](65);
        vm.expectRevert(PleaDistributor.InvalidClaim.selector);
        distributor.claim(ALICE, amount, overlong);
        assertFalse(distributor.claimed(ALICE));
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether);
        vm.prank(BOB);
        distributor.claim(ALICE, amount, empty);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(hook.averageBuyTime(ALICE), block.timestamp);
        assertEq(hook.costBasis(ALICE), 0);
    }

    function testHourlyCheckpointRingWrapAndNoSameBlockSpotPromotion() public {
        _afterLaunch();
        _buy(ALICE, 10 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.checkpoint();
        uint256 before = hook.latestPrice();
        _buy(BOB, 1000 ether);
        hook.checkpoint();
        assertEq(hook.latestPrice(), before);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.checkpoint(); // Same block number, so the new spot still cannot be promoted.
        assertEq(hook.latestPrice(), before);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 26 hours);
        hook.checkpoint();
        uint256 newest = hook.latestCheckpointHour();
        assertGt(hook.latestPrice(), before);
        for (uint256 i; i < 25; ++i) {
            (uint64 hour, uint192 recorded) = hook.checkpoints((newest - i) % 25);
            assertEq(hour, newest - i);
            assertEq(recorded, hook.latestPrice());
        }
        assertEq(hook.price24hAgo(), hook.latestPrice());
    }

    function testZeroAndOutOfRangeBuyInputsCannotMoveCash() public {
        uint160 limit = _limit();
        uint256[3] memory inputs = [uint256(0), uint256(int256(type(int128).max)) + 1, type(uint256).max];
        uint256 cash = imd.balanceOf(ALICE);
        for (uint256 i; i < inputs.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(CabalGate.InvalidAmount.selector);
            gate.buy(inputs[i], 0, limit);
        }
        assertEq(imd.balanceOf(ALICE), cash);
        assertEq(hook.costBasis(ALICE), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzzRepeatedFullRoundTripsCannotCreateTraderWealth(uint96 rawAmount, uint8 rawCycles) public {
        vm.warp(gate.lastVerdictAt() + 33 hours);
        gate.killCabal();
        uint256 input = bound(rawAmount, 0.01 ether, 1000 ether);
        uint256 cycles = 1 + uint256(rawCycles) % 5;
        uint256 initial = imd.balanceOf(ALICE) + simd.convertToAssets(simd.balanceOf(ALICE));
        for (uint256 i; i < cycles; ++i) {
            uint256 before = imd.balanceOf(ALICE) + simd.convertToAssets(simd.balanceOf(ALICE));
            uint256 bought = _buy(ALICE, input);
            vm.prank(ALICE);
            gate.sellFreely(bought, 0);
            uint256 after_ = imd.balanceOf(ALICE) + simd.convertToAssets(simd.balanceOf(ALICE));
            assertLe(after_, before, "fees, cap and rounding must not fund a round-trip profit");
            assertEq(token.balanceOf(ALICE), 0);
            assertEq(hook.costBasis(ALICE), 0);
            assertEq(hook.averageBuyTime(ALICE), 0);
        }
        assertLe(imd.balanceOf(ALICE) + simd.convertToAssets(simd.balanceOf(ALICE)), initial);
    }
}
