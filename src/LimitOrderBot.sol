// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Counters } from "@openzeppelin/contracts/utils/Counters.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Balance } from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { ICreditManagerV3 } from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import { ICreditFacadeV3 } from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import { ICreditFacadeV3Multicall } from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import { IPriceOracleV3 } from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";


/// @notice Limit order data.
struct Order {
    address borrower;
    address manager;
    address creditAccount;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 limitPrice;
    uint256 triggerPrice;
    uint256 deadline;
}


/// @title Limit order bot.
/// @notice Allows Gearbox users to submit limit sell orders.
///         Arbitrary accounts can execute orders by providing a multicall that swaps assets.
contract LimitOrderBot {
    using Counters for Counters.Counter;

    /// --------------- ///
    /// STATE VARIABLES ///
    /// --------------- ///

    /// @notice Pending orders.
    mapping(uint256 => Order) public orders;

    /// @dev Orders counter.
    Counters.Counter private _nextOrderId;

    /// ------ ///
    /// EVENTS ///
    /// ------ ///

    /// @notice Emitted when user submits a new order.
    /// @param user User that submitted the order.
    /// @param orderId ID of the created order.
    event OrderCreated(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when user cancels the order.
    /// @param user User that canceled the order.
    /// @param orderId ID of the canceled order.
    event OrderCanceled(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when order is successfully executed.
    /// @param executor Account that executed the order.
    /// @param orderId ID of the executed order.
    event OrderExecuted(address indexed executor, uint256 indexed orderId);

    /// ------ ///
    /// ERRORS ///
    /// ------ ///

    /// @notice When user tries to submit/cancel other user's order.
    error CallerNotBorrower();

    /// @notice When order can't be executed because it's incorrect.
    error InvalidOrder();

    /// @notice When trying to execute order after deadline.
    error Expired();

    /// @notice When trying to execute order while it's not triggered.
    error NotTriggered();

    /// @notice When user has no input token on their balance.
    error NothingToSell();

    /// @notice When the credit account's owner changed between order submission and execution.
    error CreditAccountBorrowerChanged();

    /// ------------------ ///
    /// EXTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @notice Submit new order.
    /// @param order Order to submit.
    /// @return orderId ID of created order.
    function submitOrder(Order calldata order) external returns (uint256 orderId) {
        if (order.borrower != msg.sender || ICreditManagerV3(order.manager).getBorrowerOrRevert(order.creditAccount) != order.borrower) {
            revert CallerNotBorrower();
        }
        orderId = _useOrderId();
        orders[orderId] = order;
        emit OrderCreated(msg.sender, orderId);
    }

    /// @notice Cancel pending order.
    /// @param orderId ID of order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.borrower != msg.sender)
            revert CallerNotBorrower();
        delete orders[orderId];
        emit OrderCanceled(msg.sender, orderId);
    }

    /// @notice Execute given order using provided multicall.
    /// @param orderId ID of order to execute.
    /// @param calls Multicall needed to execute an order.
    function executeOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        (
            address creditAccount,
            uint256 balanceBefore,
            uint256 amountIn,
            uint256 minAmountOut
        ) = _validateOrder(order);

        IERC20(order.tokenOut).transferFrom(msg.sender, address(this), minAmountOut);
        IERC20(order.tokenOut).approve(order.manager, minAmountOut + 1);

        MultiCall[] memory calls = new MultiCall[](2);

        address facade = ICreditManagerV3(order.manager).creditFacade();

        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (order.tokenOut, minAmountOut))
        });

        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (order.tokenIn, amountIn, msg.sender))
        });

        ICreditFacadeV3(facade).botMulticall(order.creditAccount, calls);

        delete orders[orderId];
        emit OrderExecuted(msg.sender, orderId);
    }

    /// ------------------ ///
    /// INTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @dev Increments the order counter and returns its previous value.
    function _useOrderId() internal returns (uint256 orderId) {
        orderId = _nextOrderId.current();
        _nextOrderId.increment();
    }

    /// @dev Checks if order can be executed:
    ///      * order must be correctly constructed and not expired;
    ///      * trigger condition must hold if trigger price is set;
    ///      * borrower must have an account in manager with non-empty
    ///        input token balance.
    function _validateOrder(Order memory order)
        internal
        view
        returns (
            uint256 amountIn,
            uint256 minAmountOut
        )
    {
        if (ICreditManagerV3(order.manager).getBorrowerOrRevert(order.creditAccount) != order.borrower) {
            revert CreditAccountBorrowerChanged();
        }

        if (order.tokenIn == order.tokenOut || order.amountIn == 0)
            revert InvalidOrder();

        if (order.deadline > 0 && block.timestamp > order.deadline)
            revert Expired();

        ICreditManagerV3 manager = ICreditManagerV3(order.manager);
        uint256 ONE = 10 ** IERC20Metadata(order.tokenIn).decimals();
        if (order.triggerPrice > 0) {
            uint256 price = IPriceOracleV3(manager.priceOracle()).convert(
                ONE, order.tokenIn, order.tokenOut
            );
            if (price > order.triggerPrice)
                revert NotTriggered();
        }

        uint256 balanceIn = IERC20(order.tokenIn).balanceOf(order.creditAccount);
        if (balanceIn <= 1)
            revert NothingToSell();

        amountIn = balanceIn > order.amountIn ? order.amountIn : balanceIn - 1;
        minAmountOut = amountIn * order.limitPrice / ONE;
    }

}
