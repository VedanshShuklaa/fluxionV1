// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAdapter {
    /**
     * @notice Deposits underlying asset into the protocol.
     * @param amount The amount of asset to deposit.
     * @return assetsDeposited Actual amount deposited (handling potential fees/slippage).
     */
    function deposit(uint256 amount) external returns (uint256 assetsDeposited);

    /**
     * @notice Withdraws underlying asset from the protocol.
     * @param amount The amount to withdraw.
     * @return assetsReceived Actual amount received.
     */
    function withdraw(uint256 amount) external returns (uint256 assetsReceived);

    /**
     * @notice Returns the total assets (principal + interest) held in the protocol.
     */
    function getTotalAssets() external view returns (uint256);

    /**
     * @notice Returns the current APY (in Ray or bps) for the strategy.
     * @dev Used by the Reactive Brain to calculate f_L * f_W.
     */
    function getSupplyRate() external view returns (uint256);
}