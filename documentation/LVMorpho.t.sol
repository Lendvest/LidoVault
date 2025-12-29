// SPDX-License-Identifier: MIT
/* solhint-disable no-console */
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {LVLidoVault} from "../contracts/LVLidoVault.sol";
import "../contracts/interfaces/pool/erc20/IERC20PoolFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {LiquidationProxy} from "../contracts/LiquidationProxy.sol";

import {LVToken} from "../contracts/LVToken.sol";
import {IPoolInfoUtils} from "../contracts/interfaces/IPoolInfoUtils.sol";
import {IERC20Pool} from "../contracts/interfaces/pool/erc20/IERC20Pool.sol";
//import {LogarithmicBucketMatcher} from "../contracts/LogarithmicBucketMatcher.sol";
import {TestHelpers} from "./TestHelpers.t.sol";
import {IWsteth} from "../contracts/interfaces/vault/IWsteth.sol";
import {VaultLib} from "../contracts/libraries/VaultLib.sol";
import {LVLidoVaultUtil} from "../contracts/LVLidoVaultUtil.sol";
/*
    Terminology:
    - Mid Epoch Withdrawal = MEW
    - Double Epoch = DE
    - MToMToM = 3 Lender orders, 3 borrower orders, 3 collateral lender orders
    - 1To1To1 = 1 Lender order, 1 borrower order, 1 collateral lender order
    - BorrPartFill = Borrower order is partially filled due to insufficient lender deposits or collateral lender collateral
 */

