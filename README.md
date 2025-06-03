# AISubscription Smart Contract System

## Overview

AISubscription is an Ethereum-based smart contract system designed to manage and track AI service subscriptions. The system uses native tokens (ETH) as the payment method, allowing users to purchase subscriptions of different tiers and tracking user subscriptions through tokenIds. All funds are stored in the Market contract and can be optionally transferred to a receiver address or retained in the contract. The system employs a signature verification mechanism to ensure that only authorized transactions are processed.

## Technical Architecture

The system consists of two main contracts:

1. **AISubscription.sol**: The core subscription record contract that manages subscription creation, upgrades, and tracking. It implements the IAISubscriptionServices interface.

2. **AISubscriptionMarket.sol**: The market contract that enables users to purchase/upgrade subscriptions using native tokens, manages funds, and integrates ECDSA signature verification to validate user calls to `purchaseSubscription`.

Both contracts adopt the Upgradeable Proxy Pattern (UUPS) to support future feature upgrades and bug fixes.

## Core Features

### Subscription Management
- **Subscription Recording**: Track user subscriptions using unique tokenIds
- **Tiered Subscription System**: Support different levels and prices of subscription cards
- **Upgrade Functionality**: Users can upgrade to higher-level subscriptions
- **Permission Management**: Fine-grained permission control using AccessControl with ADMIN_ROLE and MARKET_ROLE
- **Pausable Functionality**: Integration with PausableUpgradeable to pause operations in emergencies

### Market Features
- **Purchase Functionality**: Users can purchase subscriptions with native tokens
- **Upgrade Functionality**: Users can pay the price difference to upgrade to higher-level subscriptions
- **Fund Management**: Support transferring funds to specified receivers or retaining them in the contract
- **Token Withdrawal**: Support withdrawing native tokens and ERC20 tokens
- **Permission Control**: Comprehensive role and permission control including ADMIN_ROLE and SIGNER_ROLE

### Time Window Features
- **Purchase Window**: Configure specific time windows during which users can purchase subscriptions
- **Refund Window**: Define time periods when refunds are allowed

### Refund System
The system implements a flexible subscription refund mechanism that allows users to return subscriptions and receive partial refunds under certain conditions. The refund amount is dynamically calculated based on holding time, with longer holding periods resulting in lower refund percentages, encouraging long-term retention.

Key refund features include:
- **Time-based Refund Percentage**: Refund amounts decrease over time based on holding period
- **Time Window Restrictions**: Refunds are only allowed within specified time windows
- **Cooldown Period**: Prevents abuse by implementing a waiting period between refunds
- **Eligibility Checking**: Comprehensive checks for refund eligibility with detailed error messages

## Data Structures

### Card Information
```solidity
struct CardInfo {
    uint256 cardId;         // Unique card identifier
    uint256 currentAmount;  // Current number of cards minted
    uint256 level;          // Card tier level
    uint256 price;          // Card price (in wei)
    string tokenURI;        // Card metadata URI
}
```

### Time Window
```solidity
struct TimeWindow {
    uint256 startTime;      // Start timestamp
    uint256 endTime;        // End timestamp
}
```

### Refund Policy
```solidity
struct RefundPolicy {
    uint256 windowDuration; // Maximum holding time (seconds)
    uint256 baseRefundRate; // Base refund rate (percentage)
    uint256 decreaseRate;   // Daily decrease rate (percentage)
    uint256 minRefundRate;  // Minimum refund rate (percentage)
    uint256 cooldownPeriod; // Cooldown period (seconds)
}
```

## Usage Examples

### Deploying Contracts
```javascript
// Deploy the subscription contract
const AISubscriptionFactory = await ethers.getContractFactory("AISubscription");
const subscription = await upgrades.deployProxy(AISubscriptionFactory, [], {
    initializer: "initialize",
    kind: "uups",
});

// Deploy the market contract
const AISubscriptionMarketFactory = await ethers.getContractFactory("AISubscriptionMarket");
const market = await upgrades.deployProxy(AISubscriptionMarketFactory, [
    subscription.address,
    owner.address,
    admin.address,
    signer.address
], {
    initializer: "initialize",
    kind: "uups",
});

// Authorize the market in the subscription contract
await subscription.authorizeMarket(market.address);
```

