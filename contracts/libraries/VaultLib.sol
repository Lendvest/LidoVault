// SPDX-License-Identifier: BUSL-1.1
// Author: Lendvest

pragma solidity ^0.8.20;

import {ILidoWithdrawal} from "../interfaces/vault/ILidoWithdrawal.sol";

/**
 * @title VaultLib
 */
library VaultLib {
    struct LenderOrder {
        address lender;
        uint256 quoteAmount;
        uint256 vaultShares;
    }

    struct BorrowerOrder {
        address borrower;
        uint256 collateralAmount;
    }

    struct CollateralLenderOrder {
        address collateralLender;
        uint256 collateralAmount;
    }


  
    uint256 public constant leverageFactor = 150;

    /* EVENTS */
    event EndEpoch(uint256 time);
    event TermEnded(uint256 time);
    event FundsQueued(uint256 requestId, uint256 collateralAmount);
    event FundsClaimed(uint256 requestId, uint256 amount);
    event FundsAdded(uint256 ethAmount, uint256 contractBalance, address sender);
    event ForwarderAddressUpdated(address oldAddress, address newAddress);
    event AvoidLiquidation(uint256 collateralAmount);
    event EpochStarted(uint256 epoch, uint256 epochStart, uint256 termEnd);
    event RedemptionRateUpdated(uint256 redemptionRate);
    event OCRResponse(bytes32 indexed requestId, bytes response, uint256 rate, bytes err);
    event RequestRevertedWithErrorMsg(string reason);
    event RequestRevertedWithoutErrorMsg(bytes data);
    event LVLidoVaultUtilAddressUpdated(address oldAddress, address newAddress);
    event LoanComposition(
        uint256 baseCollateral, uint256 leveragedCollateral, uint256 totalCollateral, uint256 quoteToBorrow
    );
    event AmountsOwed(uint256 lendersOwed, uint256 borrowersOwed, uint256 collateralLendersOwed);
    // ------------------------------------------------------------
    // Confirmed to be used
    event LenderOrderAdded(address lender, uint256 quoteAmount);
    event BorrowerOrderAdded(address borrower, uint256 collateralAmount);
    event CollateralLenderDeposit(address collateralLender, uint256 collateralAmount);
    event WithdrawLender(address lender, uint256 quoteAmount);
    event WithdrawBorrower(address borrower, uint256 collateralAmount);
    event WithdrawCollateralLender(address collateralLender, uint256 collateralAmount);
    event EpochInterestEarned(
        uint256 epochNumber,
        uint256 lendersInterestAccrued,
        uint256 borrowersInterestAccrued,
        uint256 collateralLendersInterestAccrued
    );

    /* Errors */
    error InsufficientFunds();
    error Unauthorized();
    error OnlyForwarder();
    error OnlyProxy();
    error ReentrantCall();
    error InvalidInput();
    error NoETHToClaim();
    error NoUnfilledOrdersFound();
    error MaxFundsExceeded();
    error TokenOperationFailed();
    error LockedBonds();

    // ------------------------------------------------------------
}
