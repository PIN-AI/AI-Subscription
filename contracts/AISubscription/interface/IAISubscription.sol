// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IAISubscription {
    /**
     * @dev Returns card information for a given card ID
     * @param cardId Card ID to query
     * @return Card information (cardId, currentAmount, level, price, tokenURI)
     */
    function cardInfoes(
        uint256 cardId
    ) external view returns (uint256, uint256, uint256, uint256, string memory);

    /**
     * @dev Maps token ID to card ID
     * @param tokenId Token ID to query
     * @return Card ID
     */
    function cardIdMap(uint256 tokenId) external view returns (uint256);

    /**
     * @dev Returns the current token ID
     */
    function getNowTokenId() external view returns (uint256);

    /**
     * @dev Mints new subscription records to the specified address
     * @param to Address to receive the subscription
     * @param cardId ID of the card to mint
     * @param amount Number of subscriptions to mint
     * @return tokenId
     */
    function mint(address to, uint256 cardId, uint256 amount) external returns (uint256 tokenId);

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
    ) external;
    
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
    ) external;

    /**
     * @dev Upgrades a subscription to a higher level card
     * @param tokenId ID of the token to upgrade
     * @param toCardId ID of the card to upgrade to
     * @return bool indicating successful operation
     */
    function upgrade(uint256 tokenId, uint256 toCardId) external returns (bool);
    
    /**
     * @dev Gets the owner of a subscription token
     * @param tokenId Token ID to query
     * @return Address of the token owner
     */
    function ownerOf(uint256 tokenId) external view returns (address);

    /**
     * @dev Gets the card ID associated with a token ID
     * @param tokenId Token ID to query
     * @return Card ID associated with the token
     */
    function getCardIdByTokenId(uint256 tokenId) external view returns (uint256);
    
    /**
     * @dev Returns all tokens owned by the specified address
     * @param addr_ Address to query tokens for
     * @return _TokenIds Array of token IDs
     * @return _CardIds Array of card IDs corresponding to token IDs
     */
    function tokenOfOwnerForAll(
        address addr_
    ) external view returns (uint256[] memory _TokenIds, uint256[] memory _CardIds);

    /**
     * @dev Returns the number of tokens owned by an address
     * @param owner Address to check balance for
     * @return uint256 token balance
     */
    function balanceOf(address owner) external view returns (uint256);
    
    /**
     * @dev Burns a token, permanently removing it from circulation
     * @param tokenId_ ID of the token to burn
     */
    function burn(uint256 tokenId_) external;
}

interface IMA {
    function characters(
        uint256 tokenId
    ) external view returns (uint256 quality, uint256 level, uint256 score);
}
