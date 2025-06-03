// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IAISubscriptionMarket {
    /** 
     * @dev Buy an Card with BNB
     * @param to Address to receive the tokens
     * @param cardId Card ID to purchase
     * @param uid UID to purchase
     * @param signature Signature of the buy request
     */ 
    function buy(address to, uint256 cardId, uint256 uid, bytes memory signature) external payable;


    /**
     * @dev Refund an NFT
     * @param tokenId Token ID to refund
     */
    function refund(uint256 tokenId) external;

    /**
     * @dev Withdraw BNB from the contract
     * @param to Address to receive the BNB
     * @param amount Amount of BNB to withdraw
     */
    function withdraw(address to, uint256 amount) external;


    /**
     * @dev Get the price of a specific card in BNB
     * @param cardId Card ID to query price for
     * @return Price of the card in BNB (wei)
     */
    function nftPrice(uint cardId) external view returns (uint);


    /**
     * @dev Get the total number of subscribers
     * @return Total number of subscribers
     */
    function totalSubscriber() external view returns (uint256);

    /**
     * @dev Get the number of BNB that user committed
     * @return Committed BNB
     */
    function totalCommitted() external view returns (uint256);


    /**
     * @dev Set the open sale time stamp
     * @param timestamp Timestamp of open sale
     */
    function setOpenSaleTimeStamp(uint256 timestamp) external;

    /**
     * @dev Get the open sale time stamp
     * @return Timestamp of open sale
     */
    function getOpenSaleTimeStamp() external view returns (uint256);

    /**
     * @dev Set the time stamp of TGE
     * @param timestamp Timestamp of TGE
     */
    function setTGETimeStamp(uint256 timestamp) external;

    /**
     * @dev Get the time stamp of TGE
     * @return Timestamp of TGE
     */
    function getTGETimeStamp() external view returns (uint256);

    
    /**
     * @dev Set the refundable time stamp
     * @param timestamp Timestamp of refundable
     */
    function setRefundableTimeStamp(uint256 timestamp) external;

    /**
     * @dev Get the refundable time stamp
     * @return Timestamp of refundable
     */
    function getRefundableTimeStamp() external view returns (uint256);

    /**
     * @dev Authorize an address to manage the contract
     * @param addr Address to authorize
     * @param authorized Boolean indicating if the address is authorized
     */
    function authorizeAdmin(address addr, bool authorized) external;
}

