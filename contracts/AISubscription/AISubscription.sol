// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAISubscription} from "./interface/IAISubscription.sol";

/**
 * @title AISubscription
 * @dev Implementation of the AISubscription with upgradeability features.
 * This contract manages AISubscription records with different card levels and upgrade capabilities.
 * Uses tokenId to track subscriptions but does not implement ERC721.
 */
contract AISubscription is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable, IAISubscription {
    /**
     * @dev Role definitions
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MARKET_ROLE = keccak256("MARKET_ROLE");

    /**
     * @dev Counter for token IDs
     */
    uint256 private _currentTokenId;

    /**
     * @dev Structure to store card information
     * @param cardId Unique identifier for the card
     * @param currentAmount Current amount of cards minted
     * @param level Level of the card
     * @param price Price of the card in ETH (in wei)
     */
    struct CardInfo {
        uint256 cardId;
        uint256 currentAmount;
        uint256 level;
        uint256 price;
        string tokenURI;
    }

    /**
     * @dev Mapping of token IDs to owners
     */
    mapping(uint256 => address) private _owners;
    
    /**
     * @dev Mapping of address to token count
     */
    mapping(address => uint256) private _balances;
    
    /**
     * @dev Mapping of address to list of owned tokens
     */
    mapping(address => mapping(uint256 => uint256)) private _ownedTokens;
    
    /**
     * @dev Mapping of token ID to index of the owner tokens list
     */
    mapping(uint256 => uint256) private _ownedTokensIndex;

    /**
     * @dev Mapping of token IDs to card IDs
     */
    mapping(uint256 => uint256) public cardIdMap;
    
    /**
     * @dev Mapping of card IDs to card information
     */
    mapping(uint256 => CardInfo) public cardInfoes;

    /**
     * @dev Emitted when a new card type is created
     */
    event NewCard(uint256 indexed cardId);
    
    /**
     * @dev Emitted when a card is updated
     */
    event CardUpdated(uint256 indexed cardId, uint256 level, uint256 price, string tokenURI);
    
    /**
     * @dev Emitted when a token is burned
     */
    event TokenBurned(uint256 indexed tokenId, uint256 indexed cardId);
    
    /**
     * @dev Emitted when a new token is minted
     */
    event Mint(address indexed user, uint256 indexed cardId, uint256 indexed tokenId);
    
    /**
     * @dev Emitted when a token is upgraded to a higher level card
     */
    event Upgrade(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed toCardId
    );

    /**
     * @dev Emitted when admin role is authorized or revoked
     */
    event AuthorizeAdmin(address indexed admin, bool isAuthorized);

    /**
     * @dev Emitted when market role is authorized or revoked
     */
    event AuthorizeMarket(address indexed market, bool isAuthorized);


    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract replacing the constructor for upgradeable contracts
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    function initialize(address owner_, address admin_, address market_) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        // Setup roles
        require(owner_ != address(0), "SUB: owner is the zero address");
        require(admin_ != address(0), "SUB: admin is the zero address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, admin_);
        if (market_ != address(0)) {
            _grantRole(MARKET_ROLE, market_);
        }
        
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
     * @dev Creates a new card type
     * @param cardId_ Unique identifier for the new card
     * @param level_ Level of the new card
     * @param price_ Price of the new card in ETH (wei)
     * @param tokenURI_ URI for the card metadata
     */
    function newCard(
        uint256 cardId_,
        uint256 level_,
        uint256 price_,
        string calldata tokenURI_
    ) public onlyRole(ADMIN_ROLE) {
        require(
            cardId_ != 0 && cardInfoes[cardId_].cardId == 0,
            "SUB: wrong cardId"
        );

        cardInfoes[cardId_] = CardInfo({
            cardId: cardId_,
            currentAmount: 0,
            level: level_,
            price: price_,
            tokenURI: tokenURI_
        });
        emit NewCard(cardId_);
    }
    
    /**
     * @dev Updates an existing card type
     * @param cardId_ Identifier of the card to update
     * @param level_ New level for the card
     * @param price_ New price for the card in ETH (wei)
     * @param tokenURI_ New URI for the card metadata
     */
    function updateCard(
        uint256 cardId_,
        uint256 level_,
        uint256 price_,
        string calldata tokenURI_
    ) public onlyRole(ADMIN_ROLE) {
        require(
            cardId_ != 0 && cardInfoes[cardId_].cardId != 0,
            "SUB: card not exist"
        );
        
        uint256 currentAmount = cardInfoes[cardId_].currentAmount;
        
        cardInfoes[cardId_] = CardInfo({
            cardId: cardId_,
            currentAmount: currentAmount,
            level: level_,
            price: price_,
            tokenURI: tokenURI_
        });
        
        emit CardUpdated(cardId_, level_, price_, tokenURI_);
    }

    /**
     * @dev Mints new subscription records to the specified address
     * @param to_ Address to receive the subscription
     * @param cardId_ ID of the card to mint
     * @param amount_ Number of subscriptions to mint
     * @return tokenId new token ID
     */
    function mint(
        address to_,
        uint256 cardId_,
        uint256 amount_
    ) public whenNotPaused override onlyRole(MARKET_ROLE) returns (uint256 tokenId) {
        require(to_ != address(0), "SUB: mint to the zero address");
        require(cardInfoes[cardId_].cardId != 0, "SUB: wrong cardId");

        for (uint256 i = 0; i < amount_; i++) {
            tokenId = getNextTokenId();
            cardIdMap[tokenId] = cardId_;
            cardInfoes[cardId_].currentAmount++;
            
            _mint(to_, tokenId);
            emit Mint(msg.sender, cardId_, tokenId);
        }
    }

    /**
     * @dev Upgrades a subscription to a higher level card
     * @param tokenId_ ID of the token to upgrade
     * @param toCardId_ ID of the card to upgrade to
     * @return bool indicating successful operation
     */
    function upgrade(uint256 tokenId_, uint256 toCardId_) public whenNotPaused onlyRole(MARKET_ROLE) returns (bool) {
        require(cardInfoes[toCardId_].cardId != 0, "SUB: wrong cardId");
        
        uint256 _oldCardId = cardIdMap[tokenId_];
        require(_oldCardId < toCardId_, "SUB: wrong lv");

        cardIdMap[tokenId_] = toCardId_;
        cardInfoes[_oldCardId].currentAmount -= 1;
        cardInfoes[toCardId_].currentAmount += 1;

        emit Upgrade(msg.sender, tokenId_, toCardId_);
        return true;
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Internal function to mint a new token
     * @param to Address to receive the token
     * @param tokenId ID of the token to mint
     */
    function _mint(address to, uint256 tokenId) internal virtual {
        require(to != address(0), "SUB: mint to the zero address");
        require(!exists(tokenId), "SUB: token already minted");

        _balances[to] += 1;
        _owners[tokenId] = to;
        
        uint256 length = _balances[to];
        _ownedTokens[to][length - 1] = tokenId;
        _ownedTokensIndex[tokenId] = length - 1;
    }


    /**
     * @dev Returns whether a token with the given ID exists
     * @param tokenId ID of the token
     * @return bool whether the token exists
     */
    function exists(uint256 tokenId) public view returns (bool) {
        return _owners[tokenId] != address(0);
    }

        /**
     * @dev Returns the current token ID
     * @return uint256 Current token ID
     */
    function getNowTokenId() public view returns (uint256) {
        return _currentTokenId;
    }

    /**
     * @dev Increments and returns the next token ID
     * @return uint256 Next token ID
     */
    function getNextTokenId() internal returns (uint256) {
        _currentTokenId += 1;
        return _currentTokenId;
    }

    /**
     * @dev Returns the owner of the token
     * @param tokenId ID of the token
     * @return address of the owner
     */
    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "SUB: nonexistent token");
        return owner;
    }

    /**
     * @dev Returns the number of tokens owned by an address
     * @param owner Address to check balance for
     * @return uint256 token balance
     */
    function balanceOf(address owner) public view returns (uint256) {
        require(owner != address(0), "SUB: balance query for the zero address");
        return _balances[owner];
    }

    /**
     * @dev Returns the token ID at a given index in the owner's token list
     * @param owner Address to query
     * @param index Index in the owner's token list
     * @return uint256 token ID
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) public view returns (uint256) {
        require(index < balanceOf(owner), "SUB: owner index out of bounds");
        return _ownedTokens[owner][index];
    }

    /**
     * @dev Gets the card ID associated with a token ID
     * @param tokenId Token ID to query
     * @return Card ID associated with the token
     */
    function getCardIdByTokenId(uint256 tokenId) public view returns (uint256) {
        return cardIdMap[tokenId];
    }

    /**
     * @dev Returns all tokens owned by the specified address
     * @param addr_ Address to query tokens for
     * @return _TokenIds Array of token IDs
     * @return _CardIds Array of card IDs corresponding to token IDs
     */
    function tokenOfOwnerForAll(
        address addr_
    ) public view returns (uint256[] memory _TokenIds, uint256[] memory _CardIds) {
        uint256 len = balanceOf(addr_);
        uint256 id;
        _TokenIds = new uint256[](len);
        _CardIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            id = tokenOfOwnerByIndex(addr_, i);
            _TokenIds[i] = id;
            _CardIds[i] = cardIdMap[id];
        }
    }

    /**
     * @dev Returns the card information for a given card ID
     * @param cardId Card ID to query
     * @return Card information (cardId, currentAmount, level, price, tokenURI)
     */
    function getCardInfo(uint256 cardId) public view returns (CardInfo memory) {
        return cardInfoes[cardId];
    }

    /**
     * @dev Authorizes or revokes admin role for a specific address
     * @param admin Address to authorize or revoke
     * @param isAuthorized Boolean indicating whether to authorize or revoke
     */
    function authorizeAdmin(address admin, bool isAuthorized) public onlyRole(ADMIN_ROLE) {
        if (isAuthorized) {
            _grantRole(ADMIN_ROLE, admin);
        } else {
            _revokeRole(ADMIN_ROLE, admin);
        }
        emit AuthorizeAdmin(admin, isAuthorized);
    }

    /**
     * @dev Authorizes or revokes market role for a specific address
     * @param market Address to authorize or revoke
     * @param isAuthorized Boolean indicating whether to authorize or revoke
     */
    function authorizeMarket(address market, bool isAuthorized) public onlyRole(ADMIN_ROLE) {
        if (isAuthorized) {
            _grantRole(MARKET_ROLE, market);
        } else {
            _revokeRole(MARKET_ROLE, market);
        }
        emit AuthorizeMarket(market, isAuthorized);
    }
    
    /**
     * @dev Burns a token, permanently removing it from circulation
     * @param tokenId_ ID of the token to burn
     */
    function burn(uint256 tokenId_) public whenNotPaused onlyRole(MARKET_ROLE) {
        // Verify token exists
        address owner = _owners[tokenId_];
        require(owner != address(0), "SUB: nonexistent token");
        
        // Get card ID associated with token
        uint256 cardId = cardIdMap[tokenId_];
        require(cardId != 0, "SUB: token not mapped");
        
        // Update card minted amount
        cardInfoes[cardId].currentAmount -= 1;
        
        // Clear owner's balance and token ownership
        _balances[owner] -= 1;
        
        // Move the last token to the position of deleted token and update index
        uint256 lastTokenIndex = _balances[owner];
        uint256 tokenIndex = _ownedTokensIndex[tokenId_];
        
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokens[owner][lastTokenIndex];
            _ownedTokens[owner][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        
        // Delete last token
        delete _ownedTokens[owner][lastTokenIndex];
        
        // Clear token data
        delete _owners[tokenId_];
        delete _ownedTokensIndex[tokenId_];
        delete cardIdMap[tokenId_];
        
        emit TokenBurned(tokenId_, cardId);
    }
}