contract LVMorphoTest is Test, TestHelpers {
    LVToken private lvweth;
    IERC20 private weth;
    IWsteth private wsteth;
    LVToken private lvwsteth;
    LVLidoVault private lvlido;
    LiquidationProxy private liquidationProxy;
    IERC20Pool private ajnaPool;
    LVLidoVaultUtil private lvlidoVaultUtil;
    // Ethereum Mainnet Addresses
    // Ajna Addresses
    address public constant POOL_FACTORY_ADDRESS = 0x6146DD43C5622bB6D12A5240ab9CF4de14eDC625;
    //address public constant POOL_INFO_UTILS = 0x30c5eF2997d6a882DE52c4ec01B6D0a5e5B4fAAE;

    // LVLidoVault Variables
    address owner = 0x6f33D099880D4b08AAd6B80c26423ec138318520;
    address garbage = makeAddr("garbage");
    address forwarder = makeAddr("forwarder");

    function setUp() public {
        vm.startPrank(owner);
        weth = IERC20(WETH_ADDRESS);
        wsteth = IWsteth(WSTETH_ADDRESS);
        lvweth = new LVToken("LV WETH", "LVWETH");
        lvwsteth = new LVToken("LV WSTETH", "LVWSTETH");

        // Deploy the Ajna pool using the pool factory
        IERC20PoolFactory poolFactory = IERC20PoolFactory(POOL_FACTORY_ADDRESS);
        address ajnaPoolAddress =
            poolFactory.deployPool(address(lvwsteth), address(lvweth), 100000000000000000 /*20000000000000000 2%*/ );
        ajnaPool = IERC20Pool(ajnaPoolAddress);
        // Deploy the Liquidation Proxy
        liquidationProxy = new LiquidationProxy(ajnaPoolAddress);
        //matcher = new LogarithmicBucketMatcher();
        // Deploy the LVLidoVault
        lvlido = new LVLidoVault(
            ajnaPoolAddress, // pool
            address(liquidationProxy) // liquidationProxy
        );
        lvlidoVaultUtil = new LVLidoVaultUtil(address(lvlido));
        lvlido.setLVLidoVaultUtilAddress(address(lvlidoVaultUtil));
        //matcher.setVaultAddress(address(lvlido));
        //matcher.renounceOwnership();
        lvwsteth.transferOwnership(address(lvlido));
        lvweth.transferOwnership(address(lvlido));
        liquidationProxy.transferOwnership(address(lvlido));
        lvlido.setForwarderAddress(forwarder);
        vm.stopPrank();
    }

    struct Order {
        address wallet;
        uint256 amount;
    }

    // what if multiple borrowers come in?
    function testMorphoIntegration() public {
        // Create multiple lender orders, borrower orders, and collateral lender orders
        Order[] memory lenderOrders = new Order[](5);
        Order[] memory borrowerOrders = new Order[](5);
        Order[] memory collateralLenderOrders = new Order[](5);
        for (uint256 i = 0; i < 5; i++) {
            lenderOrders[i] = Order({wallet: makeAddr(string.concat("lender", vm.toString(i))), amount: 1000 ether});
            borrowerOrders[i] = Order({wallet: makeAddr(string.concat("borrower", vm.toString(i))), amount: 10 ether});
            collateralLenderOrders[i] =
                Order({wallet: makeAddr(string.concat("collateralLender", vm.toString(i))), amount: 100 ether});
        }

        for (uint256 i = 0; i < 5; i++) {
            console.log("--------------------------------");
            console.log("Epoch", i);
            console.log("--------------------------------");
            for (uint256 index = 0; index < 5; index++) {
                Order memory lenderOrder = lenderOrders[index];
                Order memory borrowerOrder = borrowerOrders[index];
                Order memory collateralLenderOrder = collateralLenderOrders[index];
                vm.startPrank(lenderOrder.wallet);
                if (i == 0) deal(WETH_ADDRESS, lenderOrder.wallet, lenderOrder.amount);
                IERC20(WETH_ADDRESS).approve(address(lvlido), lenderOrder.amount);
                console.log("Starting WETH Balance of Lender", weth.balanceOf(lenderOrder.wallet));
                lvlido.createLenderOrder(lenderOrder.amount);
                vm.stopPrank();
            }
            if (i == 0) {
                for (uint256 index = 0; index < 5; index++) {
                    Order memory borrowerOrder = borrowerOrders[index];
                    Order memory collateralLenderOrder = collateralLenderOrders[index];
                    vm.startPrank(borrowerOrder.wallet);
                    if (i == 0) deal(WSTETH_ADDRESS, borrowerOrder.wallet, borrowerOrder.amount);
                    IERC20(WSTETH_ADDRESS).approve(address(lvlido), borrowerOrder.amount);
                    lvlido.createBorrowerOrder(borrowerOrder.amount);
                    vm.stopPrank();
                    vm.startPrank(collateralLenderOrder.wallet);
                    if (i == 0) deal(WSTETH_ADDRESS, collateralLenderOrder.wallet, collateralLenderOrder.amount);
                    IERC20(WSTETH_ADDRESS).approve(address(lvlido), collateralLenderOrder.amount);
                    lvlido.createCLOrder(collateralLenderOrder.amount);
                    vm.stopPrank();
                }
            }
            vm.prank(owner);
            lvlido.startEpoch(22 days);
            console.log("Term Length:", lvlido.termEnd() - lvlido.epochStart());
            console.log("flagshipVaultShares", lvlido.flagshipVaultShares());
            for (uint256 index = 0; index < 5; index++) {
                Order memory lenderOrder = lenderOrders[index];
                vm.prank(lenderOrder.wallet);
                try lvlido.withdrawLenderOrder() returns (uint256 amount) {
                    console.log("Withdrawn Morpho Amount", amount);
                } catch (bytes memory reason) {}
            }
            endEpoch(false);
            for (uint256 index = 0; index < 5; index++) {
                Order memory lenderOrder = lenderOrders[index];
                vm.prank(lenderOrder.wallet);
                try lvlido.withdrawLenderOrder() {} catch (bytes memory reason) {}
                // balance of weth of lenderOrder.wallet
                uint256 wethBalance = weth.balanceOf(lenderOrder.wallet);
                console.log("Ending WETH Balance of Lender", wethBalance);
                // Update lender order amount
                lenderOrders[index].amount = wethBalance;
            }
            // Forward one hour to skip epoch cooldown period
            vm.warp(block.timestamp + 1 hours);
        }
        // Print LVLido WETH Balance
        console.log("LVLido WETH Balance", weth.balanceOf(address(lvlido)));
    }

    function endEpoch(bool skipRedemptionPeriod) public {
        if (lvlido.updateRateNeeded()) {
            vm.prank(owner);
            lvlido.setUpdateRateNeeded(false);
        }
        if (!lvlido.fundsQueued()) {
            if (!skipRedemptionPeriod && block.timestamp <= lvlido.termEnd()) {
                vm.warp(lvlido.termEnd() + 1);
            }
            (bool upkeepNeeded, bytes memory performData) = lvlidoVaultUtil.checkUpkeep(bytes(""));
            vm.prank(forwarder);
            lvlidoVaultUtil.performUpkeep(performData);

            processLidoQueue(wsteth.stEthPerToken());
        }

        (bool upkeepNeeded, bytes memory performData) = lvlidoVaultUtil.checkUpkeep(bytes(""));
        vm.prank(forwarder);
        lvlidoVaultUtil.performUpkeep(performData); // End the epoch
    }

    // FIXME
    /*function createOrders()
        public
        returns (Order[] memory lenderOrders, Order[] memory borrowerOrders, Order[] memory collateralLenderOrders)
    {
        // Create random number of lender orders (min 1 max 8) with random amounts (min 1 wei max 100 ether)

        Order[] memory lenderOrders = new Order[](vm.randomUint(1, 10));
        Order[] memory borrowerOrders = new Order[](vm.randomUint(1, 10));
        Order[] memory collateralLenderOrders = new Order[](vm.randomUint(1, 10));
        for (uint256 i = 0; i < lenderOrders.length; i++) {
            lenderOrders[i] =
                Order({wallet: makeAddr(string.concat("lender", vm.toString(i))), amount: vm.randomUint(1, 100 ether)});
        }
        for (uint256 i = 0; i < borrowerOrders.length; i++) {
            borrowerOrders[i] = Order({
                wallet: makeAddr(string.concat("borrower", vm.toString(i))),
                amount: vm.randomUint(1, 100 ether)
            });
        }
        for (uint256 i = 0; i < collateralLenderOrders.length; i++) {
            collateralLenderOrders[i] = Order({
                wallet: makeAddr(string.concat("collateralLender", vm.toString(i))),
                amount: vm.randomUint(1, 100 ether)
            });
        }

        for (uint256 i = 0; i < lenderOrders.length; i++) {
            vm.startPrank(lenderOrders[i].wallet);
            deal(WETH_ADDRESS, lenderOrders[i].wallet, lenderOrders[i].amount);
            IERC20(WETH_ADDRESS).approve(address(lvlido), lenderOrders[i].amount);
            lvlido.createLenderOrder(lenderOrders[i].amount);
            vm.stopPrank();
        }

        for (uint256 i = 0; i < borrowerOrders.length; i++) {
            vm.startPrank(borrowerOrders[i].wallet);
            deal(WSTETH_ADDRESS, borrowerOrders[i].wallet, borrowerOrders[i].amount);
            IERC20(WSTETH_ADDRESS).approve(address(lvlido), borrowerOrders[i].amount);
            lvlido.createBorrowerOrder(borrowerOrders[i].amount);
            vm.stopPrank();
        }

        for (uint256 i = 0; i < collateralLenderOrders.length; i++) {
            vm.startPrank(collateralLenderOrders[i].wallet);
            deal(WSTETH_ADDRESS, collateralLenderOrders[i].wallet, collateralLenderOrders[i].amount);
            IERC20(WSTETH_ADDRESS).approve(address(lvlido), collateralLenderOrders[i].amount);
            lvlido.createCLOrder(collateralLenderOrders[i].amount);
            vm.stopPrank();
        }

        // Return the orders
        return (lenderOrders, borrowerOrders, collateralLenderOrders);
    }*/
    // Helper functions

    function printBalances(address[] memory addresses, address token) public view {
        for (uint256 i = 0; i < addresses.length; i++) {
            console.log("i:", i, "Balance:", formatValue(IERC20(token).balanceOf(addresses[i])));
        }
    }

    function testAjnaPoolDepositSize() public {
        // Deposit into Ajna pool
        deal(WETH_ADDRESS, address(lvlido), 100 ether);
        vm.startPrank(address(lvlido));
        // Mint LVWETH to LVLidoVault
        weth.approve(address(lvweth), 100 ether);
        lvweth.mint(address(lvlido), 100 ether);
        uint256 approxDepositSize = (100 ether * (1e18 - poolInfoUtils.depositFeeRate(address(ajnaPool)))) / 1e18;
        lvweth.approve(address(ajnaPool), 100 ether);
        (, uint256 postFeeDepositSize) = ajnaPool.addQuoteToken(100 ether, 4156, block.timestamp + 3600);
        console.log("approxDepositSize", approxDepositSize);
        console.log("postFeeLenderDepositSize", postFeeDepositSize);
        console.log("Ajna Deposit Size", ajnaPool.depositSize());

        assertEq(postFeeDepositSize, approxDepositSize);
        assertEq(ajnaPool.depositSize(), approxDepositSize);
        assertEq(postFeeDepositSize, ajnaPool.depositSize());

        vm.stopPrank();
    }

    function printEpochInfo(address[] memory lenders, address[] memory borrowers) public view {
        // Get debt using pool info utils
        uint256 epoch = lvlido.epoch();
        console.log("Epoch", epoch);
        VaultLib.MatchInfo[] memory matches = lvlido.getEpochMatches(epoch);
        console.log("--------------------------------");
        console.log("Matches Info");
        console.log("--------------------------------");

        for (uint256 i = 0; i < matches.length; i++) {
            VaultLib.MatchInfo memory match_ = matches[i];
            address matchLender = match_.lender;
            address matchBorrower = match_.borrower;
            uint256 lenderIndex = 0;
            uint256 borrowerIndex = 0;
            for (uint256 j = 0; j < lenders.length; j++) {
                if (lenders[j] == matchLender) {
                    lenderIndex = j;
                }
            }
            for (uint256 j = 0; j < borrowers.length; j++) {
                if (borrowers[j] == matchBorrower) {
                    borrowerIndex = j;
                }
            }
            console.log(
                string.concat(
                    "Match ",
                    vm.toString(i),
                    " Lender Index: ",
                    vm.toString(lenderIndex),
                    " Borrower Index: ",
                    vm.toString(borrowerIndex),
                    " Quote Amount: ",
                    formatValue(match_.quoteAmount),
                    " Collateral Amount: ",
                    formatValue(match_.collateralAmount),
                    " Reserved Quote Amount: ",
                    formatValue(match_.reservedQuoteAmount)
                )
            );
        }

        console.log("--------------------------------");
    }

    function printBorrowerInfo() public view {
        // Get borrower order details and print
        // Get length of borrower orders
        uint256 borrowerOrdersLength = lvlido.getBorrowerOrdersLength();
        for (uint256 i = 0; i < borrowerOrdersLength; i++) {
            (address borrower, uint256 collateralToPledge) = lvlido.borrowerOrders(i);
            console.log(
                string.concat(
                    "Borrower Position ", vm.toString(i), ":", " collateralToPledge: ", formatValue(collateralToPledge)
                )
            );
        }
    }

    function printLenderInfo() public view {
        // Get lender order details and print
        uint256 lenderOrdersLength = lvlido.getLenderOrdersLength();
        for (uint256 i = 0; i < lenderOrdersLength; i++) {
            (address lender, uint256 depositAmount, uint256 vaultShares) = lvlido.lenderOrders(i);
            console.log(
                string.concat(
                    "Lender Position ",
                    vm.toString(i),
                    ":",
                    " amount: ",
                    formatValue(depositAmount),
                    " vaultShares: ",
                    formatValue(vaultShares)
                )
            );
        }
    }

    function printCollateralLenderInfo() public view {
        // Get collateral lender order details and print
        uint256 collateralLenderOrdersLength = lvlido.getCollateralLenderOrdersLength();
        uint256 totalCollateralLenderDeposit = 0;
        for (uint256 i = 0; i < collateralLenderOrdersLength; i++) {
            (address collateralLender, uint256 collateralLenderDeposit) = lvlido.collateralLenderOrders(i);
            console.log(
                string.concat(
                    "Collateral Lender Position ",
                    vm.toString(i),
                    ":",
                    " amount: ",
                    formatValue(collateralLenderDeposit)
                )
            );
            totalCollateralLenderDeposit += collateralLenderDeposit;
        }
        console.log("Total Collateral Lender Deposit", formatValue(totalCollateralLenderDeposit));
        console.log("LVLido Accounting WSTETH Deposit", formatValue(lvlido.totalCollateralLenderCT()));
        console.log("LVLido Accounting WSTETH Deposit Unutilized", formatValue(lvlido.totalCLDepositsUnutilized()));
    }

    function printCollateralLenderUtilization() public view {
        // Get collateral lender order details and print
        uint256 collateralLenderDepositsUtilized = lvlido.totalCLDepositsUtilized();
        console.log("Collateral Lender Deposits Utilized", formatValue(collateralLenderDepositsUtilized));
        uint256 collateralLenderDepositsUnutilized = lvlido.totalCLDepositsUnutilized();
        console.log("Collateral Lender Deposits Unutilized", formatValue(collateralLenderDepositsUnutilized));
        console.log(
            string.concat(
                "Collateral Lender Deposits Utilized Percentage: ",
                formatValue(
                    (collateralLenderDepositsUtilized * 1e20)
                        / (collateralLenderDepositsUtilized + collateralLenderDepositsUnutilized)
                ),
                " %"
            )
        );
    }
}
