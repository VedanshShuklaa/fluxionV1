// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockLendingPool is ERC20 {
    using SafeERC20 for IERC20;

    address public underlyingAsset;
    uint256 public currentLiquidityRate; // APY in Ray (1e27)

    // Track total underlying liquidity held by the pool
    uint256 public totalLiquidity;

    // Generic simplified event useful for Reactive Network listeners
    event RateUpdated(uint256 rate, uint256 liquidity);

    // Aave V3-style event (The signal for the Reactive Brain)
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );

    /**
     * @param _asset The ERC20 underlying token (e.g., USDC)
     */
    constructor(address _asset, uint256 _initialLiquidityRate) ERC20("Mock aToken", "maUSDC") {
        underlyingAsset = _asset;
        currentLiquidityRate = _initialLiquidityRate;
        totalLiquidity = 0;
    }

    /**
     * @notice Supply underlying into the pool and receive mock aTokens 1:1.
     * @dev Transfers underlying from msg.sender and mints onBehalfOf the equivalent aTokens.
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) external {
        require(asset == underlyingAsset, "Wrong asset");
        // Transfer asset from user to this pool (safe)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // Mint mock aTokens 1:1
        _mint(onBehalfOf, amount);

        // Update liquidity tracking
        totalLiquidity += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == underlyingAsset, "Wrong asset");
        // Ensure pool has enough underlying to honor the withdraw
        require(IERC20(asset).balanceOf(address(this)) >= amount, "insufficient pool liquidity");

        // Burn the caller's aTokens (reverts if balance insufficient)
        _burn(msg.sender, amount);

        // Transfer underlying to receiver (safe)z
        IERC20(asset).safeTransfer(to, amount);

        // Update liquidity tracking
        unchecked {
            // safe since we checked balance before
            totalLiquidity -= amount;
        }

        return amount;
    }

    function setLiquidityRate(uint256 newRateRay) external {
        currentLiquidityRate = newRateRay;

        // Emit both a simple signal and an Aave-compatible event
        emit RateUpdated(newRateRay, totalLiquidity);

        emit ReserveDataUpdated(
            underlyingAsset,
            newRateRay,
            0,
            0,
            totalLiquidity, // using liquidityIndex field to surface liquidity for demo purposes
            0
        );
    }

    function getLiquidityRate() external view returns (uint256) {
        return currentLiquidityRate;
    }
}
