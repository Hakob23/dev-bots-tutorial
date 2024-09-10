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
import {console} from "forge-std/console.sol";
/// @title Dollar Cost Averaging (DCA) bot.
/// @notice Allows Gearbox users to submit DCA orders, which automatically buy a fixed amount of tokens at regular intervals.
/// @dev Not designed to handle quoted tokens.
contract DCAOrderBot {
    // ----- //
    // TYPES //
    // ----- //

    /// @notice DCA order data.
    struct DCAOrder {
        address borrower;
        address manager;
        address account;
        address tokenIn;
        address tokenOut;
        uint256 amountPerInterval;
        uint256 interval; // in seconds
        uint256 nextExecutionTime;
        uint256 totalExecutions;
        uint256 executionsLeft;
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    /// @notice Pending DCA orders.
    mapping(uint256 => DCAOrder) public dcaOrders;

    /// @dev DCA orders counter.
    uint256 internal _nextDCAOrderId;

    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when user submits a new DCA order.
    /// @param user User that submitted the order.
    /// @param orderId ID of the created order.
    event CreateDCAOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when user cancels a DCA order.
    /// @param user User that canceled the order.
    /// @param orderId ID of the canceled order.
    event CancelDCAOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when a DCA order is successfully executed.
    /// @param executor Account that executed the DCA order.
    /// @param orderId ID of the executed DCA order.
    event ExecuteDCAOrder(address indexed executor, uint256 indexed orderId);

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice When user tries to submit/cancel other user's DCA order.
    error CallerNotBorrower();

    /// @notice When order can't be executed because it's cancelled.
    error OrderIsCancelled();

    /// @notice When DCA order can't be executed because it's incorrect.
    error InvalidOrder();

    /// @notice When trying to execute DCA order before the interval has passed.
    error NotTimeYet();

    /// @notice When no more executions are left for the DCA order.
    error NoExecutionsLeft();

    /// @notice When user has no input token on their balance.
    error NothingToSell();


    // ------------------ //
    // EXTERNAL FUNCTIONS //
    // ------------------ //

    /// @notice Submit new DCA order.
    /// @param dcaOrder DCA order to submit.
    /// @return orderId ID of the created DCA order.
    function submitDCAOrder(DCAOrder calldata dcaOrder) external returns (uint256 orderId) {
        if (
            dcaOrder.borrower != msg.sender
                || ICreditManagerV3(dcaOrder.manager).getBorrowerOrRevert(dcaOrder.account) != dcaOrder.borrower
        ) {
            revert CallerNotBorrower();
        }

        orderId = _useDCAOrderId();
        dcaOrders[orderId] = dcaOrder;
        emit CreateDCAOrder(msg.sender, orderId);
    }

    /// @notice Cancel a pending DCA order.
    /// @param orderId ID of the DCA order to cancel.
    function cancelDCAOrder(uint256 orderId) external {
        DCAOrder storage dcaOrder = dcaOrders[orderId];
        if (dcaOrder.borrower != msg.sender) {
            revert CallerNotBorrower();
        }
        delete dcaOrders[orderId];
        emit CancelDCAOrder(msg.sender, orderId);
    }

    /// @notice Execute a DCA order.
    /// @param orderId ID of the DCA order to execute.
    function executeDCAOrder(uint256 orderId) external {
        DCAOrder storage dcaOrder = dcaOrders[orderId];

        (uint256 amountIn, uint256 minAmountOut) = _validateDCAOrder(dcaOrder);

        IERC20(dcaOrder.tokenOut).transferFrom(msg.sender, address(this), minAmountOut);
        IERC20(dcaOrder.tokenOut).approve(dcaOrder.manager, minAmountOut + 1);

        address facade = ICreditManagerV3(dcaOrder.manager).creditFacade();

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (dcaOrder.tokenOut, minAmountOut))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (dcaOrder.tokenIn, amountIn/4, msg.sender))
        });
        console.log(amountIn);
        ICreditFacadeV3(facade).botMulticall(dcaOrder.account, calls);

        dcaOrder.executionsLeft -= 1;
        dcaOrder.nextExecutionTime += dcaOrder.interval;

        if (dcaOrder.executionsLeft == 0) {
            delete dcaOrders[orderId];
        }

        emit ExecuteDCAOrder(msg.sender, orderId);
    }

    // ------------------ //
    // INTERNAL FUNCTIONS //
    // ------------------ //

    /// @dev Increments the DCA order counter and returns its previous value.
    function _useDCAOrderId() internal returns (uint256 orderId) {
        orderId = _nextDCAOrderId;
        _nextDCAOrderId = orderId + 1;
    }

    /// @dev Validates the DCA order and ensures it can be executed.
    function _validateDCAOrder(DCAOrder memory dcaOrder) internal view returns (uint256 amountIn, uint256 minAmountOut) {
        
        ICreditManagerV3 manager = ICreditManagerV3(dcaOrder.manager);
        if (dcaOrder.account == address(0)) {
            revert OrderIsCancelled();
        }

        if (dcaOrder.executionsLeft == 0) {
            revert NoExecutionsLeft();
        }

        if (block.timestamp < dcaOrder.nextExecutionTime) {
            revert NotTimeYet();
        }

        if (manager.getBorrowerOrRevert(dcaOrder.account) != dcaOrder.borrower) {
            revert InvalidOrder();
        }

        uint256 balanceIn = IERC20(dcaOrder.tokenIn).balanceOf(dcaOrder.account);
        if (balanceIn <= 1) {
            revert NothingToSell();
        }

        uint256 ONE = 10 ** IERC20Metadata(dcaOrder.tokenIn).decimals();
        uint256 price = IPriceOracleV3(manager.priceOracle()).convert(ONE, dcaOrder.tokenIn, dcaOrder.tokenOut);
        amountIn = dcaOrder.amountPerInterval > balanceIn ? balanceIn - 1 : dcaOrder.amountPerInterval;
        minAmountOut = amountIn * price / ONE; // Assuming a 1:1 conversion ratio for simplicity
    }
}
