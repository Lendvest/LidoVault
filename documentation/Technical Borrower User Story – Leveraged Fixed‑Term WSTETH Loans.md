# **Technical Borrower User Story:** **Lendvest Leveraged “Looping” Fixed-Term WSTETH Loans**

### ---

## **Contracts Involved**

* ### **`LVLidoVault.sol`**

* ### **`LVLidoVaultUtil.sol`**

* ### **`LiquidationProxy.sol`**

* ### **`LVToken.sol`**

* ### **`IERC20Pool` (Ajna Pool Interface)**

* ### **`IVault` (Balancer Vault Interface)**

### **Token Interfaces**

* ### **`IWsteth`**

* ### **`ISteth`**

* ### **`IWeth`**

### **Other Interfaces**

* ### **`ILiquidationProxy`**

* ### **`ILVLidoVault`**

* ### **`ILVToken`**

* ### **`IPoolInfoUtils`**

### **Chainlink Interfaces**

* ### **`FunctionsClient`**

* ### **`AutomationCompatibleInterface`**

* ### **`VaultLib.sol`** 

### ---

## **Technical Flow**

### **1\. Initiating Loan Request (Submit Order)**

* **Action:** Borrower deposits WSTETH and signals intent to borrow WETH.

* **Mechanism:**

  * Borrower approves `LVLidoVault` to spend their WSTETH (`VaultLib.COLLATERAL_TOKEN`).

  * Borrower calls `LVLidoVault.createBorrowerOrder(collateralAmount)`.

  * `createBorrowerOrder` executes `IERC20(VaultLib.COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), collateralAmount)` to pull the WSTETH into the vault.

  * It updates the vault’s internal state:

    * Adds a `VaultLib.BorrowerOrder` struct to the `borrowerOrders` array.

    * Increments `totalBorrowerCT` (total borrower collateral held).

    * Increments `totalBorrowerCTUnutilized` (collateral not yet matched/leveraged).

  * Emits `VaultLib.BorrowerOrderAdded` event.

---

### **2\. Order Matching and Loan Origination**

* **Action:** Lendvest system matches the borrower’s request with lenders and collateral lenders, then executes the leveraged loan.

* **Mechanism:**

#### **Matching**

* Check that an epoch isn’t already running and sufficient time has passed.

* Store current redemption rate for epoch start, bucket index calculation, and to be used as an updateable reference for dynamic collateral lending traunches.

* Triggered by `LVLidoVault.startEpoch()`, which calls the internal `tryMatchOrders(redemptionRate)`.

* `tryMatchOrders` iterates through `lenderOrders` and `borrowerOrders`.

* For each potential match (lender and borrowers with micro-amount deposits will be skipped if they yield zero values), it calculates:

  * Flash-loan amount needed based on `leverageFactor`.

  * Amount to borrow in WETH (`amountToBorrow`) considering the `redemptionRate`.

  * Ajna borrow fee (`originationFactor`) and deposit fee (`depositFeeRate`).

  * Initial debt (`t0Debt`).

  * Maximum debt supportable by the lender’s quote amount (`maxT0Debt`) considering `initialUtilization` and `depositFeeRate`.

  * If `t0Debt > maxT0Debt`, the order amounts are scaled down (`scaledT0Debt`, `scaledAmountToBorrow`, `scaledBorrowerCollateralAmount`) and `preFeeAmountToDeposit` is set to `lenderOrders[i].quoteAmount`.

  * Otherwise they remain unscaled and `preFeeAmountToDeposit` is set to `(scaledT0Debt) / (initialUtilization x (1 - depositFeeRate))`.

  * Compute unused reserved slice via `scaledReservedQuoteAmount = (1−initialUtilization) × (scaledT0Debt / initialUtilization)`.

  * It creates `VaultLib.MatchInfo` structs and pushes them to the `epochToMatches[epoch]` mapping:

    * **lender** – address of the lender in the match.

    * **borrower** – address of the borrower in the match.

    * **quoteAmount** – amount of the lender’s quote token (WETH) allocated to this match (e.g., `scaledT0Debt`).

    * **collateralAmount** – amount of the borrower’s collateral token (WSTETH) allocated to this match (e.g., `scaledBorrowerCollateralAmount`).

    * **reservedQuoteAmount** – slice of quote tokens reserved for future use (`scaledReservedQuoteAmount`).

  * Totals are incremented (`totalPreFeeAmountToDeposit`, `borrowerCTMatched`, `borrowAmountMatched`); utilized amounts are decremented from order arrays and zero-balance entries popped.

