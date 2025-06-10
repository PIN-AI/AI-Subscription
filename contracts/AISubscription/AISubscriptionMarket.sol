// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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
contract AISubscriptionMarket is Initializable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
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
     * @dev Event emitted when active subscription payment is paid
     */
    event PayActiveSubscription(address indexed user, uint256 amount, uint256 tokenId);

    /**
     * @dev Event emitted when active subscription payment is set
     */
    event SetActiveSubscriptionPayment(uint256 amount);

    /**
     * @dev Event emitted when fund receiver is set
     */
    event SetFundReceiver(address indexed fundReceiver);

    /**
     * @dev Role definitions
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    /**
     * @dev Maximum refund rate
     */
    uint256 internal constant _MAX_REFUND_RATE = 100;
    
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

    /// @dev Maximum active subscription payment
    uint256 internal constant _MAX_ACTIVE_SUBSCRIPTION_PAYMENT = 0.005 ether;

    /// @dev Receiver address
    address public receiver;

    /// @dev Fund receiver address
    address internal _fundReceiver;
    
    /// @dev AISubscription contract instance
    IAISubscription public subscription;
    
    /// @dev Refund policy settings
    RefundPolicy public refundPolicy;
    
    /// @dev Purchase window settings
    TimeWindow public purchaseWindow;
    
    /// @dev Refund window settings
    TimeWindow public refundWindow;

    // @dev Payment for active subscription
    uint256 public activeSubscriptionPayment;

    /// @dev mapping of active subscriptions
    mapping(address => bool) public activeSubscription;

    /// @dev mapping of user's card ID
    mapping(address => uint256) public userCardId;
    
    /// @dev Mapping of token purchase timestamps
    mapping(uint256 => uint256) private tokenPurchaseTime;
    
    /// @dev Mapping of user's last refund time
    mapping(address => uint256) private lastRefundTime;

    /**
     * @dev Initializes the contract
     */
    function initialize(address subscriptionAddr_, address owner_, address admin_, address signer_, address fundReceiver_) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        
        // Setup roles with validation
        require(owner_ != address(0), "AM: owner is the zero address");
        require(admin_ != address(0), "AM: admin is the zero address");
        require(signer_ != address(0), "AM: signer is the zero address");
        require(fundReceiver_ != address(0), "AM: fund receiver is the zero address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(SIGNER_ROLE, signer_);
        
        _setSubscriptionService(subscriptionAddr_);

        _fundReceiver = fundReceiver_;
        
        // Initialize refund policy with default values
        refundPolicy = RefundPolicy({
            windowDuration: 0,
            baseRefundRate: 100,
            decreaseRate: 0,
            minRefundRate: 100,
            cooldownPeriod: 0
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
    function purchaseSubscription(uint256 cardId_, bytes calldata signature_) public nonReentrant withinPurchaseWindow whenNotPaused payable {
        // only one subscription per user
        require(subscription.balanceOf(msg.sender) == 0, "AM: already owned");
        require(!activeSubscription[msg.sender], "AM: already active subscription");
        
        if (userCardId[msg.sender] != 0) {
            require(userCardId[msg.sender] == cardId_, "AM: must same card");
        }else{
            userCardId[msg.sender] = cardId_;
        }

        bytes32 messageHash = keccak256(
            abi.encodePacked(msg.sender,block.chainid,address(this))
        );

        require(hasRole(SIGNER_ROLE, (messageHash.toEthSignedMessageHash()).recover(signature_)), "AM: invalid signer");

        uint256 payAmount = getCardPrice(cardId_);
        require(msg.value >= payAmount && payAmount > 0, "AM: insufficient ETH");
        
        // Mint the subscription to the buyer
        uint tokenId = subscription.mint(msg.sender, cardId_, 1);
        
        // Record purchase time for potential refund
        tokenPurchaseTime[tokenId] = block.timestamp;

        _activateSubscription(msg.sender);
        
        // if receiver is set, send ETH to receiver
        if (receiver != address(0)) {
            (bool success, ) = receiver.call{value: payAmount}("");
            require(success, "AM: transfer failed");
        }
        
        uint256 refund = msg.value - payAmount;
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
    function upgradeSubscription(uint256 tokenId_, uint256 toCardId_) public payable nonReentrant whenNotPaused returns (bool) {
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
     * @dev Pay for active subscription
     */
    function payActiveSubscription() public payable whenNotPaused withinPurchaseWindow {
        uint256 _activeSubscriptionPayment = activeSubscriptionPayment;
        require(subscription.balanceOf(msg.sender) == 0, "AM: already owned");
        require(!activeSubscription[msg.sender], "AM: already active subscription");
        require(msg.value >= _activeSubscriptionPayment, "AM: insufficient ETH");
        
        // if receiver is set, send ETH to receiver
        if (receiver != address(0)) {
            (bool success, ) = receiver.call{value: msg.value}("");
            require(success, "AM: transfer failed");
        }
        _activateSubscription(msg.sender);
        // mint cardid 0
        uint256 tokenId = subscription.mint(msg.sender, 0, 1);
        userCardId[msg.sender] = tokenId;
        emit PayActiveSubscription(msg.sender, _activeSubscriptionPayment, tokenId);
    }

    /**
     * @dev Set active subscription payment
     * @param amount New active subscription payment
     */
    function setActiveSubscriptionPayment(uint256 amount) public onlyRole(ADMIN_ROLE) {
        require(amount <= _MAX_ACTIVE_SUBSCRIPTION_PAYMENT, "AM: invalid amount");
        activeSubscriptionPayment = amount;
        emit SetActiveSubscriptionPayment(amount);
    }

    /**
     * @dev Sets the wallet address for receiving funds
     * @param fundReceiver_ New fund receiver address
     */
    function setFundReceiver(address fundReceiver_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(fundReceiver_ != address(0), "AM: zero address");
        _fundReceiver = fundReceiver_;
        emit SetFundReceiver(fundReceiver_);
    }

    /**
     * @dev Internal function to activate subscription
     */
    function _activateSubscription(address user) internal {
        activeSubscription[user] = true;
    }
    
    /**
     * @dev Withdraws Token from the contract to the wallet address
     * @notice Can only withdraw after the refund window has been opened and closed
     * @param token Address of token to withdraw (address(0) for native token)
     * @param amount Amount to withdraw
     */
    function withdrawToken(address token, uint256 amount) public nonReentrant onlyRole(ADMIN_ROLE) {
        require(_fundReceiver != address(0), "AM: fund receiver is not set");
        uint256 _startTime = refundWindow.startTime;
        uint256 _endTime = refundWindow.endTime;
        require(_startTime > 0, "AM: refund window never set");
        require(_endTime > 0 && block.timestamp > _endTime && _endTime > _startTime, "AM: refund window not closed");
        address to = _fundReceiver;

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
        require(receiver_ != address(0), "AM: zero address");
        receiver = receiver_;
        emit SetReceiver(receiver_);
    }

    /**
     * @dev Sets the AISubscription contract address
     * @param subscriptionAddr_ New AISubscription contract address
     */
    function setSubscriptionService(address subscriptionAddr_) public onlyRole(ADMIN_ROLE) {
        require(address(subscription) == address(0), "AM: already set");
        _setSubscriptionService(subscriptionAddr_);
    }

    /**
     * @dev Transfers ownership of the contract to a new owner
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOwner != address(0), "AM: zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Authorizes or revokes admin role for a specific address
     * @param admin Address to authorize or revoke
     * @param isAuthorized Boolean indicating whether to authorize or revoke
     */
    function authorizeAdmin(address admin, bool isAuthorized) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(admin != address(0), "AM: zero address");
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
    function refundSubscription(uint256 tokenId_) public nonReentrant whenNotPaused returns (uint256) {
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
            uint256 precisionFactor = 1e18;
            uint256 rateWithPrecision = rate * precisionFactor;
            uint256 reduction = (holdingDays * refundPolicy.decreaseRate * precisionFactor) / 100;
            if (reduction >= rateWithPrecision) {
                return refundPolicy.minRefundRate;
            }
            rateWithPrecision = rateWithPrecision - reduction;
            rate = rateWithPrecision / precisionFactor;
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
        require(baseRefundRate <= _MAX_REFUND_RATE, "AM: invalid base refund rate");
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
        if (refundPolicy.windowDuration > 0) {
            uint256 windowEnd = purchaseTime + refundPolicy.windowDuration;
            if (block.timestamp > windowEnd) {
                reason = "Max holding time exceeded";
                return (eligible, refundAmount, timeLeft, reason);
            }
            // Calculate remaining time in refund window
            timeLeft = windowEnd - block.timestamp;
        } else {
            timeLeft = type(uint256).max; // no time limit
        }
        
        // cool down period
        if (block.timestamp <= lastRefundTime[msg.sender] + refundPolicy.cooldownPeriod) {
            reason = "In cooldown period";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
        // Get card ID and price
        uint256 cardId = subscription.getCardIdByTokenId(tokenId_);
        uint256 originalPrice = getCardPrice(cardId);
        
        // Calculate refund amount
        uint256 holdingDays = (block.timestamp - purchaseTime) / 1 days;
        uint256 refundRate = calculateRefundRate(holdingDays);
        refundAmount = (originalPrice * refundRate) / 100;
        
        // Check if user has already refunded once
        if (lastRefundTime[owner_] != 0) {
            reason = "Already used one-time refund chance";
            return (eligible, refundAmount, timeLeft, reason);
        }
        
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
     * @notice Once set, endTime can only be decreased, not increased
     */
    function setRefundWindow(
        uint256 startTime_,
        uint256 endTime_
    ) public onlyRole(ADMIN_ROLE) {
        require(startTime_ < endTime_ || (startTime_ == 0 && endTime_ == 0), "AM: invalid time window");
        
        // If refund window was already set, endTime can only be decreased
        if (refundWindow.endTime > 0 && endTime_ > 0) {
            require(endTime_ <= refundWindow.endTime, "AM: end time can only be decreased");
        }
        
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
     * @dev Pauses all token operations
     */
    function pause() public onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token operations
     */
    function unpause() public onlyRole(ADMIN_ROLE) {
        _unpause();
    }


    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev Fallback function to receive ETH
     */
    receive() external payable {}

    /**
    * @dev Gap
    */
    uint256[50] private __gap;
}
