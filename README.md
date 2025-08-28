# MEV Protection System Documentation

## Overview

The MEV Protection rebates MEV captured by bots back to the user or a specified refund recipient. Built on the Atlas protocol, it creates a fair auction mechanism where solvers compete to bid for the right to backrun a user.

### Key Benefits

- **Value Recovery**: Captures MEV that would otherwise be lost to extractors and shares it with users
- **Fair Auctions**: Transparent bidding system ensures competitive pricing
- **Seamless Integration**: Works with existing DEX interfaces with minimal changes

## System Architecture

### Core Components

1. **BackrunDAppControl**: Main contract handling swap execution and MEV protection logic
2. **Atlas Protocol**: Underlying auction and execution framework
3. **Solver Network**: Competing entities providing MEV protection services
4. **Router Whitelist**: Approved DEX routers for secure swap execution

### Flow Overview

1. User submits swap transaction through MEV-protected interface
2. Atlas protocol creates auction for MEV protection rights
3. Solvers compete by bidding to protect the transaction
4. Winning solver executes protection strategy
5. Extracted value is distributed between user, refund recipient, and governance

## BackrunDAppControl Contract

### Constructor Parameters

```solidity
constructor(
    address _atlas,           // Atlas protocol address
    address _govPayoutAddr,   // Governance treasury address
    uint256 _govPercent       // Governance fee percentage (basis points)
)
```

### Key State Variables

- **`govPercent`** (`uint256`): Percentage of extracted MEV allocated to governance (in basis points, max 10,000)
- **`govPayoutAddr`** (`address`): Address receiving governance portion of MEV
- **`routerWhitelist`** (`mapping(address => uint8)`): Approved DEX routers with their types

### Router Types

- **`ROUTER_TYPE_NONE` (0)**: Router not whitelisted
- **`ROUTER_TYPE_APPROVE` (1)**: Requires token approval before swap
- **`ROUTER_TYPE_DIRECT` (2)**: Tokens transferred directly to router

## Core Functions

### User Functions

#### `swap`
```solidity
function swap(
    SwapTokenInfo calldata _swapInfo,
    address _refundRecipient,
    uint256 _refundPercent
) external payable
```

**Purpose**: Main entry point for MEV-protected token swaps

**Parameters**:
- `_swapInfo`: Swap configuration including tokens, amounts, and DEX router
- `_refundRecipient`: Address to receive portion of extracted MEV
- `_refundPercent`: Percentage of MEV to refund to recipient (basis points)

**SwapTokenInfo Structure**:
```solidity
struct SwapTokenInfo {
    address inputToken;           // Token being sold (address(0) for ETH)
    uint256 inputAmount;          // Amount of input token
    address outputToken;          // Token being bought
    uint256 outputMin;           // Minimum acceptable output amount
    bool bidTokenIsOutputToken;  // Whether bid token matches output token
    address target;              // DEX router address
    bytes swapData;              // Encoded swap function call
}
```

### Governance Functions

#### `setGovPayoutAddr`
```solidity
function setGovPayoutAddr(address _govPayoutAddr) external onlyGovernance
```

**Purpose**: Updates the governance payout address for MEV revenue

#### `setGovPercent`
```solidity
function setGovPercent(uint256 _govPercent) external onlyGovernance
```

**Purpose**: Updates governance fee percentage (0-10,000 basis points)

#### `addRouter`
```solidity
function addRouter(address _router, uint8 _type) external onlyGovernance
```

**Purpose**: Adds DEX router to whitelist with specified type

#### `removeRouter`
```solidity
function removeRouter(address _router) external onlyGovernance
```

**Purpose**: Removes DEX router from whitelist

### View Functions

#### `getBidFormat`
```solidity
function getBidFormat(UserOperation calldata userOp) external view returns (address)
```

**Returns**: Token address that solvers must bid in (output token or ETH)

#### `getPayoutData`
```solidity
function getPayoutData() external view returns (address, uint256)
```

**Returns**: Governance payout address and percentage

#### `isRouterWhitelisted`
```solidity
function isRouterWhitelisted(address _router) external view returns (uint8)
```

**Returns**: Router type (0 if not whitelisted, 1-2 for whitelisted types)

## Atlas Integration Hooks

### `_preOpsCall`

**Purpose**: Executed before main swap operation
- Validates router whitelist status
- Handles ERC20 token swaps and approvals
- Sets refund parameters for value distribution

### `_preSolverCall`

**Purpose**: Validates solver bids before execution
- Ensures bid token matches expected format
- Prevents invalid bid submissions

### `_allocateValueCall`

**Purpose**: Distributes extracted MEV value
- Calculates governance, refund recipient, and user portions
- Transfers tokens to respective recipients
- Emits tracking events

## Value Distribution Model

