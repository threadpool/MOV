# The Merchant of Venice

A fully on-chain secured lending escrow on Ethereum. Deployed and demonstrated on Sepolia testnet.

## Overview

MerchantOfVenice enforces a complete lending lifecycle with no trusted third party at any stage. Antonio deposits collateral worth twice the loan amount. Shylock disburses the loan. Antonio repays and recovers his collateral, or defaults and forfeits it. Three time-locked windows ensure neither party can be trapped.

```
Deploy → depositCollateral() → disburseLoan() → repay() | claimBond()
```

## Contract Parameters

| Parameter | Description |
|---|---|
| `_antonio` | Borrower wallet address |
| `_loanAmount` | Loan amount in wei |
| `_depositWindowSeconds` | How long Antonio has to deposit collateral after deployment |
| `_disbursementWindowSeconds` | How long Shylock has to disburse after Antonio deposits |
| `_repaymentWindowSeconds` | How long Antonio has to repay after disbursement |

`collateralAmount` is computed automatically as `loanAmount * 2`.

## Functions

| Function | Caller | Description |
|---|---|---|
| `depositCollateral()` | Antonio | Locks 2x loan amount. Starts disbursement clock. |
| `disburseLoan()` | Shylock | Sends loan ETH to Antonio. Starts repayment clock. |
| `repay()` | Antonio | Returns loan to Shylock. Releases collateral. |
| `claimBond()` | Shylock | Claims collateral after Antonio defaults. |
| `reclaimCollateral()` | Antonio | Recovers collateral if Shylock never disburses. |
| `cancel()` | Shylock | Closes contract if Antonio never deposits. |

## ETH Flow

```
depositCollateral()   Antonio  →  Contract   (collateral locked)
disburseLoan()        Shylock  →  Antonio    (loan passes through)
repay()               Antonio  →  Shylock    (repayment) + Contract → Antonio (collateral returned)
claimBond()           Contract →  Shylock    (collateral forfeited)
reclaimCollateral()   Contract →  Antonio    (collateral returned)
```

## Security

- Reentrancy guard on all ETH-moving functions
- Checks-Effects-Interactions pattern throughout
- Three progressive deadlines enforced by `block.timestamp`
- State flags enforce correct sequencing: `collateralDeposited → disbursed → settled`
- No ETH can be stranded: every entry path has a defined exit

## Deployment (Remix)

1. Compile `MerchantOfVenice.sol` with Solidity `^0.8.20`
2. Set Environment to **Injected Provider — MetaMask**, network to **Sepolia**
3. Fill constructor fields. Do not attach ETH at deployment.
4. `_loanAmount` must be entered in **wei**. Use the Value field in **Gwei** for payable calls.

**Example — 1 ETH loan:**

| Field | Value |
|---|---|
| `_loanAmount` | `1000000000000000000` |
| `_depositWindowSeconds` | `600` |
| `_disbursementWindowSeconds` | `120` |
| `_repaymentWindowSeconds` | `180` |
| Antonio Value (depositCollateral) | `2000000000` Gwei |
| Shylock Value (disburseLoan) | `1000000000` Gwei |

## Licence

MIT
