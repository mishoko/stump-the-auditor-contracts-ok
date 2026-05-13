// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ILendingPool} from "../interfaces/ILendingPool.sol";

library LendingMath {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint8 internal constant ORACLE_DECIMALS = 8;

    function updatedReserve(ILendingPool.Reserve memory reserve, uint256 timestamp)
        internal
        pure
        returns (ILendingPool.Reserve memory updated, uint256 reserveDelta, bool changed)
    {
        updated = reserve;

        uint256 dt = timestamp - updated.lastUpdateTimestamp;
        if (dt == 0) return (updated, 0, false);

        changed = true;
        updated.lastUpdateTimestamp = timestamp.toUint64();

        uint256 totalSupplyActual =
            scaledToUnderlying(updated.totalScaledSupply, updated.supplyIndex, Math.Rounding.Floor);
        uint256 totalBorrowActual =
            scaledToUnderlying(updated.totalScaledBorrow, updated.supplyIndex, Math.Rounding.Floor);

        if (totalSupplyActual == 0 && totalBorrowActual == 0) {
            return (updated, 0, true);
        }

        uint256 oldBorrowIndex = updated.borrowIndex;
        uint256 newBorrowIndex;

        {
            uint256 utilizationRay = totalSupplyActual == 0
                ? RAY
                : totalBorrowActual == 0 ? 0 : Math.mulDiv(totalBorrowActual, RAY, totalSupplyActual);
            if (utilizationRay > RAY) utilizationRay = RAY;
            (uint256 borrowRatePerYear, uint256 supplyRatePerYear) = ratesRay(updated, utilizationRay);

            newBorrowIndex = Math.mulDiv(oldBorrowIndex, RAY + ((borrowRatePerYear / SECONDS_PER_YEAR) * dt), RAY);
            if (totalSupplyActual != 0) {
                updated.supplyIndex =
                    Math.mulDiv(updated.supplyIndex, RAY + ((supplyRatePerYear / SECONDS_PER_YEAR) * dt), RAY);
            }
        }

        if (totalBorrowActual != 0 && updated.reserveFactorBps != 0 && newBorrowIndex > oldBorrowIndex) {
            uint256 borrowDelta = Math.mulDiv(totalBorrowActual, newBorrowIndex - oldBorrowIndex, oldBorrowIndex);
            reserveDelta = Math.mulDiv(borrowDelta, updated.reserveFactorBps, BPS);
            updated.accruedReserves += reserveDelta;
        }

        updated.borrowIndex = newBorrowIndex;
    }

    function ratesRay(ILendingPool.Reserve memory reserve, uint256 utilizationRay)
        internal
        pure
        returns (uint256 borrowRatePerYear, uint256 supplyRatePerYear)
    {
        uint256 optimalUtilizationRay = Math.mulDiv(reserve.irParams.optimalUtilizationBps, RAY, BPS);

        if (utilizationRay <= optimalUtilizationRay) {
            if (optimalUtilizationRay == 0) {
                borrowRatePerYear = reserve.irParams.baseRateRayPerYear;
            } else {
                borrowRatePerYear = reserve.irParams.baseRateRayPerYear
                    + Math.mulDiv(reserve.irParams.slope1RayPerYear, utilizationRay, optimalUtilizationRay);
            }
        } else if (optimalUtilizationRay >= RAY) {
            borrowRatePerYear =
                uint256(reserve.irParams.baseRateRayPerYear) + uint256(reserve.irParams.slope1RayPerYear);
        } else {
            borrowRatePerYear = uint256(reserve.irParams.baseRateRayPerYear)
                + uint256(reserve.irParams.slope1RayPerYear)
                + Math.mulDiv(
                    reserve.irParams.slope2RayPerYear,
                    utilizationRay - optimalUtilizationRay,
                    RAY - optimalUtilizationRay
                );
        }

        uint256 borrowRevenueRate = Math.mulDiv(borrowRatePerYear, utilizationRay, RAY);
        supplyRatePerYear = Math.mulDiv(borrowRevenueRate, BPS - reserve.reserveFactorBps, BPS);
    }

    function utilizationRateRay(ILendingPool.Reserve memory reserve) internal pure returns (uint256 utilizationRay) {
        uint256 totalSupplyActual =
            scaledToUnderlying(reserve.totalScaledSupply, reserve.supplyIndex, Math.Rounding.Floor);
        if (totalSupplyActual == 0) return 0;

        uint256 totalBorrowActual =
            scaledToUnderlying(reserve.totalScaledBorrow, reserve.borrowIndex, Math.Rounding.Floor);
        if (totalBorrowActual == 0) return 0;

        utilizationRay = Math.mulDiv(totalBorrowActual, RAY, totalSupplyActual);
        if (utilizationRay > RAY) utilizationRay = RAY;
    }

    function assetValueWad(uint256 amount, uint8 decimals, uint256 price) internal pure returns (uint256 valueWad) {
        if (amount == 0) return 0;
        valueWad = Math.mulDiv(toWad(amount, decimals), price, pow10(ORACLE_DECIMALS));
    }

    function amountFromValueWad(uint256 valueWad, uint8 decimals, uint256 price)
        internal
        pure
        returns (uint256 amount)
    {
        return amountFromValueWad(valueWad, decimals, price, Math.Rounding.Floor);
    }

    function amountFromValueWad(uint256 valueWad, uint8 decimals, uint256 price, Math.Rounding rounding)
        internal
        pure
        returns (uint256 amount)
    {
        if (valueWad == 0) return 0;
        amount = fromWad(Math.mulDiv(valueWad, pow10(ORACLE_DECIMALS), price, rounding), decimals, rounding);
    }

    function scaledToUnderlying(uint256 scaledAmount, uint256 index, Math.Rounding rounding)
        internal
        pure
        returns (uint256 amount)
    {
        if (scaledAmount == 0) return 0;
        amount = Math.mulDiv(scaledAmount, index, RAY, rounding);
    }

    function toWad(uint256 amount, uint8 decimals) internal pure returns (uint256 wadAmount) {
        if (decimals == 18) return amount;
        if (decimals < 18) return Math.mulDiv(amount, pow10(uint8(18 - decimals)), 1);
        return Math.mulDiv(amount, 1, pow10(uint8(decimals - 18)));
    }

    function fromWad(uint256 wadAmount, uint8 decimals) internal pure returns (uint256 amount) {
        return fromWad(wadAmount, decimals, Math.Rounding.Floor);
    }

    function fromWad(uint256 wadAmount, uint8 decimals, Math.Rounding rounding) internal pure returns (uint256 amount) {
        if (decimals == 18) return wadAmount;
        if (decimals < 18) return Math.mulDiv(wadAmount, 1, pow10(uint8(18 - decimals)), rounding);
        return Math.mulDiv(wadAmount, pow10(uint8(decimals - 18)), 1, rounding);
    }

    function pow10(uint8 exponent) internal pure returns (uint256 value) {
        if (exponent == 0) return 1;
        if (exponent == 1) return 10;
        if (exponent == 2) return 100;
        if (exponent == 3) return 1_000;
        if (exponent == 4) return 10_000;
        if (exponent == 5) return 100_000;
        if (exponent == 6) return 1_000_000;
        if (exponent == 7) return 10_000_000;
        if (exponent == 8) return 100_000_000;
        if (exponent == 9) return 1_000_000_000;
        if (exponent == 10) return 10_000_000_000;
        if (exponent == 11) return 100_000_000_000;
        if (exponent == 12) return 1_000_000_000_000;
        if (exponent == 13) return 10_000_000_000_000;
        if (exponent == 14) return 100_000_000_000_000;
        if (exponent == 15) return 1_000_000_000_000_000;
        if (exponent == 16) return 10_000_000_000_000_000;
        if (exponent == 17) return 100_000_000_000_000_000;
        if (exponent == 18) return 1_000_000_000_000_000_000;
        return 10 ** exponent;
    }
}
