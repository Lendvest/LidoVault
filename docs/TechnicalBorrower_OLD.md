# Lendvest Leveraged Fixed-Term WSTETH Loans: Borrower Guide

This document provides an overview of how you, as a borrower, can utilize Lendvest's leveraged fixed-term loan product. This product allows you to gain amplified exposure to WSTETH staking rewards by using your WSTETH as collateral to borrow WETH.

## Borrower Journey Overview

The process is designed to be straightforward from your perspective, leveraging sophisticated backend systems including Chainlink Functions and Automation to manage the complexities of rate optimization, loan management, and collateral handling.

### 1. Initiating Your Loan Request

- **Submit Order:** You begin by depositing your WSTETH collateral into the Lendvest vault and specifying your desire to borrow WETH. This creates your borrow order.

### 2. Order Matching and Loan Origination

- **Matching Engine:** Lendvest's matching engine works to fill your borrow order. It pairs your request with available WETH deposits from lenders and ensures sufficient backing from collateral lenders (who contribute additional collateral to secure the overall loan pool).
- **Leverage via Flash Loan:** Once matched, the system utilizes a flash loan mechanism. It borrows WETH against your deposited WSTETH and the contributions from collateral lenders. This borrowed WETH is immediately converted into more WSTETH and staked via Lido on your behalf, effectively leveraging your initial position to maximize potential staking reward exposure.

### 3. The Loan Epoch (Fixed Term)

- **Fixed Term:** Your leveraged loan operates over a fixed term (epoch), typically set for a duration like two weeks. This term also accounts for the time required for the Lido withdrawal process later on.
- **Automated Management:** During the epoch, Lendvest systems, powered by Chainlink Automation, work in the background:
  - **Collateral Monitoring:** The system monitors the value of the underlying WSTETH collateral relative to the borrowed WETH. Chainlink Automation helps manage collateral levels dynamically to mitigate liquidation risks for the _collateral lenders_ supporting the pool.
  - **Rate Fetching:** Towards the end of your term, Chainlink Functions are used to query external data sources (like Space and Time) to determine the optimal, fair interest rate applicable to your loan based on prevailing market conditions.

### 4. Loan Repayment and Settlement

- **Automated Lido Withdrawal:** As your fixed term concludes, Chainlink Automation initiates the withdrawal process for the necessary amount of WSTETH from Lido to cover the loan repayment. This involves queuing the withdrawal request and subsequently claiming the ETH once it becomes available (respecting Lido's standard withdrawal timeline).
- **Debt Repayment:** The claimed ETH is converted back to WETH and used to automatically repay the underlying WETH debt on the Ajna protocol.
- **Interest Calculation:** The system calculates the final interest owed based on the optimal rate fetched earlier and the loan duration.

### 5. Withdrawing Your Funds

- **End of Epoch:** Once the debt is repaid and all accounting is finalized (interest distributed etc.), your initial WSTETH collateral, adjusted for the profit or loss from the leveraged staking position (after accounting for interest and fees), becomes available for you to withdraw from the Lendvest vault.
- **Partial Fills:** If your initial borrow order was only partially matched (meaning not all the WETH you sought to borrow was available), the portion of your WSTETH collateral corresponding to the _unmatched_ part of your order remains available for withdrawal at any time, even during the active loan epoch. You don't have to wait for the term to end to access these specific unused funds.

## Summary

Lendvest offers a streamlined way to access leveraged WSTETH staking. By depositing WSTETH, you can borrow WETH, increase your staking exposure, and potentially earn amplified rewards. The platform automates the complex backend processes involving matching, flash loans, rate optimization, collateral management, and repayment, allowing you to focus on managing your leveraged position.
