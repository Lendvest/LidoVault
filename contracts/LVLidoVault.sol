// SPDX-License-Identifier: MIT
// Copyright (c) 2025 KLV1, Inc.
pragma solidity ^0.8.20;

import {IERC20} from "@balancer/solidity-utils/openzeppelin/IERC20.sol";
import {IERC20Pool} from "./interfaces/pool/erc20/IERC20Pool.sol";
import {IPoolInfoUtils} from "./interfaces/IPoolInfoUtils.sol";
import {ILVToken} from "./interfaces/ILVToken.sol";
import {ILiquidationProxy} from "./interfaces/ILiquidationProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultLib} from "./libraries/VaultLib.sol";
import {IWsteth} from "./interfaces/vault/IWsteth.sol";
import {IWeth} from "./interfaces/vault/IWeth.sol";
import {ISteth} from "./interfaces/vault/ISteth.sol";
import {IFlashLoanRecipient} from "@balancer/vault/IFlashLoanRecipient.sol";
import {IVault} from "@balancer/vault/IVault.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UD60x18} from "@prb/math/UD60x18.sol";

/// @author Lendvest Labs
contract LVLidoVault is IFlashLoanRecipient, Ownable {
    ILVToken public testCollateralToken;
    ILVToken public testQuoteToken;

    IERC20Pool public pool;
    ILiquidationProxy public liquidationProxy;
    IVault public constant vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    ISteth public constant steth = ISteth(VaultLib.STETH_ADDRESS);
    IWsteth public constant wsteth = IWsteth(VaultLib.COLLATERAL_TOKEN);
    IPoolInfoUtils public constant poolInfoUtils = IPoolInfoUtils(0x30c5eF2997d6a882DE52c4ec01B6D0a5e5B4fAAE);
    IERC4626 public constant flagshipVault = IERC4626(0x38989BBA00BDF8181F4082995b3DEAe96163aC5D);

    address public LVLidoVaultUtil;
    uint256 public totalBorrowAmount;
    uint256 public totalLenderQTUnutilized;
    uint256 public flagshipVaultShares;
    uint256 public totalLenderQTUtilized;
    uint256 public totalBorrowerCT;
    uint256 public totalBorrowerCTUnutilized;
    uint256 public totalCollateralLenderCT;
    uint256 public totalCLDepositsUnutilized;
    uint256 public totalCLDepositsUtilized;
    uint256 public currentBucketIndex;
    uint256 public epochStartRedemptionRate;
    uint256 public currentRedemptionRate;
    uint256 public collateralLenderTraunche = 0;
    uint256 inverseBorrowCLAmount = 2;
    uint256 public epoch = 0;
    uint256 public epochStart;
    uint256 public termDuration = 22 days;
    uint256 public lastEpochEnd;
    uint256 public constant epochCoolDownPeriod = 1 weeks;
    uint256 public deploymentTimestamp;
    uint256 public rate = 221e14;
    int256 public constant priceDifferencethreshold = -1e16; // -1%
    bool public epochStarted;
    bool private _borrowInitiated;
    bool public fundsQueued;

    VaultLib.LenderOrder[] public lenderOrders;
    VaultLib.BorrowerOrder[] public borrowerOrders;
    VaultLib.CollateralLenderOrder[] public collateralLenderOrders;
    mapping(uint256 => VaultLib.MatchInfo[]) public epochToMatches;
    mapping(uint256 => VaultLib.CollateralLenderOrder[]) public epochToCollateralLenderOrders;

    uint256 public requestId;
    uint256 public totalManualRepay;

    bool internal locked;

    /**
     * @notice Constructor
     * @param _pool The address of the Ajna Pool contract
     * @param _liquidationProxy The address of the Liquidation Proxy contract
     */
    constructor(address _pool, address _liquidationProxy) Ownable(msg.sender) {
        pool = IERC20Pool(_pool);
        liquidationProxy = ILiquidationProxy(_liquidationProxy);
        testCollateralToken = ILVToken(pool.collateralAddress());
        testQuoteToken = ILVToken(pool.quoteTokenAddress());
        deploymentTimestamp = block.timestamp;
    }

    receive() external payable {
        if (msg.sender != address(VaultLib.LIDO_WITHDRAWAL) && msg.sender != VaultLib.QUOTE_TOKEN) {
            revert VaultLib.Unauthorized();
        }
        emit VaultLib.FundsAdded(msg.value, address(this).balance, msg.sender);
    }

    fallback() external payable {
        revert VaultLib.Unauthorized();
    }

    modifier lock() {
        if (locked) revert VaultLib.ReentrantCall();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyProxy() {
        if (msg.sender != LVLidoVaultUtil && msg.sender != address(liquidationProxy)) {
            revert VaultLib.OnlyProxy();
        }
        _;
    }

    function maxFundsLimiter(uint256 quoteAmount, uint256 collateralAmount) public view returns (bool) {
        uint256 wethPrice = 2430;
        uint256 wstethPrice = (wethPrice * wsteth.stEthPerToken()) / 1e18;
        // Fetch total existing lender amounts, also consider the value of the vault shares (in WETH)
        uint256 totalQT =
            quoteAmount + totalLenderQTUtilized + totalLenderQTUnutilized + flagshipVault.maxWithdraw(address(this));
        // Fetch total existing borrower amounts (in WSTETH)
        uint256 totalCT = collateralAmount + totalBorrowerCT + totalCLDepositsUtilized + totalCLDepositsUnutilized;
        uint256 totalValue = ((totalQT * wethPrice) / 1e18) + ((totalCT * wstethPrice) / 1e18);
        return totalValue <= 10000;
    }

    /**
     * @notice Converts WETH to WSTETH through a series of token conversions
     * @dev Restricted to Balancer vault and LVLidoVaultUtil contract only
     * @dev Conversion flow:
     *      1. WETH -> ETH (unwrap)
     *      2. ETH -> stETH (stake with Lido)
     *      3. stETH -> wstETH (wrap)
     * @param amount Amount of WETH to convert
     * @return uint256 Amount of WSTETH received after conversion
     * @custom:security Only callable by authorized contracts
     */
    function wethToWsteth(uint256 amount) public returns (uint256) {
        // Validate caller authorization
        if (msg.sender != address(vault) && msg.sender != address(LVLidoVaultUtil)) {
            revert VaultLib.Unauthorized();
        }

        // Step 1: Unwrap WETH to ETH
        if (!IERC20(VaultLib.QUOTE_TOKEN).approve(address(VaultLib.QUOTE_TOKEN), amount)) {
            revert VaultLib.TokenOperationFailed();
        }
        IWeth(VaultLib.QUOTE_TOKEN).withdraw(amount);

        // Step 2: Stake ETH with Lido to receive stETH
        uint256 shares = steth.submit{value: amount}(address(0));
        uint256 stethReceived = steth.getPooledEthByShares(shares);

        // Step 3: Wrap stETH to wstETH
        if (!IERC20(address(steth)).approve(address(VaultLib.COLLATERAL_TOKEN), stethReceived)) {
            revert VaultLib.TokenOperationFailed();
        }

        return wsteth.wrap(stethReceived);
    }

    /**
     * @notice Handles the flash loan callback from Balancer Vault
     * @dev This function is called by the Balancer Vault after a flash loan is initiated
     * @dev It performs the following steps:
     *      1. Validates the caller and loan authorization
     *      2. Mints collateral tokens for the pool
     *      3. Draws debt from the Ajna pool
     *      4. Converts borrowed WETH to wstETH to repay the flash loan
     * @param tokens The addresses of the tokens received in the flash loan
     * @param amounts The amounts of tokens received
     * @param feeAmounts The fee amounts charged by Balancer for the flash loan
     * @param userData Encoded data containing borrowing parameters
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (msg.sender != address(vault) || !_borrowInitiated) revert VaultLib.Unauthorized();
        _borrowInitiated = false;
        // Decode the user data to get borrowing parameters
        (uint256 baseLoanCollateral, uint256 amountToBorrow) = abi.decode(userData, (uint256, uint256));

        // Calculate total collateral (base + flash loan amount)
        uint256 totalCollateral = baseLoanCollateral + amounts[0];
        emit VaultLib.LoanComposition(baseLoanCollateral, amounts[0], totalCollateral, amountToBorrow);

        // Mint test collateral tokens and approve them for the pool
        if (
            !testCollateralToken.mint(address(this), totalCollateral)
                || !testCollateralToken.approve(address(pool), totalCollateral)
        ) {
            revert VaultLib.TokenOperationFailed();
        }

        // Record the borrowed amount for accounting purposes
        totalBorrowAmount = amountToBorrow;

        // Draw debt from the Ajna pool using the collateral
        pool.drawDebt(address(this), amountToBorrow, currentBucketIndex, totalCollateral);

        // Burn test quote tokens (accounting for the borrowed amount)
        if (!testQuoteToken.burn(address(this), amountToBorrow)) {
            revert VaultLib.TokenOperationFailed();
        }

        // Convert WETH to wstETH to repay the flash loan
        uint256 wstethReceived = wethToWsteth(amountToBorrow);

        // Repay the flash loan with fees
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 totalRepayment = amounts[i] + feeAmounts[i];
            if (!tokens[i].transfer(address(vault), totalRepayment)) {
                revert VaultLib.TokenOperationFailed();
            }
        }
    }



    /**
     * @notice Starts a new epoch, matching orders and managing funds.
     * @dev Validates epoch conditions, sets the redemption rate, and then calls `tryMatchOrders()` to match pending
     * lender and borrower orders. Any remaining unutilized lender funds are deposited into the flagship vault, and
     * the corresponding shares are distributed to the lenders.
     */
    function startEpoch() external lock {
        // Validate epoch parameters
        if (
            lastEpochEnd + epochCoolDownPeriod > block.timestamp || epochStarted
                || deploymentTimestamp + 72 hours > block.timestamp
        ) {
            revert VaultLib.Unauthorized();
        }

        // Get current wstETH/stETH ratio and set rates
        uint256 redemptionRate = wsteth.stEthPerToken();
        epochStartRedemptionRate = redemptionRate;
        currentRedemptionRate = redemptionRate;
        currentBucketIndex = poolInfoUtils.priceToIndex(redemptionRate);

        // Update state first
        epoch++;
        epochStarted = true;
        collateralLenderTraunche = 0;
        epochStart = block.timestamp;

        // Emit events before external calls
        emit VaultLib.EpochStarted(epoch, epochStart, epochStart + termDuration);
        emit VaultLib.RedemptionRateUpdated(redemptionRate);

        // Perform external calls
        tryMatchOrders();

        // Store amount to deposit in temporary variable
        uint256 amountToDeposit = totalLenderQTUnutilized;

        // Deposit remaining unutilized lender funds into flagship vault
        if (!IERC20(VaultLib.QUOTE_TOKEN).approve(address(flagshipVault), amountToDeposit)) {
            revert VaultLib.TokenOperationFailed();
        }
        uint256 depositedShares = flagshipVault.deposit(amountToDeposit, address(this));
        flagshipVaultShares += depositedShares;

        // Update lender shares after deposit using PRBMath
        for (uint256 i = 0; i < lenderOrders.length; i++) {
            UD60x18 lenderAmount = UD60x18.wrap(lenderOrders[i].quoteAmount);
            UD60x18 totalShares = UD60x18.wrap(flagshipVaultShares);
            UD60x18 totalDeposit = UD60x18.wrap(amountToDeposit);

            // Calculate shares using PRBMath: (lenderAmount * totalShares) / totalDeposit
            UD60x18 shares = lenderAmount.mul(totalShares).div(totalDeposit);
            lenderOrders[i].vaultShares = UD60x18.unwrap(shares);
            lenderOrders[i].quoteAmount = 0;
        }
        totalLenderQTUnutilized = 0;
    }

    // PROXY FUNCTIONS
    /**
     * @notice Pushes a lender order to the lenderOrders array.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param lenderOrder The lender order to push.
     */
    function lenderOrdersPush(VaultLib.LenderOrder memory lenderOrder) external onlyProxy {
        lenderOrders.push(lenderOrder);
    }

    /**
     * @notice Pushes a borrower order to the borrowerOrders array.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param borrowerOrder The borrower order to push.
     */
    function borrowerOrdersPush(VaultLib.BorrowerOrder memory borrowerOrder) external onlyProxy {
        borrowerOrders.push(borrowerOrder);
    }

    /**
     * @notice Pushes a collateral lender order to the collateralLenderOrders array.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param collateralLenderOrder The collateral lender order to push.
     */
    function collateralLenderOrdersPush(VaultLib.CollateralLenderOrder memory collateralLenderOrder)
        external
        onlyProxy
    {
        collateralLenderOrders.push(collateralLenderOrder);
    }

    /**
     * @notice Pushes a match info to the epochToMatches mapping.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param epoch The epoch number.
     * @param matchInfo The match info to push.
     */
    function epochToMatchesPush(uint256 epoch, VaultLib.MatchInfo memory matchInfo) external onlyProxy {
        epochToMatches[epoch].push(matchInfo);
    }

    /**
     * @notice Pushes a collateral lender order to the epochToCollateralLenderOrders mapping.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param epoch The epoch number.
     * @param collateralLenderOrder The collateral lender order to push.
     */
    function epochToCollateralLenderOrdersPush(
        uint256 epoch,
        VaultLib.CollateralLenderOrder memory collateralLenderOrder
    ) external onlyProxy {
        epochToCollateralLenderOrders[epoch].push(collateralLenderOrder);
    }

    /**
     * @notice Deletes the matches for a given epoch.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param epoch The epoch number.
     */
    function deleteEpochMatches(uint256 epoch) external onlyProxy {
        delete epochToMatches[epoch];
    }

    /**
     * @notice Deletes the collateral lender orders for a given epoch.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param epoch The epoch number.
     */
    function deleteEpochCollateralLenderOrders(uint256 epoch) external onlyProxy {
        delete epochToCollateralLenderOrders[epoch];
    }

    /**
     * @notice Approves a token for the proxy contract.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param token The address of the token to approve.
     * @param receiver The address of the receiver.
     * @param amount The amount to approve.
     */
    function approveForProxy(address token, address receiver, uint256 amount) external onlyProxy returns (bool) {
        return IERC20(token).approve(receiver, amount);
    }

    /**
     * @notice Transfers a token on behalf of the proxy contract.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param token The address of the token to transfer.
     * @param recipient The address of the recipient.
     * @param amount The amount to transfer.
     */
    function transferForProxy(address token, address recipient, uint256 amount) external onlyProxy returns (bool) {
        return IERC20(token).transfer(recipient, amount);
    }

    /**
     * @notice Requests withdrawals for WstETH from Lido protocol
     * @dev This function initiates the withdrawal process for wstETH tokens
     * @dev Only callable by the proxy contract (LVLidoVaultUtil or LiquidationProxy)
     * @dev Sets the global requestId to the first ID returned from the withdrawal request
     * @dev Marks funds as queued in the Lido withdrawal queue
     * @dev The withdrawal process in Lido is asynchronous - first request, then claim after finalization
     * @param amounts Array of wstETH amounts to withdraw from Lido protocol
     * @return requestId The ID of the first withdrawal request, used later for claiming
     */
    function requestWithdrawalsWstETH(uint256[] memory amounts) external onlyProxy returns (uint256) {
        uint256[] memory requestIds = VaultLib.LIDO_WITHDRAWAL.requestWithdrawalsWstETH(amounts, address(this));
        requestId = requestIds[0];
        fundsQueued = true;
        return requestId;
    }

    /**
     * @notice Claims a withdrawal from Lido protocol
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @dev Uses the global requestId that was set during the requestWithdrawalsWstETH call
     * @dev This function should only be called after the Lido withdrawal request has been finalized
     * @dev After successful claim, the ETH will be sent to this contract's address
     */
    function claimWithdrawal() external onlyProxy {
        // Call Lido withdrawal contract to claim the finalized withdrawal using stored requestId
        VaultLib.LIDO_WITHDRAWAL.claimWithdrawal(requestId);
        // Note: After claiming, the contract will receive ETH which should be converted to WETH if needed
    }

    /**
     * @notice Deposits ETH for WETH.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param amount The amount of ETH to deposit.
     */
    function depositEthForWeth(uint256 amount) external onlyProxy {
        IWeth(VaultLib.QUOTE_TOKEN).deposit{value: amount}();
    }

    /**
     * @notice Ends the current epoch.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @dev This function resets epoch state variables and prepares the vault for the next epoch.
     */
    function end_epoch() external onlyProxy {
        epochStarted = false;
        fundsQueued = false; // Reset withdrawal queue status
        lastEpochEnd = block.timestamp;

        emit VaultLib.EndEpoch(lastEpochEnd);
    }

    /**
     * @notice Clears Ajna deposits.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param amount The amount of quote token to remove.
     */
    function clearAjnaDeposits(uint256 amount) external onlyProxy lock {
        (uint256 removedAmount_,) = pool.removeQuoteToken(amount, currentBucketIndex);
        if (!testQuoteToken.burn(address(this), removedAmount_)) {
            revert VaultLib.TokenOperationFailed();
        }
    }

    /**
     * @notice Sets the total manual repay amount.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param amount The total manual repay amount.
     */
    function setTotalManualRepay(uint256 amount) external onlyProxy {
        totalManualRepay = amount;
    }

    /**
     * @notice Adds collateral to avoid liquidation.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @dev Uses unutilized collateral lender deposits to increase position health.
     * @param amount The amount of collateral to add.
     */
    function avoidLiquidation(uint256 amount) external onlyProxy lock {
        // Check if we have enough unutilized collateral from lenders
        if (totalCLDepositsUnutilized < amount) revert VaultLib.InsufficientFunds();

        // Update state first
        totalCLDepositsUnutilized -= amount;
        totalCLDepositsUtilized += amount;

        // Emit event before external calls
        emit VaultLib.AvoidLiquidation(amount);

        // Perform external calls last
        if (!testCollateralToken.mint(address(this), amount) || !testCollateralToken.approve(address(pool), amount)) {
            revert VaultLib.TokenOperationFailed();
        }

        pool.drawDebt(address(this), 0, 7388, amount);
    }

    /**
     * @notice Sets the LVLidoVaultUtil address.
     * @dev Can only be called by the owner.
     * @param _LVLidoVaultUtil The new LVLidoVaultUtil address.
     */
    function setLVLidoVaultUtilAddress(address _LVLidoVaultUtil) public onlyOwner {
        emit VaultLib.LVLidoVaultUtilAddressUpdated(LVLidoVaultUtil, _LVLidoVaultUtil);
        LVLidoVaultUtil = _LVLidoVaultUtil;
    }

    // Note Anyone can call this function, ensure there are overflow protections in place.
    // Define range of values that can be entered in.
    /**
     * @notice Repays Ajna debt.
     * @param quoteTokenAmount The amount of quote token to repay.
     * @dev This function allows anyone to repay debt on behalf of the vault
     */
    function repayAjnaDebt(uint256 quoteTokenAmount) external lock {
        // Prevent zero-value transactions to save gas
        if (quoteTokenAmount == 0) {
            revert VaultLib.InvalidInput();
        }

        // Update state first
        totalManualRepay += quoteTokenAmount;

        // Perform external calls last
        if (
            !IERC20(VaultLib.QUOTE_TOKEN).transferFrom(msg.sender, address(this), quoteTokenAmount)
                || !testQuoteToken.mint(address(this), quoteTokenAmount)
                || !IERC20(address(testQuoteToken)).approve(address(pool), quoteTokenAmount)
        ) {
            revert VaultLib.TokenOperationFailed();
        }
        pool.repayDebt(address(this), quoteTokenAmount, 0, address(this), 7388);
    }

    /**
     * @notice Gets the matches for a given epoch.
     * @param _epoch The epoch number.
     * @return An array of MatchInfo structs.
     */
    function getEpochMatches(uint256 _epoch) external view returns (VaultLib.MatchInfo[] memory) {
        return epochToMatches[_epoch];
    }

    /**
     * @notice Gets the collateral lender orders for a given epoch.
     * @param _epoch The epoch number.
     * @return An array of CollateralLenderOrder structs.
     */
    function getEpochCollateralLenderOrders(uint256 _epoch)
        external
        view
        returns (VaultLib.CollateralLenderOrder[] memory)
    {
        return epochToCollateralLenderOrders[_epoch];
    }

    /**
     * @notice Sets the total CL deposits unutilized.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalCLDepositsUnutilized The new total CL deposits unutilized.
     */
    function setTotalCLDepositsUnutilized(uint256 _totalCLDepositsUnutilized) external onlyProxy {
        totalCLDepositsUnutilized = _totalCLDepositsUnutilized;
    }

    /**
     * @notice Sets the total CL deposits utilized.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalCLDepositsUtilized The new total CL deposits utilized.
     */
    function setTotalCLDepositsUtilized(uint256 _totalCLDepositsUtilized) external onlyProxy {
        totalCLDepositsUtilized = _totalCLDepositsUtilized;
    }

    /**
     * @notice Sets the collateral lender traunche.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _collateralLenderTraunche The new collateral lender traunche.
     */
    function setCollateralLenderTraunche(uint256 _collateralLenderTraunche) external onlyProxy {
        collateralLenderTraunche = _collateralLenderTraunche;
    }

    /**
     * @notice Sets the current redemption rate.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _currentRedemptionRate The new current redemption rate.
     */
    function setCurrentRedemptionRate(uint256 _currentRedemptionRate) external onlyProxy {
        currentRedemptionRate = _currentRedemptionRate;
    }

    /**
     * @notice Mints tokens for the proxy contract.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param token The address of the token to mint.
     * @param receiver The address of the receiver.
     * @param amount The amount to mint.
     */
    function mintForProxy(address token, address receiver, uint256 amount) external onlyProxy returns (bool) {
        if (token == address(testQuoteToken)) {
            return testQuoteToken.mint(receiver, amount);
        } else if (token == address(testCollateralToken)) {
            return testCollateralToken.mint(receiver, amount);
        }
    }

    /**
     * @notice Burns tokens for the proxy contract.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param token The address of the token to burn.
     * @param receiver The address of the receiver.
     * @param amount The amount to burn.
     */
    function burnForProxy(address token, address receiver, uint256 amount) external onlyProxy returns (bool) {
        if (token == address(testQuoteToken)) {
            return testQuoteToken.burn(receiver, amount);
        } else if (token == address(testCollateralToken)) {
            return testCollateralToken.burn(receiver, amount);
        }
    }

    /**
     * @notice Repays debt for the proxy contract.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param debt The amount of debt to repay.
     * @param collateral The amount of collateral to repay.
     */
    function repayDebtForProxy(uint256 debt, uint256 collateral) external onlyProxy {
        pool.repayDebt(address(this), debt, collateral, address(this), 7388);
    }

    /**
     * @notice Sets the total lender QT unutilized.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalLenderQTUnutilized The new total lender QT unutilized.
     */
    function setTotalLenderQTUnutilized(uint256 _totalLenderQTUnutilized) external onlyProxy {
        totalLenderQTUnutilized = _totalLenderQTUnutilized;
    }

    /**
     * @notice Sets the total lender QT utilized.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalLenderQTUtilized The new total lender QT utilized.
     */
    function setTotalLenderQTUtilized(uint256 _totalLenderQTUtilized) external onlyProxy {
        totalLenderQTUtilized = _totalLenderQTUtilized;
    }

    /**
     * @notice Sets the total borrower CT.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalBorrowerCT The new total borrower CT.
     */
    function setTotalBorrowerCT(uint256 _totalBorrowerCT) external onlyProxy {
        totalBorrowerCT = _totalBorrowerCT;
    }

    /**
     * @notice Sets the total borrower CT unutilized.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalBorrowerCTUnutilized The new total borrower CT unutilized.
     */
    function setTotalBorrowerCTUnutilized(uint256 _totalBorrowerCTUnutilized) external onlyProxy {
        totalBorrowerCTUnutilized = _totalBorrowerCTUnutilized;
    }

    /**
     * @notice Sets the total collateral lender CT.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _totalCollateralLenderCT The new total collateral lender CT.
     */
    function setTotalCollateralLenderCT(uint256 _totalCollateralLenderCT) external onlyProxy {
        totalCollateralLenderCT = _totalCollateralLenderCT;
    }

    // ORDER CREATION AND WITHDRAWAL FUNCTIONS
    /**
     * @notice Creates a lender order.
     * @param amount The amount of quote token (WETH) to lend.
     * @return The amount of quote token lent.
     * @dev This function allows users to deposit quote tokens (WETH) into the vault
     * @dev The deposited tokens are tracked as unutilized until they are matched with borrower orders
     * @dev or deposited into the flagship vault during epoch start
     */
    function createLenderOrder(uint256 amount) external lock returns (uint256) {
        // Prevent zero-value transactions to save gas
        if (amount == 0) revert VaultLib.InvalidInput();
        if (!maxFundsLimiter(amount, 0)) revert VaultLib.MaxFundsExceeded();
        lenderOrders.push(VaultLib.LenderOrder({lender: msg.sender, quoteAmount: amount, vaultShares: 0}));
        totalLenderQTUnutilized += amount;

        emit VaultLib.LenderOrderAdded(msg.sender, amount);

        if (!IERC20(VaultLib.QUOTE_TOKEN).transferFrom(address(msg.sender), address(this), amount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return amount;
    }

    /**
     * @notice Creates a new borrower order with the specified collateral amount
     * @dev Transfers collateral from the user to the vault and adds a new borrower order
     * @param collateralAmount The amount of collateral to deposit for the order
     * @return The amount of collateral deposited
     */
    function createBorrowerOrder(uint256 collateralAmount) external lock returns (uint256) {
        if (collateralAmount == 0) {
            revert VaultLib.InvalidInput();
        }
        if (!maxFundsLimiter(0, collateralAmount)) revert VaultLib.MaxFundsExceeded();

        totalBorrowerCT += collateralAmount;
        totalBorrowerCTUnutilized += collateralAmount;
        borrowerOrders.push(VaultLib.BorrowerOrder({borrower: msg.sender, collateralAmount: collateralAmount}));

        // Emit event before external call
        emit VaultLib.BorrowerOrderAdded(msg.sender, collateralAmount);

        // Perform external call last
        if (!IERC20(VaultLib.COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), collateralAmount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return collateralAmount;
    }

    /**
     * @notice Lends collateral as a collateral lender.
     * @param amount The amount of collateral to lend.
     * @return The amount of collateral lent.
     * @dev This function allows users to deposit collateral tokens (wstETH) to be used as additional
     * @dev collateral for borrowers, helping to maintain healthy collateralization ratios and
     * @dev potentially preventing liquidations. Collateral lenders earn fees from this service.
     */
    function createCLOrder(uint256 amount) external lock returns (uint256) {
        // Prevent zero-value transactions to save gas
        if (amount == 0) {
            revert VaultLib.InvalidInput();
        }
        if (!maxFundsLimiter(0, amount)) revert VaultLib.MaxFundsExceeded();

        totalCollateralLenderCT += amount;
        collateralLenderOrders.push(VaultLib.CollateralLenderOrder(msg.sender, amount));

        emit VaultLib.CollateralLenderDeposit(msg.sender, amount);

        if (!IERC20(VaultLib.COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), amount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return amount;
    }

    /**
     * @notice Withdraws a lender order.
     * @dev This function allows lenders to withdraw their unutilized funds from the vault.
     * @dev Handles both direct quote token deposits and flagship vault shares.
     * @dev Uses a swap-and-pop pattern to efficiently remove orders from the array.
     * @return The total amount of quote tokens withdrawn.
     */
    function withdrawLenderOrder() external lock returns (uint256) {
        uint256 userWithdrawalAmount = 0;
        uint256 userVaultShares = 0;

        // Find and collect all orders from this lender
        for (uint256 i = 0; i < lenderOrders.length;) {
            if (lenderOrders[i].lender == msg.sender) {
                // Track either vault shares or direct quote token amounts
                if (lenderOrders[i].vaultShares > 0) {
                    userVaultShares += lenderOrders[i].vaultShares;
                } else {
                    userWithdrawalAmount += lenderOrders[i].quoteAmount;
                }

                // Swap with last element and pop (more gas efficient than shifting elements)
                if (i < lenderOrders.length - 1) {
                    lenderOrders[i] = lenderOrders[lenderOrders.length - 1];
                }
                lenderOrders.pop();
            } else {
                i++;
            }
        }

        if (userWithdrawalAmount == 0 && userVaultShares == 0) {
            revert VaultLib.NoUnfilledOrdersFound();
        }

        // Update all state variables first
        totalLenderQTUnutilized -= userWithdrawalAmount;

        // Handle flagship vault shares if present
        if (userVaultShares > 0) {
            flagshipVaultShares -= userVaultShares;
        }

        // Emit event before any external calls
        emit VaultLib.WithdrawLender(msg.sender, userWithdrawalAmount);

        // Perform external calls last
        if (userVaultShares > 0) {
            userWithdrawalAmount += flagshipVault.redeem(userVaultShares, address(this), address(this));
        }

        if (!IERC20(VaultLib.QUOTE_TOKEN).transfer(msg.sender, userWithdrawalAmount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return userWithdrawalAmount;
    }

    /**
     * @notice Withdraws a borrower order.
     * @dev This function allows borrowers to withdraw their unutilized collateral from pending orders
     * @dev Uses a gas-efficient removal pattern (swap with last element and pop)
     * @dev Updates global accounting for borrower collateral tracking
     * @return The total amount of collateral tokens withdrawn.
     */
    function withdrawBorrowerOrder() external lock returns (uint256) {
        uint256 userWithdrawalAmount = 0;
        for (uint256 i = 0; i < borrowerOrders.length;) {
            if (borrowerOrders[i].borrower == msg.sender) {
                userWithdrawalAmount += borrowerOrders[i].collateralAmount;
                if (i < borrowerOrders.length - 1) {
                    borrowerOrders[i] = borrowerOrders[borrowerOrders.length - 1];
                }
                borrowerOrders.pop();
            } else {
                i++;
            }
        }

        if (userWithdrawalAmount == 0) {
            revert VaultLib.NoUnfilledOrdersFound();
        }

        totalBorrowerCT -= userWithdrawalAmount;
        totalBorrowerCTUnutilized -= userWithdrawalAmount;
        emit VaultLib.WithdrawBorrower(msg.sender, userWithdrawalAmount);
        if (!IERC20(VaultLib.COLLATERAL_TOKEN).transfer(msg.sender, userWithdrawalAmount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return userWithdrawalAmount;
    }

    /**
     * @notice Withdraws a collateral lender order.
     * @dev Allows collateral lenders to withdraw their unutilized collateral tokens (wstETH)
     * @dev Finds and aggregates all orders from the caller, then removes them from the array
     * @dev Updates global accounting and transfers tokens back to the lender
     * @dev Protected by the lock modifier to prevent reentrancy attacks
     * @return The total amount of collateral withdrawn
     */
    function withdrawCLOrder() external lock returns (uint256) {
        uint256 userWithdrawalAmount = 0;
        for (uint256 i = 0; i < collateralLenderOrders.length;) {
            if (collateralLenderOrders[i].collateralLender == msg.sender) {
                userWithdrawalAmount += collateralLenderOrders[i].collateralAmount;
                if (i < collateralLenderOrders.length - 1) {
                    collateralLenderOrders[i] = collateralLenderOrders[collateralLenderOrders.length - 1];
                }
                collateralLenderOrders.pop();
            } else {
                i++;
            }
        }
        if (userWithdrawalAmount == 0) {
            revert VaultLib.NoUnfilledOrdersFound();
        }

        totalCollateralLenderCT -= userWithdrawalAmount;
        emit VaultLib.WithdrawCollateralLender(msg.sender, userWithdrawalAmount);
        if (!IERC20(VaultLib.COLLATERAL_TOKEN).transfer(msg.sender, userWithdrawalAmount)) {
            revert VaultLib.TokenOperationFailed();
        }

        return userWithdrawalAmount;
    }

    // AUCTION BASED FUNCTIONS
    /**
     * @notice Sets whether kicking is allowed.
     * @dev Can only be called by the LVLidoVaultUtil or LiquidationProxy contract.
     * @param _allowKick Whether kicking is allowed.
     */
    function setAllowKick(bool _allowKick) external onlyProxy {
        liquidationProxy.setAllowKick(_allowKick);
    }

    function getAllowKick() external view returns (bool) {
        return liquidationProxy.allowKick();
    }

    function lenderKick(uint256 bondAmount) external onlyProxy {
        if (
            !(
                liquidationProxy.allowKick() == true && testQuoteToken.mint(address(this), bondAmount)
                    && IERC20(address(testQuoteToken)).approve(address(pool), bondAmount)
            )
        ) {
            revert VaultLib.TokenOperationFailed();
        }

        pool.lenderKick(currentBucketIndex, 7388);
    }

    function withdrawBondsForProxy() external onlyProxy returns (uint256) {
        (uint256 claimable, uint256 locked) = pool.kickerInfo(address(this));
        if (locked != 0) {
            revert VaultLib.LockedBonds();
        }
        return pool.withdrawBonds(address(this), claimable);
    }
}
