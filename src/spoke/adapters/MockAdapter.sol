// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAdapter} from "./IAdapter.sol";
import {MockLendingPool} from "../../mocks/MockLendingPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract MockAdapter is IAdapter {
    using SafeERC20 for IERC20;

    MockLendingPool public immutable pool;
    IERC20 public immutable asset;

    constructor(address _pool, address _asset) {
        pool = MockLendingPool(_pool);
        asset = IERC20(_asset);
    }

    function deposit(uint256 amount) external override returns (uint256) {
        asset.safeIncreaseAllowance(address(pool), amount);
        pool.supply(address(asset), amount, address(this), 0);
        return amount;
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        return pool.withdraw(address(asset), amount, address(this));
    }

    function getTotalAssets() external view override returns (uint256) {
        return pool.balanceOf(address(this));
    }

    function getSupplyRate() external view override returns (uint256) {
        return pool.currentLiquidityRate();
    }
}