* It determines required collateral-lender backing (`borrowAmountMatched / (epochStartRedemptionRate * 2)`) and ensures `totalCollateralLenderCT` is sufficient, matching against `collateralLenderOrders` and pushing to `epochToCollateralLenderOrders[epoch]`.

* Updates totals:

  * `totalCollateralLenderCT -= ((borrowAmountMatched * 1e18) / epochStartRedemptionRate) / 2`

  * `totalCLDepositsUtilized += clInitialUtilized`

  * `totalCLDepositsUnutilized += (((borrowAmountMatched * 1e18) / epochStartRedemptionRate) / 2) - clInitialUtilized`

* Deposits matched lender funds (WETH) into the Ajna pool after wrapping:

  * `IERC20(VaultLib.QUOTE_TOKEN).approve(address(wrappedQuoteToken), totalPreFeeAmountToDeposit)`

  * `testQuoteToken.mint(address(this), amount)`

  * `IERC20(pool.quoteTokenAddress()).approve(address(pool), totalPreFeeAmountToDeposit)`

  * `pool.addQuoteToken(totalPreFeeAmountToDeposit, currentBucketIndex, …)`

* Updates:

  * `totalLenderQTUtilized += totalPostFeeDepositAmount`

  * `totalLenderQTUnutilized -= totalPreFeeAmountToDeposit`

#### **Leverage via Flash Loan**

* Calculate total WSTETH needed from the flash loan: `amounts[0] = (borrowerCTMatched * (leverageFactor - 10)) / 10`.

* Determine `minTotalLoanCollateral` and portion from collateral lenders (`clInitialUtilized`, currently 0).

* Set `_borrowInitiated = true`.

* Call `vault.flashLoan(this, tokens, amounts, abi.encode(borrowerCTMatched, clInitialUtilized, borrowAmountMatched))`. `tokens[0]` is WSTETH (`VaultLib.COLLATERAL_TOKEN`).

* Balancer Vault calls back `LVLidoVault.receiveFlashLoan(…)`.

`receiveFlashLoan`:

* Confirms `msg.sender == address(vault)` and `_borrowInitiated == true`.

* Decodes `userData` → `baseLoanCollateral`, `clInitialUtilized`, `amountToBorrow`.

* Calculates `totalCollateral` (borrower initial \+ flash loan \+ collateral lender).

* Mints `testCollateralToken` (`LVToken`) for `totalCollateral`.

* Approves Ajna pool to spend it, then draws WETH debt:  
   `pool.drawDebt(address(this), amountToBorrow, currentBucketIndex, totalCollateral)`.

* Burns wrapped quote token: `testQuoteToken.burn(address(this), amountToBorrow)`.

* Converts borrowed WETH → WSTETH with `wethToWsteth(amountToBorrow)`.

* Repays flash loan (WSTETH) \+ zero fee: `tokens[i].transfer(address(vault), totalRepayment)`.

* Sets `_borrowInitiated = false`, decrements `totalBorrowerCTUnutilized` by `borrowerCTMatched`.

---

### **3\. The Loan Epoch (Fixed Term)**

* **Action:** Loan runs for a fixed duration, managed automatically.

* **Mechanism:**

#### **Fixed Term**

* Defined by `epochStart` and `termEnd` set in `LVLidoVault.startEpoch()`. `termDuration` is configurable.

#### **Automated Management – Collateral Monitoring (via `LVLidoVaultUtil`)**

* `checkUpkeep` tracks WSTETH price via `IWsteth(address(VaultLib.COLLATERAL_TOKEN)).stEthPerToken()`.

* Computes `percentageDifferenceRedemptionRate` vs. `LVLidoVault.currentRedemptionRate()`.

* If thresholds (based on `priceDifferencethreshold`, `FACTOR_COLLATERAL_INCREASE`, `collateralLenderTraunche`) are crossed **and** `totalCLDepositsUnutilized > 0`:

  * Calculates `collateralToAddToPreventLiquidation`.

  * Returns `upkeepNeeded = true` with Task ID 0\.

  * `performUpkeep` Task ID 0 → `LVLidoVault.avoidLiquidation(collateralToAddToPreventLiquidation)`, adds collateral, updates state.

