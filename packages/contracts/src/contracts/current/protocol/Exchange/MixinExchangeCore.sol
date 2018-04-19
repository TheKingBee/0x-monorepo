/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.4.21;
pragma experimental ABIEncoderV2;

import "./mixins/MExchangeCore.sol";
import "./mixins/MSettlement.sol";
import "./mixins/MSignatureValidator.sol";
import "./LibOrder.sol";
import "./LibErrors.sol";
import "./LibPartialAmount.sol";
import "../../utils/SafeMath/SafeMath.sol";

/// @dev Provides MExchangeCore
/// @dev Consumes MSettlement
/// @dev Consumes MSignatureValidator
contract MixinExchangeCore is
    LibOrder,
    MExchangeCore,
    MSettlement,
    MSignatureValidator,
    SafeMath,
    LibErrors,
    LibPartialAmount
{
    // Mapping of orderHash => amount of takerToken already bought by maker
    mapping (bytes32 => uint256) public filled;

    // Mapping of orderHash => cancelled
    mapping (bytes32 => bool) public cancelled;

    // Mapping of makerAddress => lowest salt an order can have in order to be fillable
    // Orders with a salt less than their maker's epoch are considered cancelled
    mapping (address => uint256) public makerEpoch;

    event Fill(
        address indexed makerAddress,
        address takerAddress,
        address indexed feeRecipientAddress,
        bytes makerAssetData,
        bytes takerAssetData,
        uint256 makerTokenFilledAmount,
        uint256 takerTokenFilledAmount,
        uint256 makerFeePaid,
        uint256 takerFeePaid,
        bytes32 indexed orderHash
    );

    event Cancel(
        address indexed makerAddress,
        address indexed feeRecipientAddress,
        bytes makerAssetData,
        bytes takerAssetData,
        bytes32 indexed orderHash
    );

    event CancelUpTo(
        address indexed makerAddress,
        uint256 makerEpoch
    );

    /*
    * Core exchange functions
    */

    function orderStatus(
        Order memory order,
        bytes signature)
        public
        view
        returns (
            uint8 status,
            bytes32 orderHash,
            uint256 filledAmount)
    {
        // Compute the order hash and fetch filled amount
        orderHash = getOrderHash(order);
        filledAmount = filled[orderHash];

        // Validations on order only if first time seen
        if (filledAmount == 0) {

            // If order.takerTokenAmount is zero, then the order will always
            // be considered filled because:
            //    0 == takerTokenAmount == filledAmount
            // Instead of distinguishing between unfilled and filled zero taker
            // amount orders, we choose not to support them.
            if(order.takerTokenAmount == 0) {
                status = uint8(Errors.ORDER_INVALID);
                return;
            }

            // If order.makerTokenAmount is zero, we also reject the order.
            // While the Exchange contract handles them correctly, they create
            // edge cases in the supporting infrastructure because they have
            // an 'infinite' price when computed by a simple division.
            if(order.makerTokenAmount == 0) {
                status = uint8(Errors.ORDER_INVALID);
                return;
            }

            // Maker signature needs to be valid
            if(!isValidSignature(orderHash, order.makerAddress, signature)) {
                status = uint8(Errors.ORDER_SIGNATURE_INVALID);
                return;
            }
        }

        // Validate order expiration
        if (block.timestamp >= order.expirationTimeSeconds) {
            status = uint8(Errors.ORDER_EXPIRED);
            return;
        }

        // Validate order availability
        if (filledAmount >= order.takerTokenAmount) {
            status = uint8(Errors.ORDER_FULLY_FILLED);
            return;
        }

        // Check if order has been cancelled
        if (cancelled[orderHash]) {
            status = uint8(Errors.ORDER_CANCELLED);
            return;
        }

        // Validate order is not cancelled
        if (makerEpoch[order.makerAddress] > order.salt) {
            status = uint8(Errors.ORDER_CANCELLED);
            return;
        }

        // Order is OK
        status = uint8(Errors.SUCCESS);
        return;
    }

    function getFillAmounts(
        Order memory order,
        uint256 filledAmount,
        uint256 takerTokenFillAmount,
        address taker)
        public
        pure
        returns (
            uint8 status,
            FillResults memory fillResults)
    {
        // Validate taker
        if (order.takerAddress != address(0)) {
            require(order.takerAddress == taker);
        }

        // Compute takerTokenFilledAmount
        uint256 remainingTakerTokenAmount = safeSub(
            order.takerTokenAmount, filledAmount);
        fillResults.takerTokenFilledAmount = min256(
            takerTokenFillAmount, remainingTakerTokenAmount);

        // Validate fill order rounding
        if (isRoundingError(
            takerTokenFilledAmount,
            order.takerTokenAmount,
            order.makerTokenAmount))
        {
            status = uint8(Errors.ROUNDING_ERROR_TOO_LARGE);
            return;
        }

        // Compute proportional transfer amounts
        // TODO: All three are multiplied by the same fraction. This can
        // potentially be optimized.
        fillResults.makerTokenFilledAmount = getPartialAmount(
            takerTokenFilledAmount,
            order.takerTokenAmount,
            order.makerTokenAmount);
        fillResults.makerFeeAmountPaid = getPartialAmount(
            takerTokenFilledAmount,
            order.takerTokenAmount,
            order.makerFeeAmount);
        fillResults.takerFeeAmountPaid = getPartialAmount(
            takerTokenFilledAmount,
            order.takerTokenAmount,
            order.takerFeeAmount);

        status = uint8(Errors.SUCCESS);
        return;
    }

    function updateState(
        Order memory order,
        bytes32 orderHash,
        uint256 makerTokenFilledAmount,
        uint256 takerTokenFilledAmount,
        uint256 makerFeeAmountPaid,
        uint256 takerFeeAmountPaid)
        private
    {
        // Update state
        filled[orderHash] = safeAdd(filled[orderHash], takerTokenFilledAmount);

        // Log order
        emit LogFill(
            order.makerAddress,
            msg.sender,
            order.feeRecipientAddress,
            order.makerTokenAddress,
            order.takerTokenAddress,
            makerTokenFilledAmount,
            takerTokenFilledAmount,
            makerFeeAmountPaid,
            takerFeeAmountPaid,
            orderHash
        );
    }

    /// @dev Fills the input order.
    /// @param order Order struct containing order specifications.
    /// @param takerTokenFillAmount Desired amount of takerToken to sell.
    /// @param signature Proof that order has been created by maker.
    /// @return Amounts filled and fees paid by maker and taker.
    function fillOrder(
        Order memory order,
        uint256 takerTokenFillAmount,
        bytes memory signature)
        public
        returns (FillResults memory fillResults)
    {
        // Fetch current order status
        bytes32 orderHash;
        uint8 status;
        uint256 filledAmount;
        (status, orderHash, filledAmount) = orderStatus(order, signature);
        if(status != uint8(Errors.SUCCESS)) {
            emit ExchangeError(uint8(status), orderHash);
            return fillResults;
        }

        // Compute proportional fill amounts
        uint256 makerTokenFilledAmount;
        uint256 makerFeeAmountPaid;
        uint256 takerFeeAmountPaid;
        (   status,
            fillResults
        ) = getFillAmounts(
            order,
            filledAmount,
            takerTokenFillAmount,
            msg.sender);
        if(status != uint8(Errors.SUCCESS)) {
            emit ExchangeError(uint8(status), orderHash);
            return fillResults;
        }

        // Update exchange internal state
        updateState(
            order,
            orderHash,
            fillResults.makerTokenFilledAmount,
            fillResults.takerTokenFilledAmount,
            fillResults.makerFeeAmountPaid,
            fillResults.takerFeeAmountPaid);

        // Settle order
        (fillResults.makerTokenFilledAmount, fillResults.makerFeePaid, fillResults.takerFeePaid) =
            settleOrder(order, msg.sender, fillResults.takerTokenFilledAmount);

        // Log order
        emit Fill(
            order.makerAddress,
            msg.sender,
            order.feeRecipientAddress,
            order.makerAssetData,
            order.takerAssetData,
            fillResults.makerTokenFilledAmount,
            fillResults.takerTokenFilledAmount,
            fillResults.makerFeeAmountPaid,
            fillResults.takerFeeAmountPaid,
            orderHash
        );
        return fillResults;
    }

    /// @dev After calling, the order can not be filled anymore.
    /// @param order Order struct containing order specifications.
    /// @return True if the order state changed to cancelled.
    ///         False if the transaction was already cancelled or expired.
    function cancelOrder(Order memory order)
        public
        returns (bool)
    {
        // Compute the order hash
        bytes32 orderHash = getOrderHash(order);

        // Validate the order
        require(order.makerTokenAmount > 0);
        require(order.takerTokenAmount > 0);
        require(order.makerAddress == msg.sender);

        if (block.timestamp >= order.expirationTimeSeconds) {
            emit ExchangeError(uint8(Errors.ORDER_EXPIRED), orderHash);
            return false;
        }

        if (cancelled[orderHash]) {
            emit ExchangeError(uint8(Errors.ORDER_CANCELLED), orderHash);
            return false;
        }

        cancelled[orderHash] = true;

        emit Cancel(
            order.makerAddress,
            order.feeRecipientAddress,
            order.makerAssetData,
            order.takerAssetData,
            orderHash
        );
        return true;
    }

    /// @param salt Orders created with a salt less or equal to this value will be cancelled.
    function cancelOrdersUpTo(uint256 salt)
        external
    {
        uint256 newMakerEpoch = salt + 1;                // makerEpoch is initialized to 0, so to cancelUpTo we need salt+1
        require(newMakerEpoch > makerEpoch[msg.sender]); // epoch must be monotonically increasing
        makerEpoch[msg.sender] = newMakerEpoch;
        emit CancelUpTo(msg.sender, newMakerEpoch);
    }

    /// @dev Checks if rounding error > 0.1%.
    /// @param numerator Numerator.
    /// @param denominator Denominator.
    /// @param target Value to multiply with numerator/denominator.
    /// @return Rounding error is present.
    function isRoundingError(uint256 numerator, uint256 denominator, uint256 target)
        public pure
        returns (bool isError)
    {
        uint256 remainder = mulmod(target, numerator, denominator);
        if (remainder == 0) {
            return false; // No rounding error.
        }

        uint256 errPercentageTimes1000000 = safeDiv(
            safeMul(remainder, 1000000),
            safeMul(numerator, target)
        );
        isError = errPercentageTimes1000000 > 1000;
        return isError;
    }
}