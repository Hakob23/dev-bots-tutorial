// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

/// @title Dollar Cost Averaging (DCA) bot.
/// @notice Allows Gearbox users to submit DCA orders, which automatically buy a fixed amount of tokens at regular intervals.
/// @dev Not designed to handle quoted tokens.
contract DCAOrderBot {
    // ----- //
    // TYPES //
    // ----- //

    /// @notice DCA order data.
    struct DCAOrder {
        address borrower;           // Address of the user who submitted the DCA order
        address manager;            // Address of the Gearbox credit manager
        address account;            // Address of the borrower's Gearbox credit account
        address tokenIn;            // Token being sold/exchanged
        address tokenOut;           // Token being bought
        uint256 amountPerInterval;  // Amount of `tokenIn` exchanged in each DCA execution
        uint256 interval;           // Time interval between each DCA execution (in seconds)
        uint256 nextExecutionTime;  // Timestamp when the next DCA execution can happen
        uint256 totalExecutions;    // Total number of executions for the DCA order
        uint256 executionsLeft;     // Number of executions left
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    /// @notice Pending DCA orders.
    mapping(uint256 => DCAOrder) public dcaOrders;

    /// @dev DCA orders counter. This keeps track of the ID of the next DCA order.
    uint256 internal _nextDCAOrderId;

    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when a user submits a new DCA order.
    /// @param user The user that submitted the order.
    /// @param orderId ID of the created DCA order.
    event CreateDCAOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when a user cancels a DCA order.
    /// @param user The user who canceled the order.
    /// @param orderId ID of the canceled order.
    event CancelDCAOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when a DCA order is successfully executed.
    /// @param executor Account that executed the DCA order.
    /// @param orderId ID of the executed DCA order.
    event ExecuteDCAOrder(address indexed executor, uint256 indexed orderId);

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice Thrown when a user tries to submit or cancel another user's DCA order.
    error CallerNotBorrower();

    /// @notice Thrown when trying to execute a canceled order.
    error OrderIsCancelled();

    /// @notice Thrown when a DCA order can't be executed because it is invalid.
    error InvalidOrder();

    /// @notice Thrown when trying to execute a DCA order before the interval has passed.
    error NotTimeYet();

    /// @notice Thrown when a DCA order has no more executions left.
    error NoExecutionsLeft();

    /// @notice Thrown when the user has insufficient tokens to sell.
    error NothingToSell();


    // ------------------ //
    // EXTERNAL FUNCTIONS //
    // ------------------ //

    /// @notice Submit a new DCA order.
    /// @param dcaOrder The DCA order to submit.
    /// @return orderId The ID of the created DCA order.
    function submitDCAOrder(DCAOrder calldata dcaOrder) external returns (uint256 orderId) {
        // Ensure the caller is the borrower and the borrower is the current owner of the Gearbox account.
        if (
            dcaOrder.borrower != msg.sender
                || ICreditManagerV3(dcaOrder.manager).getBorrowerOrRevert(dcaOrder.account) != dcaOrder.borrower
        ) {
            revert CallerNotBorrower();
        }

        // Generate a new order ID and store the DCA order.
        orderId = _useDCAOrderId();
        dcaOrders[orderId] = dcaOrder;

        // Emit an event notifying the DCA order has been created.
        emit CreateDCAOrder(msg.sender, orderId);
    }

    /// @notice Cancel a pending DCA order.
    /// @param orderId ID of the DCA order to cancel.
    function cancelDCAOrder(uint256 orderId) external {
        DCAOrder storage dcaOrder = dcaOrders[orderId];

        // Ensure the caller is the borrower of the DCA order.
        if (dcaOrder.borrower != msg.sender) {
            revert CallerNotBorrower();
        }

        // Delete the DCA order from storage and emit a cancellation event.
        delete dcaOrders[orderId];
        emit CancelDCAOrder(msg.sender, orderId);
    }

    /// @notice Execute a DCA order.
    /// @param orderId ID of the DCA order to execute.
    function executeDCAOrder(uint256 orderId) external {
        DCAOrder storage dcaOrder = dcaOrders[orderId];

        // Validate the DCA order (check for balance, time, etc.) and get the amount to be exchanged.
        (uint256 amountIn, uint256 minAmountOut) = _validateDCAOrder(dcaOrder);

        // The executor sends the `tokenOut` to the contract and approves the manager.
        IERC20(dcaOrder.tokenOut).transferFrom(msg.sender, address(this), minAmountOut);
        IERC20(dcaOrder.tokenOut).approve(dcaOrder.manager, minAmountOut + 1);

        // Get the facade of the Gearbox credit manager to perform the multicall.
        address facade = ICreditManagerV3(dcaOrder.manager).creditFacade();

        // Create the multi-call for adding and withdrawing collateral using the DCA details.
        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (dcaOrder.tokenOut, minAmountOut))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (dcaOrder.tokenIn, amountIn, msg.sender))
        });
        ICreditFacadeV3(facade).botMulticall(dcaOrder.account, calls);

        // Update the DCA order for the next execution and decrease the executions left.
        dcaOrder.executionsLeft -= 1;
        dcaOrder.nextExecutionTime += dcaOrder.interval;

        // If no executions are left, delete the order.
        if (dcaOrder.executionsLeft == 0) {
            delete dcaOrders[orderId];
        }

        // Emit an event notifying that the DCA order has been executed.
        emit ExecuteDCAOrder(msg.sender, orderId);
    }

    // ------------------ //
    // INTERNAL FUNCTIONS //
    // ------------------ //

    /// @dev Increments the DCA order counter and returns its previous value.
    function _useDCAOrderId() internal returns (uint256 orderId) {
        orderId = _nextDCAOrderId;
        _nextDCAOrderId += 1;
    }

    /// @dev Validates the DCA order and ensures it can be executed.
    /// @param dcaOrder The DCA order to validate.
    /// @return amountIn The amount of `tokenIn` to be exchanged in this execution.
    /// @return minAmountOut The minimum amount of `tokenOut` that should be received.
    function _validateDCAOrder(DCAOrder memory dcaOrder) internal view returns (uint256 amountIn, uint256 minAmountOut) {
        ICreditManagerV3 manager = ICreditManagerV3(dcaOrder.manager);

        // Ensure the DCA order has not been cancelled.
        if (dcaOrder.account == address(0)) {
            revert OrderIsCancelled();
        }

        // Ensure there are executions left.
        if (dcaOrder.executionsLeft == 0) {
            revert NoExecutionsLeft();
        }

        // Ensure the time interval has passed for the next execution.
        if (block.timestamp < dcaOrder.nextExecutionTime) {
            revert NotTimeYet();
        }

        // Ensure the borrower is still the owner of the credit account.
        if (manager.getBorrowerOrRevert(dcaOrder.account) != dcaOrder.borrower) {
            revert InvalidOrder();
        }

        // Check the balance of `tokenIn` in the borrower's credit account.
        uint256 balanceIn = IERC20(dcaOrder.tokenIn).balanceOf(dcaOrder.account);
        if (balanceIn <= 1) {
            revert NothingToSell();
        }

        // Get the current price of the `tokenIn` to `tokenOut` pair from the price oracle.
        uint256 ONE = 10 ** IERC20Metadata(dcaOrder.tokenIn).decimals();
        uint256 price = IPriceOracleV3(manager.priceOracle()).convert(ONE, dcaOrder.tokenIn, dcaOrder.tokenOut);
        
        // Calculate how much `tokenIn` can be sold and the minimum amount of `tokenOut` to receive.
        amountIn = dcaOrder.amountPerInterval > balanceIn ? balanceIn - 1 : dcaOrder.amountPerInterval;
        minAmountOut = amountIn * price / ONE;
    }
}
