// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IAISubscription} from "./interface/IAISubscription.sol";

/**
 * @title AISubscriptionMarket
 * @dev Contract for selling AISubscription records using native token as payment
 */
contract AISubscriptionMarket is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    /**
     * @dev Emitted when a subscription is upgraded
     */
    event UpgradeSubscription(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed toCardId
    );

    /// @dev Event emitted when a new subscription is purchased
    event PurchaseSubscription(
        address indexed user,
        uint indexed cardId,
        uint indexed tokenId
    );

    /// @dev Event emitted when token is withdrawn
    event WithdrawToken(address indexed token, uint256 amount, address indexed to);

    /// @dev Event emitted when receiver is set
    event SetReceiver(address indexed receiver);

    /// @dev Event emitted when subscription service is set
    event SetSubscriptionService(address indexed subscription);

    /// @dev Event emitted when admin role is set
    event SetAdmin(address indexed admin, bool isAuthorized);

    /// @dev Event emitted when market role is set
    event SetMarket(address indexed market, bool isAuthorized);
    
    /// @dev Event emitted when a refund is processed
    event RefundProcessed(
        address indexed user,
        uint256 indexed tokenId, 
        uint256 cardId,
        uint256 refundAmount
    );
    
    /// @dev Event emitted when refund policy is updated
    event RefundPolicyUpdated(
        uint256 windowDuration,
        uint256 baseRefundRate,
        uint256 decreaseRate,
        uint256 minRefundRate,
        uint256 cooldownPeriod
    );
    
    /// @dev Event emitted when purchase window is updated
    event PurchaseWindowUpdated(
        uint256 startTime,
        uint256 endTime
    );
    
    /// @dev Event emitted when refund window is updated
    event RefundWindowUpdated(
        uint256 startTime,
        uint256 endTime
    );

    /**
     * @dev Role definitions
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    
    /**
     * @dev Time window structure for limiting operations to specific periods
     */
    struct TimeWindow {
        uint256 startTime;   // Start timestamp
        uint256 endTime;     // End timestamp
    }
    
    /**
     * @dev Refund policy parameters
     */
    struct RefundPolicy {
        uint256 windowDuration;   // Max holding time for refund eligibility (seconds)
        uint256 baseRefundRate;   // Base refund rate (percentage, e.g., 80 means 80%)
        uint256 decreaseRate;     // Refund rate decrease per day
        uint256 minRefundRate;    // Minimum refund rate
        uint256 cooldownPeriod;   // Cooldown period after refund (seconds)
    }

    /// @dev Receiver address
    address public receiver;
    
    /// @dev AISubscription contract instance
    IAISubscription public subscription;
    
    /// @dev Refund policy settings
    RefundPolicy public refundPolicy;
    
    /// @dev Purchase window settings
    TimeWindow public purchaseWindow;
    
    /// @dev Refund window settings
    TimeWindow public refundWindow;
    
    /// @dev Mapping of token purchase timestamps
    mapping(uint256 => uint256) private tokenPurchaseTime;
    
    /// @dev Mapping of user's last refund time
    mapping(address => uint256) private lastRefundTime;

    /**
     * @dev Initializes the contract
     */
    function initialize(address subscriptionAddr_, address owner_, address admin_, address signer_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        // Setup roles with validation
        require(owner_ != address(0), "AM: owner is the zero address");
        require(admin_ != address(0), "AM: admin is the zero address");
        require(signer_ != address(0), "AM: signer is the zero address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(SIGNER_ROLE, signer_);
        
        _setSubscriptionService(subscriptionAddr_);
        
        // Initialize refund policy with default values
        refundPolicy = RefundPolicy({
            windowDuration: 365 days,
            baseRefundRate: 80,
            decreaseRate: 33, // 0.33% per day, perfectly tuned for 26 weeks (182 days) period
            minRefundRate: 20,
            cooldownPeriod: 1 days
        });
        
        // Initialize purchase window
        purchaseWindow = TimeWindow({
            startTime: 0,
            endTime: 0
        });
        
        // Initialize refund window
        refundWindow = TimeWindow({
            startTime: 0,
            endTime: 0
        });
    }

    /**
     * @dev Modifier to check if the current time is within the purchase window
     */
    modifier withinPurchaseWindow() {
        require(
            purchaseWindow.startTime < purchaseWindow.endTime && 
            block.timestamp >= purchaseWindow.startTime && 
            block.timestamp <= purchaseWindow.endTime,
            "AM: purchase window closed"
        );
        _;
    }

    /**
     * @dev Buy a subscription with native token
     * @param cardId_ Card ID to purchase
     * @param signature_ Signature from the signer role
     */
    function purchaseSubscription(uint256 cardId_, bytes calldata signature_) public nonReentrant withinPurchaseWindow payable {
        // only one subscription per user
        require(subscription.balanceOf(msg.sender) == 0, "AM: already owned");

        bytes32 messageHash = keccak256(
            abi.encodePacked(msg.sender,block.chainid,address(this))
        );

        require(hasRole(SIGNER_ROLE, (messageHash.toEthSignedMessageHash()).recover(signature_)), "AM: invalid signer");

        uint price = getCardPrice(cardId_);
        require(msg.value >= price, "AM: insufficient ETH");
        
        // Mint the subscription to the buyer
        uint tokenId = subscription.mint(msg.sender, cardId_, 1);
        
        // Record purchase time for potential refund
        tokenPurchaseTime[tokenId] = block.timestamp;
        
        // if receiver is set, send ETH to receiver
        if (receiver != address(0)) {
            (bool success, ) = receiver.call{value: price}("");
            require(success, "AM: transfer failed");
        }
        
        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: refund}("");
            require(refundSuccess, "AM: refund failed");
        }
        
        emit PurchaseSubscription(msg.sender, cardId_, tokenId);
    }
    
    /**
     * @dev Upgrades a subscription to a higher level card
     * @param tokenId_ ID of the token to upgrade
     * @param toCardId_ ID of the card to upgrade to
     * @return bool indicating successful operation
     */
    function upgradeSubscription(uint256 tokenId_, uint256 toCardId_) public payable nonReentrant returns (bool) {
        // Check token ownership
        require(subscription.ownerOf(tokenId_) == msg.sender, "AM: Not owner");
        
        (,,, uint256 currentPrice,) = subscription.cardInfoes(subscription.getCardIdByTokenId(tokenId_));
        (,,, uint256 newPrice,) = subscription.cardInfoes(toCardId_);
        
        uint256 priceDiff = newPrice - currentPrice;
        require(msg.value >= priceDiff, "AM: insufficient ETH");

        // if receiver is set, send ETH to receiver
        if (receiver != address(0)) {
            (bool success, ) = receiver.call{value: priceDiff}("");
            require(success, "AM: transfer failed");
        }
        
        subscription.upgrade(tokenId_, toCardId_);
        
        uint256 refund = msg.value - priceDiff;
        if (refund > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: refund}("");
            require(refundSuccess, "AM: refund failed");
        }
        
        emit UpgradeSubscription(msg.sender, tokenId_, toCardId_);
        return true;
    }
    
    /**
     * @dev Withdraws Token from the contract to the wallet address
     */
    function withdrawToken(address token, uint256 amount, address to) public nonReentrant onlyRole(ADMIN_ROLE) {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "AM: transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit WithdrawToken(token, amount, to);
    }

    /**
     * @dev Sets the wallet address for receiving funds
     * @param receiver_ New receiver address
     */
    function setReceiver(address receiver_) public onlyRole(ADMIN_ROLE) {
        receiver = receiver_;
        emit SetReceiver(receiver_);
    }

    /**
     * @dev Sets the AISubscription contract address
     * @param subscriptionAddr_ New AISubscription contract address
     */
    function setSubscriptionService(address subscriptionAddr_) public onlyRole(ADMIN_ROLE) {
        _setSubscriptionService(subscriptionAddr_);
    }

    /**
     * @dev Transfers ownership of the contract to a new owner
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) public onlyRole(ADMIN_ROLE) {
        require(newOwner != address(0), "AM: zero address");
        _grantRole(ADMIN_ROLE, newOwner);
        _revokeRole(ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Authorizes or revokes admin role for a specific address
     * @param admin Address to authorize or revoke
     * @param isAuthorized Boolean indicating whether to authorize or revoke
     */
    function authorizeAdmin(address admin, bool isAuthorized) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (isAuthorized) {
            _grantRole(ADMIN_ROLE, admin);
        } else {
            _revokeRole(ADMIN_ROLE, admin);
        }
        emit SetAdmin(admin, isAuthorized);
    }

    /**
     * @dev Internal function to set the AISubscription contract address
     * @param subscriptionAddr_ New AISubscription contract address
     */
    function _setSubscriptionService(address subscriptionAddr_) internal {
        require(subscriptionAddr_ != address(0), "AIMarket: zero address");
        subscription = IAISubscription(subscriptionAddr_);
        emit SetSubscriptionService(subscriptionAddr_);
    }

    /**
     * @dev Gets the price of a specific card in native token
     * @param cardId_ Card ID to query price for
     * @return Price of the card in native token (wei)
     */
    function getCardPrice(uint cardId_) public view returns (uint) {
        (,,, uint256 price,) = subscription.cardInfoes(cardId_);
        return price;
    }
    
    /**
     * @dev Process subscription refund
     * @param tokenId_ Token ID to refund
     * @return refundAmount Amount refunded
     */
    function refundSubscription(uint256 tokenId_) public nonReentrant returns (uint256) {
        // Check eligibility and get refund amount
        (bool eligible, uint256 refundAmount, , string memory reason) = checkRefundEligibility(tokenId_, msg.sender);
        require(eligible, string(abi.encodePacked("AM: refund not eligible - ", reason)));
        
        // Get card ID for event emission
        uint256 cardId = subscription.getCardIdByTokenId(tokenId_);
        
        // Check contract balance before refund
        require(address(this).balance >= refundAmount, "AM: insufficient contract balance");
        
        // Update last refund time for cooldown
        lastRefundTime[msg.sender] = block.timestamp;
        
        // Burn the Subscription
        subscription.burn(tokenId_);
        
        // Delete purchase time record
        delete tokenPurchaseTime[tokenId_];
        
        // Process refund
        if (refundAmount > 0) {
            // Send refund from market contract balance
            (bool success, ) = msg.sender.call{value: refundAmount}("");
            require(success, "AM: refund transfer failed");
        }
        
        // Emit refund event
        emit RefundProcessed(msg.sender, tokenId_, cardId, refundAmount);
        
        return refundAmount;
    }
    
    /**
     * @dev Calculate refund rate based on holding days
     * @param holdingDays Days the subscription has been held
     * @return Refund rate as percentage (0-100)
     */
    function calculateRefundRate(uint256 holdingDays) internal view returns (uint256) {
        uint256 rate = refundPolicy.baseRefundRate;
        
        // Decrease rate for each day held
        if (holdingDays > 0) {
            uint256 reduction = (holdingDays * refundPolicy.decreaseRate) / 100;
            
            if (reduction >= rate) {
                return refundPolicy.minRefundRate;
            }
            
            rate = rate - reduction;
            
            // Ensure rate doesn't go below minimum
            if (rate < refundPolicy.minRefundRate) {
                rate = refundPolicy.minRefundRate;
            }
        }
        
        return rate;
    }
    
    /**
     * @dev Set refund policy parameters
     * @param windowDuration Refund window period (seconds)
     * @param baseRefundRate Base refund rate (percentage)
     * @param decreaseRate Daily decrease rate
     * @param minRefundRate Minimum refund rate
     * @param cooldownPeriod Cooldown period after refund (seconds)
     */
    function setRefundPolicy(
        uint256 windowDuration,
        uint256 baseRefundRate,
        uint256 decreaseRate,
        uint256 minRefundRate,
        uint256 cooldownPeriod
    ) public onlyRole(ADMIN_ROLE) {
        require(baseRefundRate <= 100, "AM: invalid base refund rate");
        require(minRefundRate <= baseRefundRate, "AM: min rate exceeds base rate");
        
        refundPolicy = RefundPolicy({
            windowDuration: windowDuration,
            baseRefundRate: baseRefundRate,
            decreaseRate: decreaseRate,
            minRefundRate: minRefundRate,
            cooldownPeriod: cooldownPeriod
        });
        
        emit RefundPolicyUpdated(
            windowDuration, 
            baseRefundRate, 
            decreaseRate, 
            minRefundRate, 
            cooldownPeriod
        );
    }
    
    /**
     * @dev Check if a token is eligible for refund
     * @param tokenId_ Token ID to check
     * @param owner_ Owner of the token
     * @return eligible Whether the token is eligible for refund
     * @return refundAmount Estimated refund amount (if eligible)
     * @return timeLeft Time left in refund window (seconds)
     * @return reason Reason for ineligibility if not eligible
     */
    function checkRefundEligibility(uint256 tokenId_, address owner_) public view returns (
        bool eligible,
        uint256 refundAmount,
        uint256 timeLeft,
        string memory reason
    ) {
        return _checkRefundEligibility(tokenId_, owner_);
    }

    function _checkRefundEligibility(uint256 tokenId_, address owner_) internal view returns (
        bool eligible,
        uint256 refundAmount,
        uint256 timeLeft,
        string memory reason
    ) {
        // Default values
        eligible = false;
        refundAmount = 0;
        timeLeft = 0;
        reason = "";
        
        // Check if refunds are enabled
        if (refundWindow.startTime >= refundWindow.endTime) {
            reason = "refund window not enabled";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Check global refund window if enabled
        if (block.timestamp < refundWindow.startTime) {
            reason = "Global refund window not started yet";
            return (eligible, refundAmount, timeLeft, reason);
        }
        if (block.timestamp > refundWindow.endTime) {
            reason = "Global refund window already closed";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Check token existence and ownership
        address owner;
        try subscription.ownerOf(tokenId_) returns (address tokenOwner) {
            owner = tokenOwner;
            // Verify caller is the token owner
            if (owner != owner_) {
                reason = "Not token owner";
                return (eligible, refundAmount, timeLeft, reason);
            }
        } catch {
            reason = "Token does not exist";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Check purchase time
        uint256 purchaseTime = tokenPurchaseTime[tokenId_];
        if (purchaseTime == 0) {
            reason = "Purchase time not recorded";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Check maximum holding time window
        uint256 windowEnd = purchaseTime + refundPolicy.windowDuration;
        if (block.timestamp > windowEnd) {
            reason = "Max holding time exceeded";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // cool down period
        if (block.timestamp <= lastRefundTime[msg.sender] + refundPolicy.cooldownPeriod) {
            reason = "In cooldown period";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Calculate remaining time in refund window
        timeLeft = windowEnd - block.timestamp;
        
        // Get card ID and price
        uint256 cardId = subscription.getCardIdByTokenId(tokenId_);
        uint256 originalPrice = getCardPrice(cardId);
        
        // Calculate refund amount
        uint256 holdingDays = (block.timestamp - purchaseTime) / 1 days;
        uint256 refundRate = calculateRefundRate(holdingDays);
        refundAmount = (originalPrice * refundRate) / 100;
        
        eligible = true;
        return (eligible, refundAmount, timeLeft, reason);
    }
       
    /**
     * @dev Sets the purchase time window
     * @param startTime_ Start timestamp
     * @param endTime_ End timestamp
     */
    function setPurchaseWindow(
        uint256 startTime_,
        uint256 endTime_
    ) public onlyRole(ADMIN_ROLE) {
        require(startTime_ < endTime_ || (startTime_ == 0 && endTime_ == 0), "AM: invalid time window");
        
        purchaseWindow.startTime = startTime_;
        purchaseWindow.endTime = endTime_;
        
        emit PurchaseWindowUpdated(startTime_, endTime_);
    }
    
    /**
     * @dev Sets the refund time window
     * @param startTime_ Start timestamp
     * @param endTime_ End timestamp
     */
    function setRefundWindow(
        uint256 startTime_,
        uint256 endTime_
    ) public onlyRole(ADMIN_ROLE) {
        require(startTime_ < endTime_ || (startTime_ == 0 && endTime_ == 0), "AM: invalid time window");
        
        refundWindow.startTime = startTime_;
        refundWindow.endTime = endTime_;
        
        emit RefundWindowUpdated(startTime_, endTime_);
    }
    
    /**
     * @dev Gets the system status information
     * @return purchaseActive Whether purchases are currently allowed
     * @return purchaseTimeLeft Time left until purchase window changes state (seconds)
     * @return refundActive Whether refunds are currently allowed
     * @return refundTimeLeft Time left until refund window changes state (seconds)
     */
    function getSystemStatus() public view returns (
        bool purchaseActive,
        uint256 purchaseTimeLeft,
        bool refundActive,
        uint256 refundTimeLeft
    ) {
        // Check purchase window status
        if (block.timestamp < purchaseWindow.startTime) {
            purchaseActive = false;
            purchaseTimeLeft = purchaseWindow.startTime - block.timestamp;
        } else if (block.timestamp <= purchaseWindow.endTime) {
            purchaseActive = true;
            purchaseTimeLeft = purchaseWindow.endTime - block.timestamp;
        } else {
            purchaseActive = false;
            purchaseTimeLeft = 0;
        }
        
        // Check refund window status
        if (refundWindow.startTime >= refundWindow.endTime) {
            refundActive = false;
            refundTimeLeft = 0;
        } else if (block.timestamp < refundWindow.startTime) {
            refundActive = false;
            refundTimeLeft = refundWindow.startTime - block.timestamp;
        } else if (block.timestamp <= refundWindow.endTime) {
            refundActive = true;
            refundTimeLeft = refundWindow.endTime - block.timestamp;
        } else {
            refundActive = false;
            refundTimeLeft = 0;
        }
        
        return (purchaseActive, purchaseTimeLeft, refundActive, refundTimeLeft);
    }
    
    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable {}
}