### Creating Cards
```javascript
// Create a basic subscription card
await subscription.connect(admin).createCard(
    1,                                  // Card ID
    1,                                  // Level 1
    ethers.parseEther("0.01"),          // Price: 0.01 ETH
    "ipfs://QmBasicSubscriptionMetadata" // Token URI
);

// Create a premium subscription card
await subscription.connect(admin).createCard(
    2,                                  // Card ID
    2,                                  // Level 2
    ethers.parseEther("0.05"),          // Price: 0.05 ETH
    "ipfs://QmPremiumSubscriptionMetadata" // Token URI
);
```

### Setting Up Refund Policy
```javascript
// Set up refund policy
await market.connect(admin).setRefundPolicy(
    182 * 24 * 60 * 60,  // 182 days maximum holding time
    80,                  // 80% base refund rate
    33,                  // 0.33% daily decrease rate (scaled by 100)
    20,                  // 20% minimum refund rate
    5 * 60 * 60          // 5 hours cooldown period
);

// Enable refund window
const now = Math.floor(Date.now() / 1000);
await market.connect(admin).setRefundWindow(
    now,                        // Start now
    now + (90 * 24 * 60 * 60)   // End in 90 days
);
```

### Purchasing a Subscription
```javascript
// Purchase a basic subscription
const signature = await generateSignature(cardId, user.address, signer);
await market.connect(user).purchaseSubscription(1, signature, { 
    value: ethers.parseEther("0.01") 
});
```

### Checking Refund Eligibility
```javascript
// Check refund eligibility for token ID 123
const [eligible, refundAmount, timeLeft, reason] = await market.checkRefundEligibility(123, userAddress);

console.log(`Refund eligibility check for token #123:`);
console.log(`- Eligible: ${eligible}`);
    
if (eligible) {
    console.log(`- Refund amount: ${ethers.formatEther(refundAmount)} ETH`);
    console.log(`- Remaining refund window time: ${timeLeft / 86400} days`);
} else {
    console.log(`- Reason for ineligibility: ${reason}`);
}
```

### Processing a Refund
```javascript
// Process refund for token ID 123
try {
    const tx = await market.connect(user).refundSubscription(123);
    const receipt = await tx.wait();
    
    // Find the refund event
    const refundEvent = receipt.events.find(e => e.event === "RefundProcessed");
    
    console.log(`Refund successful:`);
    console.log(`- Token ID: ${refundEvent.args.tokenId}`);
    console.log(`- Card ID: ${refundEvent.args.cardId}`);
    console.log(`- Refund amount: ${ethers.formatEther(refundEvent.args.refundAmount)} ETH`);
    console.log(`- Applied refund rate: ${refundEvent.args.refundRate}%`);
} catch (error) {
    console.error(`Refund failed: ${error.message}`);
}
```

## Security Considerations

1. **Re-entrancy Protection**: Uses ReentrancyGuard to prevent re-entrancy attacks in all fund-transferring functions
2. **Time Restrictions**: Uses time windows and cooldown periods to prevent frequent refund abuse
3. **Permission Control**: Refund policy and time window settings are restricted to ADMIN_ROLE permissions
4. **Precise Calculations**: Refund amounts use percentage-based precise calculations to avoid rounding errors
5. **Validate-First Pattern**: All conditions are verified before any state changes to ensure operation safety
6. **Detailed Error Messages**: Provides clear error reasons to help users understand refund failures
7. **ECDSA Signature Verification**: Validates transaction signatures to prevent unauthorized operations
8. **Upgradeable Architecture**: Uses UUPS pattern to allow fixing vulnerabilities and adding features
9. **Fund Protection**: Configurable fund destination to avoid funds being locked in contracts
10. **Event System**: Comprehensive event system for transaction tracking and verification

## Testing Coverage

The system includes comprehensive testing suites covering:

1. Contract initialization and basic functionality
2. Card creation and price queries
3. Card information update functionality
4. Native token payment and refund mechanisms
5. Subscription upgrade functionality
6. Permission control and role management
7. Complete end-to-end process testing
8. ERC20 token withdrawal functionality testing
9. Signature verification mechanism testing
10. Refund policy configuration and validation
11. Refund eligibility checking and time simulation
12. Refund processing flow and limitation conditions

## License

[MIT](LICENSE)
