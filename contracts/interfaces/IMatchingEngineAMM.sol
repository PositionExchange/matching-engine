/**
 * @author Musket
 */
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "./IAutoMarketMakerCore.sol";
import "./IMatchingEngineCore.sol";
import "./IFee.sol";

interface IMatchingEngineAMM is
    IFee,
    IAutoMarketMakerCore,
    IMatchingEngineCore
{
    // TODO add guard

    function initialize(
        address quoteAsset,
        address baseAsset,
        uint256 basisPoint,
        uint256 baseBasisPoint,
        uint128 maxFindingWordsIndex,
        uint128 initialPip,
        uint128 pipRange,
        uint32 tickSpace,
        address owner
    ) external;

    struct ExchangedData {
        uint256 baseAmount;
        uint256 quoteAmount;
        uint256 feeQuoteAmount;
        uint256 feeBaseAmount;
    }

    function accumulateClaimableAmount(
        uint128 _pip,
        uint64 _orderId,
        ExchangedData memory exData,
        uint256 basisPoint,
        uint16 fee,
        uint128 feeBasis
    ) external view returns (ExchangedData memory);
}