* If `MAX_TRANCHES` reached: Task ID 3 → `LVLidoVault.setAllowKick(true)` enabling `LiquidationProxy`.

#### **Automated Management – Rate Fetching (via `LVLidoVaultUtil` & `LVLidoVault`)**

* If `LVLidoVault.updateRateNeeded()` is true and `termEnd` is near → Task ID 221 → `LVLidoVault.getRate()`.

* Off-chain Chainlink Functions compute rates; `fulfillRequest` sets new `LVLidoVault.rate` and clears `updateRateNeeded`.

---

### **4\. Loan Repayment and Settlement**

* **Action:** Automated Lido withdrawal, Ajna debt repayment, and interest distribution.

* **Mechanism (via `LVLidoVaultUtil`):**

#### **Automated Lido Withdrawal Initiation**

* `checkUpkeep` verifies term ended & funds not queued.

* If `currentDebt == 0` → Task ID 2 (direct withdraw). Else → Task ID 1 (queue withdraw after repayment).

Task ID 1 (`performUpkeep`):

* Calculates `approxPercentFinalInterest`.

* Updates `currentRedemptionRate`, emits `RedemptionRateUpdated`.

* Computes `approxCTForClaim`, approves `VaultLib.LIDO_WITHDRAWAL`, calls `requestWithdrawalsWstETH`, emits `FundsQueued`, sets `fundsQueued = true`.

#### **Claiming Funds & Debt Repayment**

* When `fundsQueued` **and** claimable ETH exists → Task ID 2\.

* `performUpkeep` Task ID 2:

  * Claims ETH (`LVLidoVault.claimWithdrawal()`), emits `FundsClaimed`, converts ETH → WETH.

  * If none claimable **and** `t1Debt` ≠ 0 → revert `VaultLib.NoETHToClaim`.

* Compute `actualDebt`; if `claimAmount < actualDebt` → revert.

* Extra WETH → WSTETH for redistribution.

* Mint test quote token, approve Ajna pool, `repayDebtForProxy`.

* Emit `AmountsOwed`; burn leftovers; clear Ajna deposits.

* Re-build orders, emit `EpochInterestEarned`, reset CL trackers, end epoch.

#### **Interest Calculation & Distribution (continuation of Task ID 2\)**

* Calculates `trueInterestPercent`, updates `actualDebt`.

* Remaining WETH → WSTETH (`claimAmountWstethRemaining`).

* Repays outstanding debt; computes amounts owed:

  * **Lenders:** `matchedLendersOwed = totalLenderQTUtilized – totalBorrowAmount + actualDebt`.

  * **Collateral lenders:** plus 0.5 % APY on utilized \+ unutilized.

  * **Borrowers:** receive remaining WSTETH (`matchedBorrowersOwed`).

* Emits `AmountsOwed`; burns remaining tokens; clears Ajna deposits.

* Redistributes scaled amounts back into order books, updates globals, deletes epoch data, resets CL stats, emits `EpochInterestEarned`, `end_epoch()`, disables kicking.

---

### **5\. Withdrawing Your Funds**

* **Action:** Borrower retrieves final WSTETH balance.

* **Mechanism:**

  * **End-of-Epoch Settlement:** `performUpkeep` (Step 4\) calculates borrower’s final WSTETH (initial collateral ± P/L) and adds a `VaultLib.BorrowerOrder` via `LVLidoVault.borrowerOrdersPush`.

  * **Final Withdrawal:**

    * Borrower calls `LVLidoVault.withdrawBorrowerOrder()`.

    * Iterates `borrowerOrders` for `borrower == msg.sender`; sums `collateralAmount` → `userWithdrawalAmount`.

    * Removes order (swap-and-pop), decrements `totalBorrowerCT` & `totalBorrowerCTUnutilized`.

    * Transfers WSTETH back: `IERC20(VaultLib.COLLATERAL_TOKEN).transfer(msg.sender, userWithdrawalAmount)`.

    * Emits `VaultLib.WithdrawBorrower(msg.sender, userWithdrawalAmount)`.

  * **Partial Fills:** Unmatched collateral remains in `borrowerOrders`; borrower may call `withdrawBorrowerOrder()` anytime to retrieve it.

---

### **6\. Miscellaneous**

* `receiveFlashLoan` increments `totalOriginationFees`, but this variable is never used outside of that.

