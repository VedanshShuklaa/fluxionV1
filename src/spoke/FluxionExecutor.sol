// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCIPReceiver} from "@chainlink/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FluxionTypes} from "../shared/FluxionTypes.sol";
import {IAdapter} from "./adapters/IAdapter.sol";

/**
 * @title FluxionExecutor (Spoke)
 * @notice Receives instructions and tokens from Hub (Sepolia).
 * @dev Updated for Real Token Transfers via CCIP Programmable Token Transfers.
 */
contract FluxionExecutor is CCIPReceiver {
    using SafeERC20 for IERC20;

    address public immutable i_hubAddress;
    uint64 public immutable i_hubChainSelector;
    address public immutable i_asset;

    event ExecutorAction(address indexed adapter, FluxionTypes.SpokeAction action, uint256 amount);
    event TokensSentToHub(uint256 amount, bytes32 messageId);

    constructor(
        address _router,
        address _hub,
        uint64 _hubChainId,
        address _asset
    ) CCIPReceiver(_router) {
        i_hubAddress = _hub;
        i_hubChainSelector = _hubChainId;
        i_asset = _asset;
    }

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        require(any2EvmMessage.sourceChainSelector == i_hubChainSelector, "Wrong Source Chain");
        address sender = abi.decode(any2EvmMessage.sender, (address));
        require(sender == i_hubAddress, "Wrong Sender");

        FluxionTypes.SpokeInstruction memory instruction = abi.decode(
            any2EvmMessage.data,
            (FluxionTypes.SpokeInstruction)
        );

        if (instruction.action == FluxionTypes.SpokeAction.DEPOSIT) {
            // Use the tokens that just arrived in this CCIP message
            require(any2EvmMessage.destTokenAmounts.length > 0, "No tokens arrived");
            uint256 amountArrived = any2EvmMessage.destTokenAmounts[0].amount;
            _handleDeposit(instruction.adapter, amountArrived);
        } else if (instruction.action == FluxionTypes.SpokeAction.WITHDRAW) {
            _handleWithdraw(instruction.adapter, instruction.amount);
        }
    }

    function _handleDeposit(address adapter, uint256 amount) internal {
        // 1. Approve the adapter to take the tokens that arrived via CCIP
        IERC20(i_asset).safeIncreaseAllowance(adapter, amount);

        // 2. Deposit into the lending pool
        IAdapter(adapter).deposit(amount);

        emit ExecutorAction(adapter, FluxionTypes.SpokeAction.DEPOSIT, amount);
    }

    function _handleWithdraw(address adapter, uint256 amount) internal {
        // 1. Withdraw tokens from the lending pool adapter back to this contract
        uint256 withdrawn = IAdapter(adapter).withdraw(amount);
        require(withdrawn > 0, "Withdraw failed");

        // 2. Send the REAL TOKENS back to the Hub
        _sendTokensBackToHub(withdrawn);

        emit ExecutorAction(adapter, FluxionTypes.SpokeAction.WITHDRAW, withdrawn);
    }

    function _sendTokensBackToHub(uint256 amount) internal {
        // 1. Prepare token array for bridging
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: i_asset, 
            amount: amount
        });

        // 2. Construct CCIP Message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(i_hubAddress),
            data: abi.encode(amount), // Send amount in data for Hub accounting
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000})),
            feeToken: address(0) // Native ETH
        });

        IRouterClient router = IRouterClient(getRouter());
        
        // 3. Approve router to take tokens
        IERC20(i_asset).safeIncreaseAllowance(address(router), amount);

        // 4. Send (Note: Fees must be available in the contract balance)
        uint256 fees = router.getFee(i_hubChainSelector, message);
        require(address(this).balance >= fees, "Insufficient fee balance");
        
        bytes32 msgId = router.ccipSend{value: fees}(i_hubChainSelector, message);

        emit TokensSentToHub(amount, msgId);
    }

    // Required to receive ETH for CCIP fees from the Hub or Admin
    receive() external payable {}
}