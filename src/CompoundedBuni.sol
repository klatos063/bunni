// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.7.6;
pragma abicoder v2;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {Multicall} from "@uniswap/v3-periphery/contracts/base/Multicall.sol";
import {SelfPermit} from "@uniswap/v3-periphery/contracts/base/SelfPermit.sol";
import {PositionKey} from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {PeripheryValidation} from "@uniswap/v3-periphery/contracts/base/PeripheryValidation.sol";

import {ERC20} from "./lib/ERC20.sol";
import {LiquidityManagement} from "./uniswap/LiquidityManagement.sol";

/// @title CompoundedBuni
/// @author zefram.eth
/// @notice A fractionalized Uniswap v3 LP position represented by an ERC20 token.
/// Supports one-sided liquidity adding and compounding fees earned back into the
/// liquidity position.
contract CompoundedBuni is
    ERC20,
    LiquidityManagement,
    Multicall,
    PeripheryValidation,
    SelfPermit
{
    /// @notice the key of this LP position in the Uniswap pool
    bytes32 public immutable positionKey;
    /// @notice the fee growth of the aggregate position as of the last action on the individual position
    uint256 public feeGrowthInside0LastX128;
    uint256 public feeGrowthInside1LastX128;
    /// @notice how many uncollected fee tokens are owed to the position, as of the last computation
    uint128 public feesOwed0;
    uint128 public feesOwed1;
    /// @notice the liquidity of the position
    uint128 public liquidity;

    constructor(
        string memory _name,
        string memory _symbol,
        IUniswapV3Pool _pool,
        int24 _tickLower,
        int24 _tickUpper,
        address _WETH9
    )
        ERC20(_name, _symbol, 18)
        LiquidityManagement(_pool, _tickLower, _tickUpper, _WETH9)
    {
        positionKey = PositionKey.compute(
            address(this),
            _tickLower,
            _tickUpper
        );
    }

    struct DepositParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`
    /// @param params amount0Desired The desired amount of token0 to be spent,
    /// amount1Desired The desired amount of token1 to be spent,
    /// amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    /// amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    /// deadline The time by which the transaction must be included to effect the change
    /// @return shares The new tokens (this) minted to the sender
    /// @return addedLiquidity The new liquidity amount as a result of the increase
    /// @return amount0 The amount of token0 to acheive resulting liquidity
    /// @return amount1 The amount of token1 to acheive resulting liquidity
    function deposit(DepositParams calldata params)
        external
        payable
        checkDeadline(params.deadline)
        returns (
            uint256 shares,
            uint128 addedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint128 existingLiquidity = liquidity;
        (addedLiquidity, amount0, amount1) = _deposit(
            params,
            existingLiquidity
        );
        shares = _mintShares(addedLiquidity, existingLiquidity);
    }

    function depositOneside() external {}

    struct WithdrawParams {
        address recipient;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Decreases the amount of liquidity in the position and sends the tokens to the sender.
    /// If withdrawing ETH, need to follow up with unwrapWETH9() and sweepToken()
    /// @param params recipient The user if not withdrawing ETH, address(0) if withdrawing ETH
    /// shares The amount of ERC20 tokens (this) to burn,
    /// amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    /// amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    /// deadline The time by which the transaction must be included to effect the change
    /// @return removedLiquidity The amount of liquidity decrease
    /// @return amount0 The amount of token0 withdrawn to the recipient
    /// @return amount1 The amount of token1 withdrawn to the recipient
    function withdraw(WithdrawParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (
            uint128 removedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        return _withdraw(params);
    }

    function withdrawOneside() external {}

    /// @notice Claims the trading fees earned and uses it to add liquidity.
    /// @return addedLiquidity The new liquidity amount as a result of the increase
    /// @return amount0 The amount of token0 added to the liquidity position
    /// @return amount1 The amount of token1 added to the liquidity position
    function compound()
        external
        returns (
            uint128 addedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        return _compound();
    }

    /// @dev See {CompoundedBuni::deposit}
    function _deposit(DepositParams calldata params, uint128 existingLiquidity)
        internal
        returns (
            uint128 addedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // add liquidity to Uniswap pool
        (addedLiquidity, amount0, amount1) = _addLiquidity(
            LiquidityManagement.AddLiquidityParams({
                recipient: address(this),
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        // this is now updated to the current transaction
        (
            ,
            uint256 updatedFeeGrowthInside0LastX128,
            uint256 updatedFeeGrowthInside1LastX128,
            ,

        ) = pool.positions(positionKey);

        // update position
        feesOwed0 += uint128(
            FullMath.mulDiv(
                updatedFeeGrowthInside0LastX128 - feeGrowthInside0LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            )
        );
        feesOwed1 += uint128(
            FullMath.mulDiv(
                updatedFeeGrowthInside1LastX128 - feeGrowthInside1LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            )
        );
        feeGrowthInside0LastX128 = updatedFeeGrowthInside0LastX128;
        feeGrowthInside1LastX128 = updatedFeeGrowthInside1LastX128;
        liquidity = existingLiquidity + addedLiquidity;

        // TODO: emit event
    }

    function _depositOneside() internal {}

    /// @dev See {CompoundedBuni::withdraw}
    function _withdraw(WithdrawParams calldata params)
        internal
        returns (
            uint128 removedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        // allow collecting to address(this) with address 0
        // this is used for withdrawing ETH
        address recipient = params.recipient == address(0)
            ? address(this)
            : params.recipient;

        // burn shares
        require(params.shares > 0, "0");
        uint256 currentTotalSupply = totalSupply;
        _burn(msg.sender, params.shares);
        // at this point of execution we know param.shares <= currentTotalSupply
        // since otherwise the _burn() call would've reverted

        // burn liquidity from pool
        uint128 existingLiquidity = liquidity;
        // type cast is safe because we know removedLiquidity <= existingLiquidity
        removedLiquidity = uint128(
            FullMath.mulDiv(
                existingLiquidity,
                params.shares,
                currentTotalSupply
            )
        );
        // burn liquidity
        // tokens are now collectable in the pool
        (amount0, amount1) = pool.burn(tickLower, tickUpper, removedLiquidity);
        // collect tokens and give to msg.sender
        (amount0, amount1) = pool.collect(
            recipient,
            tickLower,
            tickUpper,
            uint128(amount0),
            uint128(amount1)
        );
        require(
            amount0 >= params.amount0Min && amount1 >= params.amount1Min,
            "SLIPPAGE"
        );

        // update position
        // this is now updated to the current transaction
        (
            ,
            uint256 updatedFeeGrowthInside0LastX128,
            uint256 updatedFeeGrowthInside1LastX128,
            ,

        ) = pool.positions(positionKey);
        feesOwed0 += uint128(
            FullMath.mulDiv(
                updatedFeeGrowthInside0LastX128 - feeGrowthInside0LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            )
        );
        feesOwed1 += uint128(
            FullMath.mulDiv(
                updatedFeeGrowthInside1LastX128 - feeGrowthInside1LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            )
        );
        feeGrowthInside0LastX128 = updatedFeeGrowthInside0LastX128;
        feeGrowthInside1LastX128 = updatedFeeGrowthInside1LastX128;
        // subtraction is safe because we checked removedLiquidity <= existingLiquidity
        liquidity = existingLiquidity - removedLiquidity;

        // TODO: emit event
    }

    function _withdrawOneside() internal {}

    /// @dev See {CompoundedBuni::compound}
    function _compound()
        internal
        returns (
            uint128 addedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint128 cachedFeesOwed0 = feesOwed0;
        uint128 cachedFeesOwed1 = feesOwed1;
        uint128 existingLiquidity = liquidity;

        /// -----------------------------------------------------------
        /// amount0, amount1 are multi-purposed, see comments below
        /// -----------------------------------------------------------
        amount0 = cachedFeesOwed0;
        amount1 = cachedFeesOwed1;

        // trigger an update of the position fees owed and fee growth snapshots if it has any liquidity
        if (existingLiquidity > 0) {
            pool.burn(tickLower, tickUpper, 0);
            (
                ,
                uint256 updatedFeeGrowthInside0LastX128,
                uint256 updatedFeeGrowthInside1LastX128,
                ,

            ) = pool.positions(positionKey);

            amount0 += FullMath.mulDiv(
                updatedFeeGrowthInside0LastX128 - feeGrowthInside0LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            );
            amount1 += FullMath.mulDiv(
                updatedFeeGrowthInside1LastX128 - feeGrowthInside1LastX128,
                existingLiquidity,
                FixedPoint128.Q128
            );

            feeGrowthInside0LastX128 = updatedFeeGrowthInside0LastX128;
            feeGrowthInside1LastX128 = updatedFeeGrowthInside1LastX128;
        }

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the updated amounts of fee owed
        /// -----------------------------------------------------------

        // the fee is likely not balanced (i.e. tokens will be left over after adding liquidity)
        // so here we compute which side to fully claim and which side to partially claim
        // so that we only claim the amounts we need

        {
            (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

            if (sqrtRatioX96 <= sqrtRatioAX96) {
                // token0 used fully, token1 used partially
                uint128 liquidityIncrease = LiquidityAmounts
                    .getLiquidityForAmount0(
                        sqrtRatioAX96,
                        sqrtRatioBX96,
                        amount0
                    );
                amount1 = LiquidityAmounts.getAmount1ForLiquidity(
                    sqrtRatioAX96,
                    sqrtRatioBX96,
                    liquidityIncrease
                );
            } else if (sqrtRatioX96 < sqrtRatioBX96) {
                // uncertain which token is used fully
                uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(
                    sqrtRatioX96,
                    sqrtRatioBX96,
                    amount0
                );
                uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(
                    sqrtRatioAX96,
                    sqrtRatioX96,
                    amount1
                );

                if (liquidity0 < liquidity1) {
                    // token0 used fully, token1 used partially
                    amount1 = LiquidityAmounts.getAmount1ForLiquidity(
                        sqrtRatioAX96,
                        sqrtRatioBX96,
                        liquidity0
                    );
                } else {
                    // token0 used partially, token1 used fully
                    amount0 = LiquidityAmounts.getAmount0ForLiquidity(
                        sqrtRatioAX96,
                        sqrtRatioBX96,
                        liquidity1
                    );
                }
            } else {
                // token0 used partially, token1 used fully
                uint128 liquidityIncrease = LiquidityAmounts
                    .getLiquidityForAmount1(
                        sqrtRatioAX96,
                        sqrtRatioBX96,
                        amount1
                    );
                amount0 = LiquidityAmounts.getAmount0ForLiquidity(
                    sqrtRatioAX96,
                    sqrtRatioBX96,
                    liquidityIncrease
                );
            }
        }

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the amount of fees to claim
        /// -----------------------------------------------------------

        // the actual amounts collected are returned
        // tokens are transferred to address(this)
        (amount0, amount1) = pool.collect(
            address(this),
            tickLower,
            tickUpper,
            uint128(amount0),
            uint128(amount1)
        );

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the fees claimed
        /// -----------------------------------------------------------

        // update feesOwed
        feesOwed0 = uint128(cachedFeesOwed0 - amount0);
        feesOwed1 = uint128(cachedFeesOwed1 - amount1);

        // add fees to Uniswap pool
        (addedLiquidity, amount0, amount1) = _addLiquidity(
            LiquidityManagement.AddLiquidityParams({
                recipient: address(this),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the tokens added as liquidity
        /// -----------------------------------------------------------

        liquidity = existingLiquidity + addedLiquidity;

        // TODO: emit event
    }

    /// @notice Mints share tokens (this) to the sender based on the amount of liquidity added.
    /// @param addedLiquidity The amount of liquidity added
    /// @param existingLiquidity The amount of existing liquidity before the add
    /// @return shares The amount of share tokens minted to the sender.
    function _mintShares(uint128 addedLiquidity, uint128 existingLiquidity)
        internal
        returns (uint256 shares)
    {
        uint256 existingShareSupply = totalSupply;
        if (existingShareSupply == 0) {
            // no existing shares, bootstrap at rate 1:1
            shares = addedLiquidity;
        } else {
            // shares = existingShareSupply * addedLiquidity / existingLiquidity;
            shares = FullMath.mulDiv(
                existingShareSupply,
                addedLiquidity,
                existingLiquidity
            );
        }

        // mint shares to sender
        _mint(msg.sender, shares);

        // TODO: emit event
    }
}
