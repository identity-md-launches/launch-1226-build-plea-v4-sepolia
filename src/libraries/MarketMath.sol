// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library MarketMath {
    uint256 internal constant Q96 = 1 << 96;

    function liquidity0(uint160 a, uint160 b, uint256 amount) internal pure returns (uint128) {
        return narrow(FullMath.mulDiv(amount, FullMath.mulDiv(a, b, Q96), b - a));
    }

    function liquidity1(uint160 a, uint160 b, uint256 amount) internal pure returns (uint128) {
        return narrow(FullMath.mulDiv(amount, Q96, b - a));
    }

    function narrow(uint256 value) internal pure returns (uint128) {
        require(value <= uint256(int256(type(int128).max)), "liquidity overflow");
        return uint128(value);
    }

    function amounts(uint160 price, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (uint256 a0, uint256 a1)
    {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        if (price < a) price = a;
        if (price > b) price = b;
        a0 = SqrtPriceMath.getAmount0Delta(price, b, liquidity, false);
        a1 = SqrtPriceMath.getAmount1Delta(a, price, liquidity, false);
    }

    /// @dev Ratios used here are bounded by the supported tick range. sqrt uses 192-bit precision.
    function sqrtRatio(uint256 numerator, uint256 denominator) internal pure returns (uint160) {
        require(numerator != 0 && denominator != 0, "zero price");
        // Q128 ratio keeps intermediate products within 256 bits at realistic prices.
        uint256 ratio = FullMath.mulDiv(numerator, 1 << 128, denominator);
        uint256 root = Math.sqrt(ratio) << 32;
        require(root > TickMath.MIN_SQRT_PRICE && root < TickMath.MAX_SQRT_PRICE, "price bounds");
        return uint160(root);
    }

    function priceWad(uint160 sqrtPrice, bool plea0) internal pure returns (uint256) {
        uint256 ratioX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
        return plea0 ? FullMath.mulDiv(ratioX128, 1e18, 1 << 128) : FullMath.mulDiv(1 << 128, 1e18, ratioX128);
    }
}
