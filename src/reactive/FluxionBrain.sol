// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "@reactive/abstract-base/AbstractReactive.sol";

contract FluxionBrain is AbstractReactive {
    uint256 public constant RAY = 1e27;
    address public owner;

    // Yield Thresholds
    uint256 public MIN_YIELD_DELTA_RAY = (uint256(5) * RAY) / 1000; // 0.5%
    uint256 public HYSTERESIS_BUFFER_RAY = (uint256(5) * RAY) / 1000; // 0.5% Buffer for reactivation

    uint256 public minLiquidityBuffer; 
    uint16 public rebalanceFractionBps = 2000; // 20%
    uint256 public rebalanceCooldown = 30 seconds;
    uint256 public lastRebalanceTimestamp;
    uint256 public GAS_LIMIT_CALLBACK = 600_000;

    // Topics
    uint256 constant TOPIC_RESERVE_UPDATED = uint256(keccak256("ReserveDataUpdated(address,uint256,uint256,uint256,uint256,uint256)"));
    uint256 constant TOPIC_VAULT_DEPOSITED = uint256(keccak256("VaultDeposited(uint256,address)"));
    uint256 constant TOPIC_STRATEGY_ACTIVATED = uint256(keccak256("StrategyActivated(address,uint256)"));
    uint256 constant TOPIC_STRATEGY_DEACTIVATED = uint256(keccak256("StrategyDeactivated(address,uint256)"));

    struct PoolState {
        uint64 chainId;
        address poolAddress;
        uint256 currentRateRay;
        uint256 lastUpdateTimestamp;
        uint256 availableLiquidity; 
        uint256 allocation; 
        bool isActive;
        uint256 poolId;
        // Risk Management
        uint256 stopLossRateRay;      // Below this, we pull funds
        uint256 reactivationRateRay;  // Above this, we re-enter (StopLoss + Buffer)
    }

    mapping(uint256 => PoolState) public poolStates;
    uint256[] public activePoolIds;
    mapping(uint256 => bool) private _poolExists;

    // Lifecycle
    bool public isActiveStrategy; 
    uint256 public vaultIdleBalance; 
    mapping(uint256 => bool) public hasAllocation;
    mapping(uint256 => uint256) public frozenWeightRay; 
    uint256[] public frozenPoolIds; 

    // Hub Config
    uint64 public hubchainId;
    address public hubAddress;

    /* Events */
    event PoolRegistered(uint256 indexed poolId, uint64 chainId, address poolAddress);
    event PoolUpdated(uint256 indexed poolId, uint256 rateRay, uint256 liquidity, uint256 allocation);
    event RebalanceScheduled(uint256 indexed fromPoolId, uint256 indexed toPoolId, uint256 amount, uint256 timestamp);
    event StrategyAllocated(uint256 totalAllocated);
    event StrategyDeallocated(uint256 timestamp);
    
    // Risk Events
    event StopLossTriggered(uint256 indexed poolId, uint256 rate, uint256 targetPoolId);
    event PoolReactivated(uint256 indexed poolId, uint256 rate);

    // Debug Events
    event DebugReact(uint256 indexed topic0, uint256 chainId, address pool, bytes data);
    event DebugMatchAttempt(uint256 poolId, address stored, address incoming, bool matchResult);
    event DebugVaultDeposit(address depositor, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Auth");
        _;
    }

    constructor(uint64 _hubchainId, address _hubAddress, uint256 _minLiquidityBuffer) {
        require(_hubAddress != address(0), "hub=0");
        owner = msg.sender;
        hubchainId = _hubchainId;
        hubAddress = _hubAddress;
        minLiquidityBuffer = _minLiquidityBuffer;
        isActiveStrategy = false;
    }

    function initialize() external {
        service.subscribe(hubchainId, hubAddress, TOPIC_STRATEGY_ACTIVATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(hubchainId, hubAddress, TOPIC_STRATEGY_DEACTIVATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(hubchainId, hubAddress, TOPIC_VAULT_DEPOSITED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /* ==================== Registration ==================== */

    function registerPool(
        uint256 poolId,
        uint64 chainId,
        address poolAddress,
        uint256 initialLiquidity,
        uint256 initialAllocation,
        uint256 initialRateRay,       // NEW: Prevent 0-rate start
        uint256 stopLossRateRay       // NEW: Risk threshold
    ) external onlyOwner {
        require(!_poolExists[poolId], "exists");

        // Subscribe using the Pool Address
        service.subscribe(chainId, poolAddress, TOPIC_RESERVE_UPDATED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);

        PoolState storage ps = poolStates[poolId];
        ps.chainId = chainId;
        ps.poolAddress = poolAddress;
        
        // Initial State Injection
        ps.currentRateRay = initialRateRay;
        ps.lastUpdateTimestamp = block.timestamp;
        ps.availableLiquidity = initialLiquidity;
        ps.allocation = initialAllocation;
        ps.isActive = true; // Starts active unless initialRate < stopLoss (checked later)
        ps.poolId = poolId;
        
        // Risk Config
        ps.stopLossRateRay = stopLossRateRay;
        ps.reactivationRateRay = stopLossRateRay + HYSTERESIS_BUFFER_RAY;

        activePoolIds.push(poolId);
        _poolExists[poolId] = true;
        if (initialAllocation > 0) hasAllocation[poolId] = true;

        // Immediate Sanity Check: If registered with a bad rate, deactivate immediately
        if (initialRateRay < stopLossRateRay) {
             ps.isActive = false;
        }

        emit PoolRegistered(poolId, chainId, poolAddress);
    }

    /* ==================== Reactive Loop ==================== */

    function react(LogRecord calldata log) external override {
        emit DebugReact(log.topic_0, log.chain_id, log._contract, log.data);

        if (log.topic_0 == TOPIC_RESERVE_UPDATED) {
            _handleReserveUpdate(log.chain_id, log._contract, log.data);
            return;
        }
        
        // ... (Other handlers) ...
        if (log.topic_0 == TOPIC_VAULT_DEPOSITED) {
            (uint256 amount, address depositor) = abi.decode(log.data, (uint256,address));
            emit DebugVaultDeposit(depositor, amount);
            vaultIdleBalance += amount;
            if (isActiveStrategy && frozenPoolIds.length > 0) _allocateUsingFrozenWeights();
            return;
        }

        if (log.topic_0 == TOPIC_STRATEGY_ACTIVATED) {
            if (!isActiveStrategy) _runAllocationLogic();
            return;
        }

        if (log.topic_0 == TOPIC_STRATEGY_DEACTIVATED) {
            isActiveStrategy = false;
            for (uint256 i = 0; i < activePoolIds.length; i++) {
                uint256 pid = activePoolIds[i];
                poolStates[pid].allocation = 0;
                hasAllocation[pid] = false;
            }
            delete frozenPoolIds; 
            emit StrategyDeallocated(block.timestamp);
            return;
        }
    }

    /* ==================== Logic ==================== */

    function _handleReserveUpdate(uint256 chainId, address poolContract, bytes calldata data) internal {
        uint256 found = 0;
        uint256 len = activePoolIds.length;

        // ORIGINAL LOOP LOGIC (With uint160 robustness)
        for (uint256 i = 0; i < len; i++) {
            uint256 pid = activePoolIds[i];
            PoolState storage ps = poolStates[pid];
            
            bool isMatch = (uint160(ps.poolAddress) == uint160(poolContract));
            emit DebugMatchAttempt(pid, ps.poolAddress, poolContract, isMatch);

            // Removed 'ps.isActive' check here so we can catch updates even if inactive (for reactivation)
            if (isMatch) {
                found = pid;
                break;
            }
        }

        if (found == 0) return;

        (uint256 liquidityRate, , , uint256 liquidityIndex, ) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256));

        PoolState storage t = poolStates[found];
        t.currentRateRay = liquidityRate;
        t.lastUpdateTimestamp = block.timestamp;
        t.availableLiquidity = liquidityIndex;

        emit PoolUpdated(found, liquidityRate, liquidityIndex, t.allocation);

        // --- RISK MANAGEMENT START ---
        if (t.isActive) {
            // Check Stop Loss
            if (liquidityRate < t.stopLossRateRay) {
                _triggerStopLoss(found);
                return; // Exit after emergency trigger
            }
        } else {
            // Check Reactivation (Hysteresis)
            if (liquidityRate > t.reactivationRateRay) {
                t.isActive = true;
                emit PoolReactivated(found, liquidityRate);
            }
        }
        // --- RISK MANAGEMENT END ---

        if (isActiveStrategy && t.isActive) {
            _evaluateAndTrigger(found);
        }
    }

    // NEW: Emergency Exit Function
    function _triggerStopLoss(uint256 failingPoolId) internal {
        PoolState storage badPs = poolStates[failingPoolId];
        badPs.isActive = false; // Kill switch
        
        uint256 amountToSave = badPs.allocation;
        if (amountToSave == 0) {
            emit StopLossTriggered(failingPoolId, badPs.currentRateRay, 0);
            return;
        }

        // Find best alternative
        uint256 bestPoolId = 0;
        uint256 bestRate = 0;
        uint256 len = activePoolIds.length;

        for (uint256 i = 0; i < len; i++) {
            uint256 pid = activePoolIds[i];
            PoolState storage ps = poolStates[pid];
            // Must be active and not the failing one
            if (ps.isActive && pid != failingPoolId && ps.availableLiquidity >= minLiquidityBuffer) {
                if (ps.currentRateRay > bestRate) {
                    bestRate = ps.currentRateRay;
                    bestPoolId = pid;
                }
            }
        }

        // Execution
        if (bestPoolId != 0) {
            PoolState storage bestPs = poolStates[bestPoolId];
            
            // Optimistic update
            badPs.allocation = 0;
            bestPs.allocation += amountToSave;

            bytes memory payload = abi.encodeWithSignature(
                "onBrainRebalance(uint256,uint256,uint256)",
                failingPoolId,
                bestPoolId,
                amountToSave
            );

            emit Callback(hubchainId, hubAddress, uint64(GAS_LIMIT_CALLBACK), payload);
            emit StopLossTriggered(failingPoolId, badPs.currentRateRay, bestPoolId);
        } else {
            // No good pool found? Just mark inactive. 
            // In a real prod system, you might recall to Hub here, but rebalance is safer for now.
            emit StopLossTriggered(failingPoolId, badPs.currentRateRay, 0);
        }
    }

    function _evaluateAndTrigger(uint256 triggeredPoolId) internal {
        if (!isActiveStrategy) return;
        if (block.timestamp < lastRebalanceTimestamp + rebalanceCooldown) return;

        // ... (Standard logic remains same) ...
        uint256 bestPoolId = 0;
        uint256 bestRate = 0;
        uint256 len = activePoolIds.length;
        
        for (uint256 i = 0; i < len; i++) {
            uint256 pid = activePoolIds[i];
            PoolState storage ps = poolStates[pid];
            if (ps.isActive && ps.availableLiquidity >= minLiquidityBuffer) {
                if (ps.currentRateRay > bestRate) {
                    bestRate = ps.currentRateRay;
                    bestPoolId = pid;
                }
            }
        }

        if (bestPoolId == 0) return;

        uint256 worstPoolId = 0;
        uint256 worstRate = type(uint256).max;
        
        for (uint256 i = 0; i < len; i++) {
            uint256 pid = activePoolIds[i];
            PoolState storage ps = poolStates[pid];
            if (ps.isActive && ps.allocation > 0) {
                if (ps.currentRateRay < worstRate) {
                    worstRate = ps.currentRateRay;
                    worstPoolId = pid;
                }
            }
        }

        if (worstPoolId == 0 || worstPoolId == bestPoolId) return;
        if (bestRate <= worstRate + MIN_YIELD_DELTA_RAY) return;

        PoolState storage worstPs = poolStates[worstPoolId];
        PoolState storage bestPs = poolStates[bestPoolId];
        
        uint256 candidateAmount = (worstPs.allocation * uint256(rebalanceFractionBps)) / 10000;
        uint256 amountToMove = _min(candidateAmount, bestPs.availableLiquidity);
        
        if (amountToMove == 0) return;

        worstPs.allocation -= amountToMove;
        bestPs.allocation += amountToMove;

        bytes memory payload = abi.encodeWithSignature(
            "onBrainRebalance(uint256,uint256,uint256)",
            worstPoolId,
            bestPoolId,
            amountToMove
        );

        emit Callback(hubchainId, hubAddress, uint64(GAS_LIMIT_CALLBACK), payload);
        emit RebalanceScheduled(worstPoolId, bestPoolId, amountToMove, block.timestamp);

        lastRebalanceTimestamp = block.timestamp;
    }

    function _runAllocationLogic() internal {
        require(!isActiveStrategy, "already active");
        uint256 totalScore = 0;
        uint256 len = activePoolIds.length;
        uint256[] memory candidateIds = new uint256[](len);
        uint256 candidateCount = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 pid = activePoolIds[i];
            PoolState storage ps = poolStates[pid];
            if (!ps.isActive || ps.availableLiquidity < minLiquidityBuffer) continue;
            
            uint256 score = (ps.currentRateRay * ps.availableLiquidity) / RAY;
            if (score == 0) continue;
            
            candidateIds[candidateCount] = pid;
            candidateCount++;
            totalScore += score;
        }

        require(candidateCount > 0, "no candidates");

        delete frozenPoolIds;
        for (uint256 i = 0; i < candidateCount; i++) {
            uint256 pid = candidateIds[i];
            PoolState storage ps = poolStates[pid];
            
            uint256 score = (ps.currentRateRay * ps.availableLiquidity) / RAY;
            uint256 w = (totalScore > 0) ? (score * RAY) / totalScore : 0;
            
            frozenWeightRay[pid] = w;
            frozenPoolIds.push(pid);
        }

        isActiveStrategy = true; 
        _allocateUsingFrozenWeights();
    }

    function _allocateUsingFrozenWeights() internal {
        uint256 idle = vaultIdleBalance;
        if (idle == 0) return;
        uint256 totalAllocated = 0;
        uint256 n = frozenPoolIds.length;

        for (uint256 i = 0; i < n; i++) {
            uint256 pid = frozenPoolIds[i];
            uint256 wRay = frozenWeightRay[pid];
            if (wRay == 0) continue;

            uint256 amt = (i < n - 1) ? (idle * wRay) / RAY : (idle - totalAllocated);
            if (amt == 0) continue;

            PoolState storage ps = poolStates[pid];
            uint256 capped = _min(amt, ps.availableLiquidity);
            if (capped == 0) continue;

            ps.allocation += capped;
            hasAllocation[pid] = true;

            bytes memory payload = abi.encodeWithSignature(
                "pushFunds(uint256,uint256,uint256)",
                pid,
                capped,
                GAS_LIMIT_CALLBACK
            );

            emit Callback(hubchainId, hubAddress, uint64(GAS_LIMIT_CALLBACK), payload);
            emit PoolUpdated(pid, ps.currentRateRay, ps.availableLiquidity, ps.allocation);

            totalAllocated += capped;
        }

        if (totalAllocated > 0) {
            vaultIdleBalance = (vaultIdleBalance > totalAllocated) ? vaultIdleBalance - totalAllocated : 0;
            emit StrategyAllocated(totalAllocated);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function getActivePoolIds() external view returns (uint256[] memory) {
        return activePoolIds;
    }
}