// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CCIPReceiver} from "@chainlink/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {FluxionTypes} from "../shared/FluxionTypes.sol";
import {IPoolRegistry} from "./IPoolRegistry.sol";

/**
 * @title FluxionVault (Hub)
 * @notice Central Hub on Sepolia. Orchestrates token moves via CCIP based on Brain instructions.
 * Features:
 * - Real Token Transfers (USDC/LINK)
 * - Optimistic Remote Accounting
 * - Pending Rebalance Queue for Async Flows
 */
contract FluxionVault is ERC4626, AccessControl, CCIPReceiver {
    using SafeERC20 for IERC20;

    bytes32 public constant REACTIVE_ROLE = keccak256("REACTIVE_ROLE");

    IRouterClient public immutable i_router;
    IPoolRegistry public immutable i_registry;

    mapping(uint64 => uint256) public remoteBalances;
    uint256 private _totalRemoteAssets;

    // Maps SourcePoolId -> DestinationPoolId
    // Used to automatically trigger a Push when a Recall arrives.
    mapping(uint256 => uint256) public pendingRebalances;

    enum StrategyState { IDLE, ACTIVE }
    StrategyState public strategyState;

    /* ================= Events ================= */
    event FundsPushed(uint64 indexed destinationChain, uint256 amount, bytes32 messageId);
    event RecallTriggered(uint64 indexed sourceChain, uint256 amount, bytes32 messageId);
    event StrategyActivated(address indexed caller, uint256 timestamp);
    event StrategyDeactivated(address indexed caller, uint256 timestamp);
    event VaultDeposited(uint256 amount, address indexed user);
    event RemoteBalanceUpdated(uint64 indexed chainSelector, uint256 newBalance);
    event FundsReceivedFromSpoke(uint64 indexed sourceChain, address indexed executor, uint256 amount);
    event AutoRebalanceTriggered(uint256 indexed fromPoolId, uint256 indexed toPoolId, uint256 amount);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _router,
        address _registry,
        address _admin
    ) ERC4626(_asset) ERC20(_name, _symbol) CCIPReceiver(_router) {
        i_router = IRouterClient(_router);
        i_registry = IPoolRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        strategyState = StrategyState.IDLE;
    }

    /* ================= ERC4626 OVERRIDES ================= */

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + _totalRemoteAssets;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        emit VaultDeposited(assets, receiver);
        return shares;
    }

    /* ================= STRATEGY LIFECYCLE ================= */

    function activateStrategy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(strategyState == StrategyState.IDLE, "Already active");
        strategyState = StrategyState.ACTIVE;
        emit StrategyActivated(msg.sender, block.timestamp);
    }

    function deactivateStrategy(uint256 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(strategyState == StrategyState.ACTIVE, "Not active");
        uint256[] memory poolIds = i_registry.getAllPoolIds();
        for (uint256 i = 0; i < poolIds.length; i++) {
            if (poolIds[i] == 0) continue;
            _sendRecall(poolIds[i], type(uint256).max, gasLimit);
        }
        strategyState = StrategyState.IDLE;
        emit StrategyDeactivated(msg.sender, block.timestamp);
    }

    /* ================= REACTIVE CALLBACKS ================= */

    /**
     * @notice Initiates a rebalance. Only triggers the RECALL first.
     * @dev The PUSH happens automatically in _ccipReceive when funds arrive.
     */
    function onBrainRebalance(uint256 fromPoolId, uint256 toPoolId, uint256 amount) external onlyRole(REACTIVE_ROLE) {
        require(strategyState == StrategyState.ACTIVE, "IDLE");
        require(fromPoolId != toPoolId, "Same Pool");

        // 1. Queue the Intent
        pendingRebalances[fromPoolId] = toPoolId;

        // 2. Trigger ONLY the Recall (Pull funds home)
        // Note: We do NOT push yet because we don't have the tokens locally.
        _sendRecall(fromPoolId, amount, 200_000); 
    }


    /* ================= INTERNAL CCIP LOGIC ================= */

    function _sendPush(uint256 poolId, uint256 amount, uint256 gasLimit) internal {
        FluxionTypes.PoolConfig memory config = i_registry.getPoolConfig(poolId);
        require(config.isActive, "Inactive");
        require(amount <= IERC20(asset()).balanceOf(address(this)), "Low Balance");

        // 1. Pack tokens (Real Transfer)
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(asset()), amount: amount});

        // 2. Pack Instructions
        bytes memory data = abi.encode(FluxionTypes.SpokeInstruction({
            adapter: config.adapter,
            action: FluxionTypes.SpokeAction.DEPOSIT,
            amount: amount
        }));

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(config.executor),
            data: data,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0) // Native ETH fees
        });

        // 3. Approval & Send
        IERC20(asset()).safeIncreaseAllowance(address(i_router), amount);
        uint256 fees = i_router.getFee(config.chainSelector, message);
        bytes32 messageId = i_router.ccipSend{value: fees}(config.chainSelector, message);

        _updateRemoteBalance(config.chainSelector, remoteBalances[config.chainSelector] + amount);
        emit FundsPushed(config.chainSelector, amount, messageId);
    }

    function _sendRecall(uint256 poolId, uint256 amount, uint256 gasLimit) internal {
        FluxionTypes.PoolConfig memory config = i_registry.getPoolConfig(poolId);
        
        bytes memory data = abi.encode(FluxionTypes.SpokeInstruction({
            adapter: config.adapter,
            action: FluxionTypes.SpokeAction.WITHDRAW,
            amount: amount
        }));

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(config.executor),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0), // Data Only
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit})),
            feeToken: address(0)
        });

        uint256 fees = i_router.getFee(config.chainSelector, message);
        bytes32 messageId = i_router.ccipSend{value: fees}(config.chainSelector, message);
        emit RecallTriggered(config.chainSelector, amount, messageId);
    }

    function _ccipReceive(Client.Any2EVMMessage memory msg_) internal override {
        address sender = abi.decode(msg_.sender, (address));
        uint64 sourceChain = msg_.sourceChainSelector;
        require(i_registry.isValidExecutor(sourceChain, sender), "Invalid Executor");

        require(msg_.destTokenAmounts.length == 1, "Expected token return");
        require(msg_.destTokenAmounts[0].token == address(asset()), "Wrong token");
        uint256 inboundAmount = msg_.destTokenAmounts[0].amount;

        // 1. Update Accounting
        uint256 reported = remoteBalances[sourceChain];
        _updateRemoteBalance(sourceChain, reported >= inboundAmount ? reported - inboundAmount : 0);
        emit FundsReceivedFromSpoke(sourceChain, sender, inboundAmount);

        // 2. CHECK PENDING REBALANCES (The Auto-Forwarder)
        if (inboundAmount > 0) {
            // Find the poolId for this incoming sender
            uint256 incomingPoolId = 0;
            uint256[] memory allPools = i_registry.getAllPoolIds();
            for(uint i=0; i<allPools.length; i++) {
                FluxionTypes.PoolConfig memory cfg = i_registry.getPoolConfig(allPools[i]);
                if(cfg.chainSelector == sourceChain && cfg.executor == sender) {
                    incomingPoolId = allPools[i];
                    break;
                }
            }

            // If we found the pool ID, check if we owe this money to another pool
            if (incomingPoolId != 0) {
                uint256 targetPoolId = pendingRebalances[incomingPoolId];
                
                if (targetPoolId != 0) {
                    // Clear the pending state
                    delete pendingRebalances[incomingPoolId];

                    // Execute the Push immediately
                    // Tokens are already in `totalAssets` (local), so this is safe.
                    _sendPush(targetPoolId, inboundAmount, 200_000);
                    
                    emit AutoRebalanceTriggered(incomingPoolId, targetPoolId, inboundAmount);
                }
            }
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, CCIPReceiver)
        returns (bool)
    {
        return
            AccessControl.supportsInterface(interfaceId) ||
            CCIPReceiver.supportsInterface(interfaceId);
    }


    function _updateRemoteBalance(uint64 sel, uint256 bal) internal {
        _totalRemoteAssets = _totalRemoteAssets - remoteBalances[sel] + bal;
        remoteBalances[sel] = bal;
        emit RemoteBalanceUpdated(sel, bal);
    }

    receive() external payable {}
}