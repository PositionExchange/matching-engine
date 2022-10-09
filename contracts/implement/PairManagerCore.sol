/**
 * @author Musket
 */
pragma solidity ^0.8.9;
import "../libraries/exchange/LimitOrder.sol";
import "../libraries/types/PairManagerCoreStorage.sol";
import "../libraries/helper/Timers.sol";
import "../libraries/helper/TradeConvert.sol";
import "../libraries/exchange/TickPosition.sol";
import "../interfaces/IPairManager.sol";
import "./Block.sol";
import "../libraries/helper/Convert.sol";

abstract contract PairManagerCore is Block, PairManagerCoreStorage {
    event MarketFilled(
        bool isBuy,
        uint256 indexed amount,
        uint128 toPip,
        uint256 startPip,
        uint128 remainingLiquidity,
        uint64 filledIndex
    );
    event LimitOrderCreated(
        uint64 orderId,
        uint128 pip,
        uint128 size,
        bool isBuy
    );

    event PairManagerInitialized(
        address quoteAsset,
        address baseAsset,
        address counterParty,
        uint256 basisPoint,
        uint256 BASE_BASIC_POINT,
        uint128 maxFindingWordsIndex,
        uint128 initialPip,
        uint64 expireTime,
        address owner
    );
    event LimitOrderCancelled(
        bool isBuy,
        uint64 orderId,
        uint128 pip,
        uint256 size
    );

    event UpdateMaxFindingWordsIndex(
        address spotManager,
        uint128 newMaxFindingWordsIndex
    );

    event MaxWordRangeForLimitOrderUpdated(
        uint128 newMaxWordRangeForLimitOrder
    );
    event MaxWordRangeForMarketOrderUpdated(
        uint128 newMaxWordRangeForMarketOrder
    );
    event UpdateBasisPoint(address spotManager, uint256 newBasicPoint);
    event UpdateBaseBasicPoint(address spotManager, uint256 newBaseBasisPoint);
    event ReserveSnapshotted(uint128 pip, uint256 timestamp);
    event LimitOrderUpdated(
        address spotManager,
        uint64 orderId,
        uint128 pip,
        uint256 size
    );
    event UpdateExpireTime(address spotManager, uint64 newExpireTime);
    event UpdateCounterParty(address spotManager, address newCounterParty);
    event LiquidityPoolAllowanceUpdate(address liquidityPool, bool value);

    // Define using library
    using TickPosition for TickPosition.Data;
    using LiquidityBitmap for mapping(uint128 => uint256);
    using Convert for uint256;
    using Convert for int256;

    function _initializeCore(
        uint256 basisPoint,
        uint256 baseBasisPoint,
        uint128 maxFindingWordsIndex,
        uint128 initialPip
    ) internal {
        reserveSnapshots.push(
            ReserveSnapshot(initialPip, _blockTimestamp(), _blockNumber())
        );
        singleSlot.pip = initialPip;
        basisPoint = basisPoint;
        BASE_BASIC_POINT = baseBasisPoint;
        maxFindingWordsIndex = maxFindingWordsIndex;
        maxWordRangeForLimitOrder = maxFindingWordsIndex;
        maxWordRangeForMarketOrder = maxFindingWordsIndex;
    }

    //*
    //*** Virtual functions
    //*

    function updatePartialFilledOrder(uint128 _pip, uint64 _orderId)
        external
        virtual
    {
        uint256 newSize = tickPosition[_pip].updateOrderWhenClose(_orderId);
        _emitLimitOrderUpdatedHook(address(this), _orderId, _pip, newSize);
    }

    function cancelLimitOrder(uint128 _pip, uint64 _orderId)
        external
        virtual
        returns (uint256 remainingSize, uint256 partialFilled)
    {
        TickPosition.Data storage _tickPosition = tickPosition[_pip];
        require(
            hasLiquidity(_pip) && _orderId >= _tickPosition.filledIndex,
            "VL_ONLY_PENDING_ORDER"
        );
        return _internalCancelLimitOrder(_tickPosition, _pip, _orderId);
    }

    function openLimit(
        uint128 pip,
        uint128 baseAmountIn,
        bool isBuy,
        address trader,
        uint256 quoteAmountIn
    )
        external
        virtual
        returns (
            uint64 orderId,
            uint256 baseAmountFilled,
            uint256 quoteAmountFilled
        )
    {
        (orderId, baseAmountFilled, quoteAmountFilled) = _internalOpenLimit(
            ParamsInternalOpenLimit({
                pip: pip,
                size: baseAmountIn,
                isBuy: isBuy,
                trader: trader,
                quoteDeposited: quoteAmountIn
            })
        );
    }

    function openMarket(
        uint256 size,
        bool isBuy,
        address trader
    ) external virtual returns (uint256 sizeOut, uint256 quoteAmount) {
        return
            _internalOpenMarketOrder(
                size,
                isBuy,
                0,
                trader,
                true,
                maxWordRangeForLimitOrder
            );
    }

    //*
    // Public view functions
    //*
    function hasLiquidity(uint128 _pip) public view returns (bool) {
        return liquidityBitmap.hasLiquidity(_pip);
    }

    function getPendingOrderDetail(uint128 pip, uint64 orderId)
        public
        view
        virtual
        returns (
            bool isFilled,
            bool isBuy,
            uint256 size,
            uint256 partialFilled
        )
    {
        (isFilled, isBuy, size, partialFilled) = tickPosition[pip]
            .getQueueOrder(orderId);

        if (!liquidityBitmap.hasLiquidity(pip)) {
            isFilled = true;
        }
        if (size != 0 && size == partialFilled) {
            isFilled = true;
        }
    }

    //*
    // Private functions
    //*

    function _internalCancelLimitOrder(
        TickPosition.Data storage _tickPosition,
        uint128 _pip,
        uint64 _orderId
    ) private returns (uint256 remainingSize, uint256 partialFilled) {
        bool isBuy;
        (remainingSize, partialFilled, isBuy) = _tickPosition.cancelLimitOrder(
            _orderId
        );
        // if that pip doesn't have liquidity after closed order, toggle pip to uninitialized
        if (_tickPosition.liquidity == 0) {
            liquidityBitmap.toggleSingleBit(_pip, false);
            // only unset isFullBuy when cancel order pip == current pip
            if (_pip == singleSlot.pip) {
                singleSlot.isFullBuy = 0;
            }
        }
        emit LimitOrderCancelled(isBuy, _orderId, _pip, remainingSize);
    }

    struct ParamsInternalOpenLimit {
        uint128 pip;
        uint128 size;
        bool isBuy;
        address trader;
        uint256 quoteDeposited;
    }

    function _internalOpenLimit(ParamsInternalOpenLimit memory _params)
        private
        returns (
            uint64 orderId,
            uint256 baseAmountFilled,
            uint256 quoteAmountFilled
        )
    {
        require(_params.size != 0, "VL_INVALID_SIZE");
        SingleSlot memory _singleSlot = singleSlot;
        uint256 underlyingPip = getUnderlyingPriceInPip();
        {
            if (_params.isBuy && _singleSlot.pip != 0) {
                int256 maxPip = int256(underlyingPip) -
                    int128(maxWordRangeForLimitOrder * 250);
                if (maxPip > 0) {
                    require(
                        int128(_params.pip) >= maxPip,
                        "VL_MUST_CLOSE_TO_INDEX_PRICE_LONG"
                    );
                } else {
                    require(
                        _params.pip >= 1,
                        "VL_MUST_CLOSE_TO_INDEX_PRICE_LONG"
                    );
                }
            } else {
                require(
                    _params.pip <=
                        (underlyingPip + maxWordRangeForLimitOrder * 250),
                    "VL_MUST_CLOSE_TO_INDEX_PRICE_SHORT"
                );
            }
        }
        bool hasLiquidity = liquidityBitmap.hasLiquidity(_params.pip);
        //save gas
        {
            bool canOpenMarketWithMaxPip = (_params.isBuy &&
                _params.pip >= _singleSlot.pip) ||
                (!_params.isBuy && _params.pip <= _singleSlot.pip);
            if (canOpenMarketWithMaxPip) {
                // open market
                if (_params.isBuy) {
                    // higher pip when long must lower than max word range for market order short
                    require(
                        _params.pip <=
                            underlyingPip + maxWordRangeForMarketOrder * 250,
                        "VL_MARKET_ORDER_MUST_CLOSE_TO_INDEX_PRICE"
                    );
                } else {
                    // lower pip when short must higher than max word range for market order long
                    require(
                        int128(_params.pip) >=
                            (int256(underlyingPip) -
                                int128(maxWordRangeForMarketOrder * 250)),
                        "VL_MARKET_ORDER_MUST_CLOSE_TO_INDEX_PRICE"
                    );
                }
                (baseAmountFilled, quoteAmountFilled) = _openMarketWithMaxPip(
                    _params.size,
                    _params.isBuy,
                    _params.pip,
                    _params.trader
                );
                hasLiquidity = liquidityBitmap.hasLiquidity(_params.pip);
                // reassign _singleSlot after _openMarketPositionWithMaxPip
                _singleSlot = singleSlot;
            }
        }
        {
            if (
                (_params.size > baseAmountFilled) ||
                (_params.size == baseAmountFilled &&
                    _params.quoteDeposited > quoteAmountFilled &&
                    _params.quoteDeposited > 0)
            ) {
                uint128 remainingSize;

                if (
                    _params.quoteDeposited > 0 &&
                    _params.isBuy &&
                    _params.quoteDeposited > quoteAmountFilled
                ) {
                    remainingSize = uint128(
                        TradeConvert.quoteToBase(
                            _params.quoteDeposited - quoteAmountFilled,
                            _params.pip,
                            _singleSlot.pip
                        )
                    );
                } else {
                    remainingSize = _params.size - uint128(baseAmountFilled);
                }

                if (
                    _params.pip == _singleSlot.pip &&
                    _singleSlot.isFullBuy != (_params.isBuy ? 1 : 2)
                ) {
                    singleSlot.isFullBuy = _params.isBuy ? 1 : 2;
                }

                orderId = tickPosition[_params.pip].insertLimitOrder(
                    remainingSize,
                    hasLiquidity,
                    _params.isBuy
                );
                if (!hasLiquidity) {
                    //set the bit to mark it has liquidity
                    liquidityBitmap.toggleSingleBit(_params.pip, true);
                }
                emit LimitOrderCreated(
                    orderId,
                    _params.pip,
                    remainingSize,
                    _params.isBuy
                );
            }
        }
    }

    function _openMarketWithMaxPip(
        uint256 size,
        bool isBuy,
        uint128 maxPip,
        address _trader
    ) internal returns (uint256 sizeOut, uint256 quoteAmount) {
        // plus 1 avoid  (singleSlot.pip - maxPip)/250 = 0
        uint128 _maxFindingWordsIndex = ((
            isBuy ? maxPip - singleSlot.pip : singleSlot.pip - maxPip
        ) / 250) + 1;
        return
            _internalOpenMarketOrder(
                size,
                isBuy,
                maxPip,
                address(0),
                true,
                _maxFindingWordsIndex
            );
    }

    struct SwapState {
        uint256 remainingSize;
        // the tick associated with the current price
        uint128 pip;
        uint32 basisPoint;
        uint32 baseBasisPoint;
        uint128 startPip;
        uint128 remainingLiquidity;
        uint8 isFullBuy;
        bool isSkipFirstPip;
        uint128 lastMatchedPip;
        bool isBuy;
        int8 lastPipRangeLiquidityIndex;

    }

    struct AmmState {
        int128 deltaBase;
        int128 deltaQuote;
    }

    function _internalOpenMarketOrder(
        uint256 _size,
        bool _isBuy,
        uint128 _maxPip,
        address _trader,
        bool _isBase,
        uint128 _maxFindingWordsIndex
    ) internal virtual returns (uint256 sizeOut, uint256 openOtherSide) {
        uint8 _pipRangeLiquidityIndex = 0;
        // only support up to 5 pip ranges
        uint8[] memory _pipRanges = new uint8[](5);
        AmmState[] memory _ammState = new AmmState[](5);

        // get current tick liquidity
        SingleSlot memory _initialSingleSlot = singleSlot;
        //save gas
        SwapState memory state = SwapState({
            remainingSize: _size,
            pip: _initialSingleSlot.pip,
            basisPoint: basisPoint.Uint256ToUint32(),
            baseBasisPoint: BASE_BASIC_POINT.Uint256ToUint32(),
            startPip: 0,
            remainingLiquidity: 0,
            isFullBuy: 0,
            isSkipFirstPip: false,
            lastMatchedPip: _initialSingleSlot.pip,
            lastPipRangeLiquidityIndex : -1,
            isBuy: _isBuy
        });
        {
            CurrentLiquiditySide currentLiquiditySide = CurrentLiquiditySide(
                _initialSingleSlot.isFullBuy
            );
            if (currentLiquiditySide != CurrentLiquiditySide.NotSet) {
                if (state.isBuy)
                    // if buy and latest liquidity is buy. skip current pip
                    state.isSkipFirstPip =
                        currentLiquiditySide == CurrentLiquiditySide.Buy;
                    // if sell and latest liquidity is sell. skip current pip
                else
                    state.isSkipFirstPip =
                        currentLiquiditySide == CurrentLiquiditySide.Sell;
            }
        }
        while (state.remainingSize != 0) {
            StepComputations memory step;
            (step.pipNext) = liquidityBitmap.findHasLiquidityInMultipleWords(
                state.pip,
                _maxFindingWordsIndex,
                !state.isBuy
            );


            // updated findHasLiquidityInMultipleWords, save more gas
            if (_maxPip != 0) {
                // if order is buy and step.pipNext (pip has liquidity) > maxPip then break cause this is limited to maxPip and vice versa
                if (
                    (state.isBuy && step.pipNext > _maxPip) ||
                    (!state.isBuy && step.pipNext < _maxPip)
                ) {
                    break;
                }
            }
            CrossPipResult memory crossPipResult = _onCrossPipHook(step.pipNext, state.isBuy);
            if ( crossPipResult.hookBaseCrossPip > 0 && step.pipNext == 0) {
                step.pipNext = crossPipResult.toPip;
            }
            /// In this line, step.pipNext still is 0, that means no liquidity for this order

            if (step.pipNext == 0) {
                // no more next pip
                // state pip back 1 pip
                if (state.isBuy) {
                    state.pip--;
                } else {
                    state.pip++;
                }
                break;
            } else {
                uint256 _remainingBase = _isBase ? state.remainingSize : TradeConvert.quoteToBase(state.remainingSize, step.pipNext, state.basisPoint);
                if (crossPipResult.hookBaseCrossPip > 0) {
                    if(state.lastPipRangeLiquidityIndex != int8(crossPipResult.pipRangeLiquidityIndex)) {
                        if(state.lastPipRangeLiquidityIndex != int8(-1)){
                            _pipRangeLiquidityIndex++;
                        }
                        if(_pipRangeLiquidityIndex > 5){
                            revert("Not enough liquidity");
                        }
                        state.lastPipRangeLiquidityIndex = int8(crossPipResult.pipRangeLiquidityIndex);
                        // set pip ranges at pipRangesIndex to _pipRangeLiquidityIndex
                        _pipRanges[_pipRangeLiquidityIndex] = crossPipResult.pipRangeLiquidityIndex;
                    }

                    _ammState[_pipRangeLiquidityIndex].deltaBase += crossPipResult.hookBaseCrossPip;
                    _ammState[_pipRangeLiquidityIndex].deltaQuote += crossPipResult.hookQuoteCrossPip;


                    if (crossPipResult.hookBaseCrossPip >= int256(state.remainingSize)) {
                        // Break the loop

                    }else {
                        // minus the remaining size
                    }
                }


            if (!state.isSkipFirstPip) {
                    if (state.startPip == 0) state.startPip = step.pipNext;

                    // get liquidity at a tick index
                    uint128 liquidity = tickPosition[step.pipNext].liquidity;
                    if (_maxPip != 0) {
                        state.lastMatchedPip = step.pipNext;
                    }
                    uint256 baseAmount = _isBase
                        ? state.remainingSize
                        : TradeConvert.quoteToBase(
                            state.remainingSize,
                            step.pipNext,
                            state.basisPoint
                        );
                    if (liquidity > baseAmount) {
                        // pip position will partially filled and stop here
                        tickPosition[step.pipNext].partiallyFill(
                            baseAmount.Uint256ToUint128()
                        );
                        if (_isBase)
                            openOtherSide += TradeConvert.baseToQuote(
                                state.remainingSize,
                                step.pipNext,
                                state.basisPoint
                            );
                        else openOtherSide += baseAmount;

                        // remaining liquidity at current pip
                        state.remainingLiquidity =
                            liquidity -
                            baseAmount.Uint256ToUint128();
                        state.remainingSize = 0;
                        state.pip = step.pipNext;
                        state.isFullBuy = uint8(
                            !state.isBuy
                                ? CurrentLiquiditySide.Buy
                                : CurrentLiquiditySide.Sell
                        );
                    } else if (baseAmount > liquidity) {
                        // order in that pip will be fulfilled
                        if (_isBase) {
                            state.remainingSize -= liquidity;
                            openOtherSide += TradeConvert.baseToQuote(
                                liquidity,
                                step.pipNext,
                                state.basisPoint
                            );
                        } else {
                            state.remainingSize -= TradeConvert.baseToQuote(
                                liquidity,
                                step.pipNext,
                                state.basisPoint
                            );
                            openOtherSide += liquidity;
                        }
                        state.pip = state.isBuy
                            ? step.pipNext + 1
                            : step.pipNext - 1;
                    } else {
                        // remaining size = liquidity
                        // only 1 pip should be toggled, so we call it directly here
                        liquidityBitmap.toggleSingleBit(step.pipNext, false);
                        if (_isBase) {
                            openOtherSide += TradeConvert.baseToQuote(
                                state.remainingSize,
                                step.pipNext,
                                state.basisPoint
                            );
                        } else {
                            openOtherSide += liquidity;
                        }
                        state.remainingSize = 0;
                        state.pip = step.pipNext;
                        state.isFullBuy = 0;
                    }
                } else {
                    state.isSkipFirstPip = false;
                    state.pip = state.isBuy ? step.pipNext + 1 : step.pipNext - 1;
                }
            }
        }
        {
            if (
                _initialSingleSlot.pip != state.pip &&
                state.remainingSize != _size
            ) {
                // all ticks in shifted range must be marked as filled
                if (
                    !(state.remainingLiquidity > 0 &&
                        state.startPip == state.pip)
                ) {
                    if (_maxPip != 0) {
                        state.pip = state.lastMatchedPip;
                    }
                    liquidityBitmap.unsetBitsRange(
                        state.startPip,
                        state.remainingLiquidity > 0
                            ? (state.isBuy ? state.pip - 1 : state.pip + 1)
                            : state.pip
                    );
                }
                // TODO write a checkpoint that we shift a range of ticks
            } else if (
                _maxPip != 0 &&
                _initialSingleSlot.pip == state.pip &&
                state.remainingSize < _size &&
                state.remainingSize != 0
            ) {
                // if limit order with max pip filled current pip, toggle current pip to initialized
                // after that when create new limit order will initialize pip again in `OpenLimitPosition`
                liquidityBitmap.toggleSingleBit(state.pip, false);
            }

            if (state.remainingSize != _size) {
                // if limit order with max pip filled other order, update isFullBuy
                singleSlot.isFullBuy = state.isFullBuy;
            }
            if (_maxPip != 0) {
                // if limit order still have remainingSize, change current price to limit price
                // else change current price to last matched pip
                singleSlot.pip = state.remainingSize != 0
                    ? _maxPip
                    : state.lastMatchedPip;
            } else {
                singleSlot.pip = state.pip;
            }
        }

        sizeOut = _size - state.remainingSize;
        _addReserveSnapshot();

        if (sizeOut != 0) {
            if (_isBase) {
                emit MarketFilled(
                    state.isBuy,
                    sizeOut,
                    singleSlot.pip,
                    state.startPip,
                    state.remainingLiquidity,
                    tickPosition[singleSlot.pip].calculatingFilledIndex()
                );
            } else {
                emit MarketFilled(
                    state.isBuy,
                    openOtherSide,
                    singleSlot.pip,
                    state.startPip,
                    state.remainingLiquidity,
                    tickPosition[singleSlot.pip].calculatingFilledIndex()
                );
            }

            emitEventSwap(state.isBuy, sizeOut, openOtherSide, _trader);
        }
    }

    //*
    // HOOK HERE *
    //*
    function _emitLimitOrderUpdatedHook(
        address spotManager,
        uint64 orderId,
        uint128 pip,
        uint256 size
    ) internal virtual {}

    struct CrossPipResult {
        int128 hookBaseCrossPip;
        int128 hookQuoteCrossPip;
        uint8 pipRangeLiquidityIndex;
        uint128 toPip;

    }
    function _onCrossPipHook(uint128 pipNext, bool isBuy)
        internal
        view
        virtual
        returns (CrossPipResult memory crossPipResult)
    {}

    function emitEventSwap(
        bool isBuy,
        uint256 _baseAmount,
        uint256 _quoteAmount,
        address _trader
    ) internal virtual {}

    function _updateAmmState() external virtual {}

    function getLiquidityInPipRange(
        uint128 fromPip,
        uint256 dataLength,
        bool toHigher
    ) external view virtual returns (LiquidityOfEachPip[] memory, uint128) {}

    function getUnderlyingPriceInPip()
        internal
        view
        virtual
        returns (uint256)
    {}

    function _addReserveSnapshot() internal virtual {}
}
