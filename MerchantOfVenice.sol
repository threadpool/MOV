// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  MerchantOfVenice
/// @notice A fully on-chain secured lending escrow.
///
///         Shylock (lender) sets the terms at deployment.
///         Antonio (borrower) deposits collateral equal to twice the loan amount.
///         Shylock then disburses the loan directly to Antonio.
///         Antonio repays before the repayment deadline to recover his collateral.
///         If Antonio defaults, Shylock claims the full collateral as compensation.
///
///         Three time windows govern the lifecycle:
///           1. depositWindow       — Antonio must deposit collateral within this
///                                    period after deployment.
///           2. disbursementWindow  — Shylock must disburse within this period
///                                    after Antonio deposits.
///           3. repaymentWindow     — Antonio must repay within this period
///                                    after Shylock disburses.
///
///         State flags enforce correct sequencing:
///           collateralDeposited -> disbursed -> settled
///
///         Every ETH entry path has a defined exit — no funds can be stranded.

contract MerchantOfVenice {

    // ─────────────────────────────────────────────────────────
    // Parties
    // ─────────────────────────────────────────────────────────

    /// @notice The lender. Deploys the contract and disburses the loan.
    address public shylock;

    /// @notice The borrower. Deposits collateral and repays the loan.
    address public antonio;

    // ─────────────────────────────────────────────────────────
    // Financial terms (all values in wei)
    // ─────────────────────────────────────────────────────────

    /// @notice The loan amount Shylock will send to Antonio.
    uint256 public loanAmount;

    /// @notice The collateral Antonio must deposit — exactly twice the loan.
    ///         Returned to Antonio on repayment. Claimed by Shylock on default.
    uint256 public collateralAmount;

    // ─────────────────────────────────────────────────────────
    // Deadlines (Unix timestamps, set progressively)
    // ─────────────────────────────────────────────────────────

    /// @notice Antonio must deposit collateral before this timestamp.
    ///         Set at deployment.
    uint256 public depositDeadline;

    /// @notice Shylock must disburse the loan before this timestamp.
    ///         Set when Antonio calls depositCollateral().
    uint256 public disbursementDeadline;

    /// @notice Antonio must repay the loan before this timestamp.
    ///         Set when Shylock calls disburseLoan().
    uint256 public repaymentDeadline;

    // ─────────────────────────────────────────────────────────
    // Window durations (stored for reference)
    // ─────────────────────────────────────────────────────────

    /// @notice Seconds Antonio has to deposit collateral after deployment.
    uint256 public depositWindowSeconds;

    /// @notice Seconds Shylock has to disburse after Antonio deposits.
    uint256 public disbursementWindowSeconds;

    /// @notice Seconds Antonio has to repay after Shylock disburses.
    uint256 public repaymentWindowSeconds;

    // ─────────────────────────────────────────────────────────
    // State flags
    // ─────────────────────────────────────────────────────────

    /// @notice True once Antonio has deposited the required collateral.
    bool public collateralDeposited;

    /// @notice True once Shylock has disbursed the loan to Antonio.
    bool public disbursed;

    /// @notice True once the contract has reached its final state.
    ///         No further functions may be called after this point.
    bool public settled;

    // ─────────────────────────────────────────────────────────
    // Reentrancy guard
    // ─────────────────────────────────────────────────────────

    bool private _locked;

    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    /// @notice Emitted when the contract is deployed and terms are set.
    event ContractCreated(
        address indexed shylock,
        address indexed antonio,
        uint256 loanAmount,
        uint256 collateralAmount,
        uint256 depositDeadline
    );

    /// @notice Emitted when Antonio successfully deposits collateral.
    event CollateralDeposited(uint256 amount, uint256 disbursementDeadline);

    /// @notice Emitted when Shylock disburses the loan to Antonio.
    event LoanDisbursed(uint256 amount, uint256 repaymentDeadline);

    /// @notice Emitted when Antonio repays and collateral is returned.
    event LoanRepaid(uint256 repaymentAmount, uint256 collateralReturned);

    /// @notice Emitted when Antonio reclaims collateral after Shylock fails to disburse.
    event CollateralReclaimed(uint256 amount);

    /// @notice Emitted when Shylock claims collateral after Antonio defaults.
    event BondForfeited(uint256 amount);

    /// @notice Emitted when Shylock cancels after no collateral was deposited.
    event ContractCancelled();

    // ─────────────────────────────────────────────────────────
    // Access control modifiers
    // ─────────────────────────────────────────────────────────

    modifier onlyShylock() {
        require(msg.sender == shylock, "Only Shylock may call this");
        _;
    }

    modifier onlyAntonio() {
        require(msg.sender == antonio, "Only Antonio may call this");
        _;
    }

    // ─────────────────────────────────────────────────────────
    // State modifiers
    // ─────────────────────────────────────────────────────────

    modifier notSettled() {
        require(!settled, "Contract already settled");
        _;
    }

    modifier hasCollateral() {
        require(collateralDeposited, "Collateral not yet deposited");
        _;
    }

    modifier notDisbursed() {
        require(!disbursed, "Loan already disbursed");
        _;
    }

    modifier isDisbursed() {
        require(disbursed, "Loan not yet disbursed");
        _;
    }

    // ─────────────────────────────────────────────────────────
    // Time modifiers
    // ─────────────────────────────────────────────────────────

    modifier beforeDepositDeadline() {
        require(block.timestamp <= depositDeadline, "Deposit window has closed");
        _;
    }

    modifier afterDepositDeadline() {
        require(block.timestamp > depositDeadline, "Deposit window still open");
        _;
    }

    modifier beforeDisbursementDeadline() {
        require(block.timestamp <= disbursementDeadline, "Disbursement window has closed");
        _;
    }

    modifier afterDisbursementDeadline() {
        require(block.timestamp > disbursementDeadline, "Disbursement window still open");
        _;
    }

    modifier beforeRepaymentDeadline() {
        require(block.timestamp <= repaymentDeadline, "Repayment window has closed");
        _;
    }

    modifier afterRepaymentDeadline() {
        require(block.timestamp > repaymentDeadline, "Repayment window not yet closed");
        _;
    }

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Deploy the contract and set the lending terms.
    ///         No ETH is locked at this stage.
    /// @param _antonio                   The borrower's wallet address.
    /// @param _loanAmount                The loan amount in wei.
    /// @param _depositWindowSeconds      Seconds Antonio has to deposit collateral.
    /// @param _disbursementWindowSeconds Seconds Shylock has to disburse after deposit.
    /// @param _repaymentWindowSeconds    Seconds Antonio has to repay after disbursement.
    constructor(
        address _antonio,
        uint256 _loanAmount,
        uint256 _depositWindowSeconds,
        uint256 _disbursementWindowSeconds,
        uint256 _repaymentWindowSeconds
    ) {
        require(_antonio != address(0),           "Invalid Antonio address");
        require(_loanAmount > 0,                  "Loan amount must be positive");
        require(_depositWindowSeconds > 0,        "Deposit window must be positive");
        require(_disbursementWindowSeconds > 0,   "Disbursement window must be positive");
        require(_repaymentWindowSeconds > 0,      "Repayment window must be positive");

        shylock                   = msg.sender;
        antonio                   = _antonio;
        loanAmount                = _loanAmount;
        collateralAmount          = _loanAmount * 2;
        depositWindowSeconds      = _depositWindowSeconds;
        disbursementWindowSeconds = _disbursementWindowSeconds;
        repaymentWindowSeconds    = _repaymentWindowSeconds;
        depositDeadline           = block.timestamp + _depositWindowSeconds;

        emit ContractCreated(
            msg.sender,
            _antonio,
            _loanAmount,
            _loanAmount * 2,
            depositDeadline
        );
    }

    // ─────────────────────────────────────────────────────────
    // Safe ETH transfer helper
    // ─────────────────────────────────────────────────────────

    /// @dev Replaces .transfer() — forwards all available gas and reverts on failure.
    function _safeTransfer(address to, uint256 value) internal {
        (bool success, ) = payable(to).call{value: value}("");
        require(success, "ETH transfer failed");
    }

    // ─────────────────────────────────────────────────────────
    // Core functions
    // ─────────────────────────────────────────────────────────

    /// @notice Antonio deposits collateral equal to twice the loan amount.
    ///         Starts the disbursement clock for Shylock.
    function depositCollateral()
        external
        payable
        onlyAntonio
        notSettled
        notDisbursed
        beforeDepositDeadline
        nonReentrant
    {
        require(!collateralDeposited,          "Collateral already deposited");
        require(msg.value == collateralAmount, "Must deposit exactly twice the loan amount");

        collateralDeposited  = true;
        disbursementDeadline = block.timestamp + disbursementWindowSeconds;

        emit CollateralDeposited(msg.value, disbursementDeadline);
    }

    /// @notice Shylock disburses the loan directly to Antonio.
    ///         Shylock attaches exactly loanAmount in wei.
    ///         Starts the repayment clock for Antonio.
    ///         The contract never holds both sums simultaneously —
    ///         the loan ETH passes through to Antonio immediately.
    function disburseLoan()
        external
        payable
        onlyShylock
        notSettled
        hasCollateral
        notDisbursed
        beforeDisbursementDeadline
        nonReentrant
    {
        require(msg.value == loanAmount, "Must disburse exactly the loan amount");

        disbursed         = true;
        repaymentDeadline = block.timestamp + repaymentWindowSeconds;

        _safeTransfer(antonio, loanAmount);

        emit LoanDisbursed(loanAmount, repaymentDeadline);
    }

    /// @notice Antonio repays the loan before the repayment deadline.
    ///         Repayment is forwarded to Shylock and collateral is returned
    ///         to Antonio in the same transaction.
    ///         Checks-Effects-Interactions: settled is written before any transfer.
    function repay()
        external
        payable
        onlyAntonio
        notSettled
        isDisbursed
        beforeRepaymentDeadline
        nonReentrant
    {
        require(msg.value == loanAmount, "Must repay exactly the loan amount");

        settled = true;

        _safeTransfer(antonio, collateralAmount);
        _safeTransfer(shylock, loanAmount);

        emit LoanRepaid(loanAmount, collateralAmount);
    }

    /// @notice Antonio reclaims his collateral if Shylock failed to disburse
    ///         within the disbursement window.
    function reclaimCollateral()
        external
        onlyAntonio
        notSettled
        hasCollateral
        notDisbursed
        afterDisbursementDeadline
        nonReentrant
    {
        settled = true;
        _safeTransfer(antonio, collateralAmount);

        emit CollateralReclaimed(collateralAmount);
    }

    /// @notice Shylock claims the full collateral after Antonio defaults.
    ///         Only callable after the repayment deadline has passed.
    ///         Antonio keeps the loan ETH as the cost of default.
    function claimBond()
        external
        onlyShylock
        notSettled
        isDisbursed
        afterRepaymentDeadline
        nonReentrant
    {
        settled = true;
        _safeTransfer(shylock, collateralAmount);

        emit BondForfeited(collateralAmount);
    }

    /// @notice Shylock cancels the contract if Antonio never deposited collateral
    ///         and the deposit window has closed. No ETH is held so nothing moves.
    function cancel()
        external
        onlyShylock
        notSettled
        afterDepositDeadline
        nonReentrant
    {
        require(!collateralDeposited, "Collateral deposited — use reclaimCollateral path");

        settled = true;

        emit ContractCancelled();
    }

    // ─────────────────────────────────────────────────────────
    // View functions
    // ─────────────────────────────────────────────────────────

    /// @notice Seconds remaining in the deposit window. Returns 0 if closed.
    function timeToDepositDeadline() external view returns (uint256) {
        if (block.timestamp >= depositDeadline) return 0;
        return depositDeadline - block.timestamp;
    }

    /// @notice Seconds remaining in the disbursement window.
    ///         Returns 0 if collateral not deposited or window has closed.
    function timeToDisbursementDeadline() external view returns (uint256) {
        if (!collateralDeposited) return 0;
        if (block.timestamp >= disbursementDeadline) return 0;
        return disbursementDeadline - block.timestamp;
    }

    /// @notice Seconds remaining in the repayment window.
    ///         Returns 0 if loan not disbursed or window has closed.
    function timeToRepaymentDeadline() external view returns (uint256) {
        if (!disbursed) return 0;
        if (block.timestamp >= repaymentDeadline) return 0;
        return repaymentDeadline - block.timestamp;
    }

    /// @notice Current ETH balance held by the contract in wei.
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
