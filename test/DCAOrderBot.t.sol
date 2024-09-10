// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    ICreditFacadeV3Multicall,
    ALL_CREDIT_FACADE_CALLS_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DCAOrderBot} from "../src/DCAOrderBot.sol";
import {BotTestHelper} from "./BotTestHelper.sol";

contract DCAOrderBotTest is BotTestHelper {
    // tested bot
    DCAOrderBot public bot;
    ICreditAccountV3 creditAccount;

    // tokens
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // actors
    address user;
    address executor;

    function setUp() public {
        user = makeAddr("USER");
        executor = makeAddr("EXECUTOR");

        setUpGearbox("Trade USDC Tier 1");

        creditAccount = openCreditAccount(user, 50_000e6, 100_000e6);

        bot = new DCAOrderBot();
        vm.prank(user);
        creditFacade.setBotPermissions(
            address(creditAccount), address(bot), uint192(ALL_CREDIT_FACADE_CALLS_PERMISSION)
        );
    }

    function test_DCA_01_setUp_is_correct() public {
        assertEq(address(underlying), address(usdc), "Incorrect underlying");
        assertEq(creditManager.getBorrowerOrRevert(address(creditAccount)), user, "Incorrect account owner");
        assertEq(usdc.balanceOf(address(creditAccount)), 150_000e6, "Incorrect account balance of underlying");
        assertEq(creditFacade.botList(), address(botList), "Incorrect bot list");
    }

    function test_DCA_02_submitDCAOrder_reverts_if_caller_is_not_borrower() public {
        DCAOrderBot.DCAOrder memory dcaOrder;

        vm.expectRevert(DCAOrderBot.CallerNotBorrower.selector);
        vm.prank(user);
        bot.submitDCAOrder(dcaOrder);

        address caller = makeAddr("CALLER");
        dcaOrder.borrower = caller;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);

        vm.expectRevert(DCAOrderBot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.submitDCAOrder(dcaOrder);
    }

    function test_DCA_03_submitDCAOrder_works_as_expected_when_called_properly() public {
        DCAOrderBot.DCAOrder memory dcaOrder = DCAOrderBot.DCAOrder({
            borrower: user,
            manager: address(creditManager),
            account: address(creditAccount),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountPerInterval: 200_000e6,
            interval: 1 days,
            nextExecutionTime: block.timestamp + 1 days,
            totalExecutions: 10,
            executionsLeft: 10
        });

        vm.expectEmit(true, true, true, true);
        emit DCAOrderBot.CreateDCAOrder(user, 0);

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);
        assertEq(orderId, 0, "Incorrect orderId");

        _assertDCAOrderIsEqual(orderId, dcaOrder);
    }

    function test_DCA_04_cancelDCAOrder_reverts_if_caller_is_not_borrower() public {
        DCAOrderBot.DCAOrder memory dcaOrder;
        dcaOrder.borrower = user;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);

        address caller = makeAddr("CALLER");
        vm.expectRevert(DCAOrderBot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.cancelDCAOrder(orderId);
    }

    function test_DCA_05_cancelDCAOrder_works_as_expected_when_called_properly() public {
        DCAOrderBot.DCAOrder memory dcaOrder;
        dcaOrder.borrower = user;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);

        vm.expectEmit(true, true, true, true);
        emit DCAOrderBot.CancelDCAOrder(user, orderId);

        vm.prank(user);
        bot.cancelDCAOrder(orderId);

        _assertDCAOrderIsEmpty(orderId);
    }

    function test_DCA_06_executeDCAOrder_reverts_if_no_executions_left() public {
        DCAOrderBot.DCAOrder memory dcaOrder;
        dcaOrder.borrower = user;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);
        dcaOrder.executionsLeft = 0;

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);

        vm.expectRevert(DCAOrderBot.NoExecutionsLeft.selector);
        vm.prank(executor);
        bot.executeDCAOrder(orderId);
    }

    function test_DCA_07_executeDCAOrder_reverts_if_execution_time_has_not_passed() public {
        DCAOrderBot.DCAOrder memory dcaOrder;
        dcaOrder.borrower = user;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);
        dcaOrder.nextExecutionTime = block.timestamp + 1 days;
        dcaOrder.executionsLeft = 5;

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);

        vm.expectRevert(DCAOrderBot.NotTimeYet.selector);
        vm.prank(executor);
        bot.executeDCAOrder(orderId);
    }

    function test_DCA_08_executeOrder_reverts_if_order_is_cancelled() public {
        DCAOrderBot.DCAOrder memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(order);

        vm.prank(user);
        bot.cancelDCAOrder(orderId);

        vm.expectRevert(DCAOrderBot.OrderIsCancelled.selector);
        vm.prank(executor);
        bot.executeDCAOrder(orderId);
    }

    function test_DCA_09_executeDCAOrder_works_as_expected_when_called_properly() public {
        DCAOrderBot.DCAOrder memory dcaOrder;
        dcaOrder.borrower = user;
        dcaOrder.manager = address(creditManager);
        dcaOrder.account = address(creditAccount);
        dcaOrder.tokenIn = address(usdc);
        dcaOrder.tokenOut = address(weth);
        dcaOrder.amountPerInterval = 200_000e6;
        dcaOrder.interval = 1 days;
        dcaOrder.nextExecutionTime = block.timestamp;
        dcaOrder.executionsLeft = 5;

        vm.prank(user);
        uint256 orderId = bot.submitDCAOrder(dcaOrder);
        uint256 ONE = 10 ** IERC20Metadata(dcaOrder.tokenIn).decimals();
        uint256 price = IPriceOracleV3(creditManager.priceOracle()).convert(ONE, dcaOrder.tokenIn, dcaOrder.tokenOut);
       
        uint256 wethAmount = (150_000e6 - 1) * price / 1e6;
        deal({token: address(weth), to: executor, give: wethAmount});
        vm.prank(executor);
        weth.approve(address(bot), wethAmount);

        vm.expectEmit(true, true, true, true);
        emit DCAOrderBot.ExecuteDCAOrder(executor, orderId);
        vm.prank(executor);
        bot.executeDCAOrder(orderId);

        _assertDCAOrderHasRemainingExecutions(orderId, 4);

        assertEq(usdc.balanceOf(executor), 150_000e6/4-1, "Incorrect executor USDC balance");
        assertEq(weth.balanceOf(address(creditAccount)), wethAmount, "Incorrect account WETH balance");
    }

    function _assertDCAOrderIsEqual(uint256 orderId, DCAOrderBot.DCAOrder memory dcaOrder) internal {
        (
            address borrower,
            address manager,
            address account,
            address tokenIn,
            address tokenOut,
            uint256 amountPerInterval,
            uint256 interval,
            uint256 nextExecutionTime,
            uint256 totalExecutions,
            uint256 executionsLeft
        ) = bot.dcaOrders(orderId);
        assertEq(borrower, dcaOrder.borrower, "Incorrect borrower");
        assertEq(manager, dcaOrder.manager, "Incorrect manager");
        assertEq(account, dcaOrder.account, "Incorrect account");
        assertEq(tokenIn, dcaOrder.tokenIn, "Incorrect tokenIn");
        assertEq(tokenOut, dcaOrder.tokenOut, "Incorrect tokenOut");
        assertEq(amountPerInterval, dcaOrder.amountPerInterval, "Incorrect amountPerInterval");
        assertEq(interval, dcaOrder.interval, "Incorrect interval");
        assertEq(nextExecutionTime, dcaOrder.nextExecutionTime, "Incorrect nextExecutionTime");
        assertEq(totalExecutions, dcaOrder.totalExecutions, "Incorrect totalExecutions");
        assertEq(executionsLeft, dcaOrder.executionsLeft, "Incorrect executionsLeft");
    }

    function _assertDCAOrderHasRemainingExecutions(uint256 orderId, uint256 expectedExecutionsLeft) internal {
        (, , , , , , , , , uint256 executionsLeft) = bot.dcaOrders(orderId);
        assertEq(executionsLeft, expectedExecutionsLeft, "Incorrect executions left");
    }

    function _assertDCAOrderIsEmpty(uint256 orderId) internal {
        (
            address borrower,
            address manager,
            address account,
            address tokenIn,
            address tokenOut,
            uint256 amountPerInterval,
            uint256 interval,
            uint256 nextExecutionTime,
            uint256 totalExecutions,
            uint256 executionsLeft
        ) = bot.dcaOrders(orderId);
        assertEq(borrower, address(0), "Incorrect borrower");
        assertEq(manager, address(0), "Incorrect manager");
        assertEq(account, address(0), "Incorrect account");
        assertEq(tokenIn, address(0), "Incorrect tokenIn");
        assertEq(tokenOut, address(0), "Incorrect tokenOut");
        assertEq(amountPerInterval, 0, "Incorrect amountPerInterval");
        assertEq(interval, 0, "Incorrect interval");
        assertEq(nextExecutionTime, 0, "Incorrect nextExecutionTime");
        assertEq(totalExecutions, 0, "Incorrect totalExecutions");
        assertEq(executionsLeft, 0, "Incorrect executionsLeft");
    }
}