### Distribution Formula

Total MEV extracted is distributed as follows:

1. **Governance Share**: `(totalValue * govPercent) / 10000`
2. **Refund Share**: `(totalValue * refundPercent) / 10000`
3. **User Share**: `totalValue - governanceShare - refundShare`

### Constraints

- Combined governance and refund percentages cannot exceed 100% (10,000 basis points)
- Minimum user retention is enforced through percentage limits
- All calculations use basis points for precision

## Solver Integration

### Solver Requirements

Solvers must implement the Atlas SolverBase pattern and provide:

1. **Bid Calculation**: Determine competitive bid amount
2. **MEV Strategy**: Execute protection or value extraction logic
3. **Payment Handling**: Ensure bid payment to execution environment

### Example Solver Implementation

```solidity
contract ExampleSolver is SolverBase {
    function solve() public onlySelf {
        // Implement MEV protection strategy
        // Bid payment handled automatically by Atlas
    }
}
```

### Solver Responsibilities

- Monitor user operations from fastlane auctioneer for profitable opportunities
- Calculate optimal bid amounts
- Execute MEV extraction strategies
- Maintain sufficient token balances for bids

## DApp Integration Guide

### Frontend Integration

1. **Replace Standard DEX Calls**: Route swap transactions through MEV protection system
2. **Configure Parameters**: Set appropriate refund recipients and percentages
3. **Handle Gas Estimation**: Account for additional execution overhead
4. **User Communication**: Inform users about MEV protection benefits

### Integration Example

```javascript
// Standard DEX swap
const swapTx = await router.swapExactTokensForTokens(
    amountIn, amountOutMin, path, to, deadline
);

// MEV-protected swap
const swapInfo = {
    inputToken: tokenA,
    inputAmount: amountIn,
    outputToken: tokenB,
    outputMin: amountOutMin,
    bidTokenIsOutputToken: true,
    target: routerAddress,
    swapData: router.interface.encodeFunctionData('swapExactTokensForTokens', [
        amountIn, amountOutMin, path, to, deadline
    ])
};

const protectedTx = await mevProtection.swap(
    swapInfo,
    refundAddress,     // refund recipient
    500             // 5% refund to user
);
```

### Required Approvals

For ERC20 swaps, users must approve the Atlas contract instead of the DEX router directly.

## API Reference

### Events

#### `SwapSuccess`
```solidity
event SwapSuccess(
    address indexed target,
    address indexed inputToken,
    address indexed outputToken,
    uint256 inputAmount,
    uint256 outputAmount
)
```

#### `UserPayout`
```solidity
event UserPayout(
    address indexed user,
    uint256 amount,
    address bidToken
)
```

#### `GovernancePayout`
```solidity
event GovernancePayout(
    address indexed govPayoutAddr,
    uint256 amount,
    address bidToken
)
```

#### Router Management Events
- `RouterAdded(address indexed router, uint8 routerType)`
- `RouterRemoved(address indexed router)`
- `GovernancePayoutAddressUpdated(address indexed oldAddr, address indexed newAddr)`
- `GovernancePayoutSplitUpdated(uint256 oldPercentage, uint256 newPercentage)`

### Error Conditions

- **`InsufficientOutputBalance()`**: Swap didn't produce minimum required output
- **`InsufficientUserOpValue()`**: ETH amount doesn't match specified input amount
- **`UserOpDappNotSwapRouter()`**: Target router not whitelisted
- **`SwapFailed()`**: DEX router call failed
- **`WrongBidToken()`**: Solver bid token doesn't match expected format
- **`GovPercentExceedsScale()`**: Governance percentage exceeds maximum allowed

## Security Considerations

### Access Controls

- **Governance Functions**: Restricted to governance address only
- **Router Whitelist**: Only approved routers can execute swaps
- **Bid Validation**: Strict validation of solver bids and tokens

### Safety Mechanisms

- **Slippage Protection**: Enforces minimum output amounts
- **Overpayment Refunds**: Automatically refunds excess payments
- **Balance Verification**: Validates token balances before and after swaps
- **Reentrancy Protection**: Built into Atlas protocol framework

## Performance and Gas Optimization

### Gas Efficiency

- Optimized token transfer patterns
- Efficient balance checking mechanisms
- Minimal external calls for core operations

### Expected Gas Overhead

- Additional ~250,000 gas compared to direct DEX calls
- Solvers pay for their own gas used on solver ops
- Winning solver pays for the entire gas used of the transaction

## Deployment Configuration

### Required Parameters

1. **Atlas Address**: Deployed Atlas protocol contract
2. **Governance Address**: Treasury/DAO address for fee collection
3. **Governance Percentage**: Initial fee percentage (suggested: 5-10%)
4. **Router Whitelist**: Initial set of approved DEX routers