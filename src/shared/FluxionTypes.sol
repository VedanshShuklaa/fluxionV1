// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title FluxionTypes
 * @notice Shared Types, Enums, and Structs for cross-chain messaging.
 */
library FluxionTypes {
    /// @notice Actions that the Executor on the spoke chain can perform.
    enum SpokeAction {
        DEPOSIT,                // Deposit received funds into the adapter
        WITHDRAW                // Withdraw funds from adapter and send back to Hub
    }

    /// @notice The payload sent via CCIP from Hub -> Spoke.
    struct SpokeInstruction {
        address adapter;        // address of adapter of the lending pool we're dealing with
        SpokeAction action;     // the action we're doing (Deposit or Withdraw)
        uint256 amount;         // Amount to deposit or withdraw
    }

    // Metadata for a registered spoke pool
    struct PoolConfig {
        uint64 chainSelector;   // CCIP Chain Selector
        address executor;       // Address of FluxionExecutor on remote chain
        address adapter;        // Address of the specific adapter on remote chain
        bool isActive;          // Whether this pool is currently active for cross-chain operations
    }
}