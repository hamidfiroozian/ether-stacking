// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// import "./interfaces/IMarket.sol";
import "./../Yieldly.sol";

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract IMediaModified {
    mapping(uint256 => address) public tokenCreators;
    address public marketContract;
}

interface IWMATIC {
    function deposit() external payable;

    function transfer(address to, uint256 value) external returns (bool);
}

contract YieldlyMarketplace is ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    // Use OpenZeppelin's SafeMath library to prevent overflows.
    using SafeMath for uint256;

    // ============ Constants ============

    // The minimum amount of time left in an auction after a new bid is created; 15 min.
    uint16 public constant TIME_BUFFER = 900;
    // The MATIC needed above the current bid for a new bid to be valid; 0.001 MATIC.
    uint8 public constant MIN_BID_INCREMENT_PERCENT = 10;
    // Interface constant for ERC721, to check values in constructor.
    bytes4 private constant ERC721_INTERFACE_ID = 0x80ac58cd;
    // Allows external read `getVersion()` to return a version for the auction.
    uint256 private constant RESERVE_AUCTION_VERSION = 1;

    // ============ Immutable Storage ============

    // The address of the ERC721 contract for tokens auctioned via this contract.
    // address public immutable nftContract;
    // The address of the WMATIC contract, so that MATIC can be transferred via
    // WMATIC if native MATIC transfers fail.
    address public immutable WMATICAddress;
    // The address that initially is able to recover assets.
    address public immutable adminRecoveryAddress;

    // team addresses
    mapping(address => bool) private whitelistMap;

    bool private _adminRecoveryEnabled;

    bool private _paused;

    mapping(uint256 => MerketItem) public marketItems;

    mapping(uint256 => uint256) public getTokenId;
    // mapping(uint => uint256) public price;
    // mapping(uint256 => bool) public listedMap;
    // A mapping of all of the auctions currently running.
    mapping(uint256 => Auction) public auctions;
    // mapping(uint256 => address) public creatorMap;
    // mapping(uint256 => uint256) public royaltyMap;
    // mapping(uint256 => address) public ownerMap;

    // ============ Structs ============

    struct MerketItem {
        uint256 price;
        uint256 royaltyMap;
        address creatorMap;
        address ownerMap;
        bool listedMap;
    }

    struct Auction {
        // The value of the current highest bid.
        uint256 amount;
        // The amount of time that the auction should run for,
        // after the first bid was made.
        uint256 duration;
        // The time of the first bid.
        uint256 firstBidTime;
        // The minimum price of the first bid.
        uint256 reservePrice;
        uint8 CreatorFeePercent;
        // The address of the auction's Creator. The Creator
        // can cancel the auction if it hasn't had a bid yet.
        address Creator;
        // The address of the current highest bid.
        address payable bidder;
        // The address that should receive funds once the NFT is sold.
        address payable fundsRecipient;
    }

    // ============ Events ============

    // All of the details of a new auction,
    // with an index created for the tokenId.
    event AuctionCreated(
        uint256 indexed tokenId,
        uint256 auctionStart,
        uint256 duration,
        uint256 reservePrice,
        address Creator
    );

    // All of the details of a new bid,
    // with an index created for the tokenId.
    event AuctionBid(
        uint256 indexed tokenId,
        address nftContractAddress,
        address sender,
        uint256 value,
        uint256 duration
    );

    // All of the details of an auction's cancelation,
    // with an index created for the tokenId.
    event AuctionCanceled(
        uint256 indexed tokenId,
        address nftContractAddress,
        address Creator
    );

    // All of the details of an auction's close,
    // with an index created for the tokenId.
    event AuctionEnded(
        uint256 indexed tokenId,
        address nftContractAddress,
        address Creator,
        address winner,
        uint256 amount,
        address nftCreator
    );

    // When the Creator recevies fees, emit the details including the amount,
    // with an index created for the tokenId.
    event CreatorFeePercentTransfer(
        uint256 indexed tokenId,
        address Creator,
        uint256 amount
    );

    // Emitted in the case that the contract is paused.
    event Paused(address account);
    // Emitted when the contract is unpaused.
    event Unpaused(address account);
    event Purchase(
        address indexed previousOwner,
        address indexed newOwner,
        uint256 price,
        uint256 nftID
    );
    event Minted(
        address indexed minter,
        uint256 price,
        uint256 nftID,
        string uri,
        bool status
    );
    event Burned(uint256 nftID);
    event PriceUpdate(
        address indexed owner,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 nftID
    );
    event NftListStatus(address indexed owner, uint256 nftID, bool isListed);
    event Withdrawn(uint256 amount, address wallet);
    event TokensWithdrawn(uint256 amount, address wallet);
    event Received(address, uint256);
    event WhitelistAddress(address updatedAddress);
    event UnwhitelistAddress(address updatedAddress);

    // ============ Modifiers ============

    // Reverts if the sender is not admin, or admin
    // functionality has been turned off.
    modifier onlyAdminRecovery() {
        require(
            // The sender must be the admin address, and
            // adminRecovery must be set to true.
            adminRecoveryAddress == msg.sender && adminRecoveryEnabled(),
            "Caller does not have admin privileges"
        );
        _;
    }

    // Reverts if the sender is not the auction's Creator.
    modifier onlyCreator(uint256 tokenId) {
        require(
            auctions[tokenId].Creator == msg.sender,
            "Can only be called by auction Creator"
        );
        _;
    }

    // Reverts if the sender is not the auction's Creator or winner.
    modifier onlyCreatorOrWinner(uint256 tokenId) {
        require(
            auctions[tokenId].Creator == msg.sender ||
                auctions[tokenId].bidder == msg.sender,
            "Can only be called by auction Creator"
        );
        _;
    }

    // Reverts if the contract is paused.
    modifier whenNotPaused() {
        require(!paused(), "Contract is paused");
        _;
    }

    // Reverts if the auction does not exist.
    modifier auctionExists(uint256 tokenId) {
        // The auction exists if the Creator is not null.
        require(!auctionCreatorIsNull(tokenId), "Auction doesn't exist");
        _;
    }

    // Reverts if the auction exists.
    modifier auctionNonExistant(uint256 tokenId) {
        // The auction does not exist if the Creator is null.
        require(auctionCreatorIsNull(tokenId), "Auction already exists");
        _;
    }

    // Reverts if the auction is expired.
    modifier auctionNotExpired(uint256 tokenId) {
        require(
            // Auction is not expired if there's never been a bid, or if the
            // current time is less than the time at which the auction ends.
            auctions[tokenId].firstBidTime == 0 ||
                block.timestamp < auctionEnds(tokenId),
            "Auction expired"
        );
        _;
    }

    // Reverts if the auction is not complete.
    // Auction is complete if there was a bid, and the time has run out.
    modifier auctionComplete(uint256 tokenId) {
        require(
            // Auction is complete if there has been a bid, and the current time
            // is greater than the auction's end time.
            auctions[tokenId].firstBidTime > 0 &&
                block.timestamp >= auctionEnds(tokenId),
            "Auction hasn't completed"
        );
        _;
    }

    // ============ Constructor ============

    constructor(
        address WMATICAddress_,
        address adminRecoveryAddress_
    ) {
        // require(address(0) != nftContract_, "Zero Address Validation");
        require(address(0) != WMATICAddress_, "Zero Address Validation");
        require(address(0) != adminRecoveryAddress_, "Zero Address Validation");

        // Initialize immutable memory.
        // nftContract = nftContract_;
        WMATICAddress = WMATICAddress_;
        adminRecoveryAddress = adminRecoveryAddress_;
        // Initialize mutable memory.
        _paused = false;
        _adminRecoveryEnabled = true;

        whitelistMap[0x38805f12a7a1eA7EE84047994Ed52f1855E23797] = true;
        whitelistMap[0xd683eb2F7214Ef5a86A1815Ad431410ddD45BAbb] = true;
    }

    function addCreatorMap(
        bool _isNew,
        uint256[] memory _newtokenIds,
        address[] memory _creators,
        uint256[] memory _prices,
        address[] memory _owners,
        uint256[] memory _royalties,
        bool[] memory _listedMap
    ) external onlyOwner {
        require(
            _newtokenIds.length == _creators.length,
            "tokenIDs and creators are not mismatched"
        );
        require(
            _newtokenIds.length == _prices.length,
            "tokenIDs and _prices are not mismatched"
        );
        require(
            _newtokenIds.length == _owners.length,
            "tokenIDs and _owners are not mismatched"
        );
        require(
            _newtokenIds.length == _royalties.length,
            "tokenIDs and _royalties are not mismatched"
        );
        require(
            _newtokenIds.length == _listedMap.length,
            "tokenIDs and _listedMap are not mismatched"
        );

        if (_isNew) _tokenIds.reset();
        for (uint256 i = 0; i < _newtokenIds.length; i++) {
            _tokenIds.increment();
            marketItems[_newtokenIds[i]].creatorMap = _creators[i];
            marketItems[_newtokenIds[i]].price = _prices[i];
            marketItems[_newtokenIds[i]].ownerMap = _owners[i];
            marketItems[_newtokenIds[i]].royaltyMap = _royalties[i];
            marketItems[_newtokenIds[i]].listedMap = _listedMap[i];
        }
    }

    function openTrade(
        address nftContract,
        uint256 _id,
        uint256 _price
    ) public {
        require(marketItems[_id].ownerMap == msg.sender, "sender is not owner");
        require(marketItems[_id].listedMap == false, "Already opened");
        Yieldly(nftContract).approve(address(this), _id);
        Yieldly(nftContract).transferFrom(msg.sender, address(this), _id);
        marketItems[_id].listedMap = true;
        marketItems[_id].price = _price;
    }

    function closeTrade(address nftContract, uint256 _id) public {
        require(marketItems[_id].ownerMap == msg.sender, "sender is not owner");
        require(marketItems[_id].listedMap == true, "Already colsed");
        Yieldly(nftContract).transferFrom(address(this), msg.sender, _id);
        marketItems[_id].listedMap = false;
    }

    function buy(address nftContract, uint256[] memory _ids) external payable {
        for (uint256 i = 0; i < _ids.length; i++) {
            _validate(nftContract, _ids[i]);
            address _previousOwner = marketItems[_ids[i]].ownerMap;
            address _newOwner = msg.sender;

            // 2.5% commission cut
            uint256 _commissionValue = marketItems[_ids[i]].price.mul(25).div(
                1000
            );
            uint256 _royaltyValue = marketItems[_ids[i]]
                .price
                .mul(marketItems[_ids[i]].royaltyMap)
                .div(100);
            uint256 _sellerValue = marketItems[_ids[i]].price.sub(
                _commissionValue + _royaltyValue
            );
            // _owner.transfer(_owner, _sellerValue);
            transferMATICOrWMATIC(payable(_previousOwner), _sellerValue);
            transferMATICOrWMATIC(
                payable(marketItems[_ids[i]].creatorMap),
                _royaltyValue
            );
            transferMATICOrWMATIC(
                payable(adminRecoveryAddress),
                _commissionValue
            );
            Yieldly(nftContract).transferFrom(
                address(this),
                _newOwner,
                _ids[i]
            );
            marketItems[_ids[i]].ownerMap = msg.sender;
            marketItems[_ids[i]].listedMap = false;
            emit Purchase(
                _previousOwner,
                _newOwner,
                marketItems[_ids[i]].price,
                _ids[i]
            );
        }
    }

    function _validate(address nftContract, uint256 _id) internal view {
        bool isItemListed = marketItems[_id].listedMap;
        require(marketItems[_id].price != 0, "Item is not minted yet");
        require(isItemListed, "Item not listed currently");
        require(
            msg.sender != Yieldly(nftContract).ownerOf(_id),
            "Can not buy what you own"
        );
        // require(auctions[_id].amount != 0 , "Can not buy auction item");
        // require(address(msg.sender).balance >= price[_id], "Error, the amount is lower");
    }

    function isWhitelisted(address _address) public view returns (bool) {
        return whitelistMap[_address];
    }

    function _unWhitelist(address[] memory _removedAddresses)
        public
        onlyAdminRecovery
    {
        for (uint256 i = 0; i < _removedAddresses.length; i++) {
            whitelistMap[_removedAddresses[i]] = false;
            emit UnwhitelistAddress(_removedAddresses[i]);
        }
    }

    function _whitelist(address[] memory _newAddresses)
        public
        onlyAdminRecovery
    {
        for (uint256 i = 0; i < _newAddresses.length; i++) {
            whitelistMap[_newAddresses[i]] = true;
            emit WhitelistAddress(_newAddresses[i]);
        }
    }

    // function isTeamAddress(address mintAddress) internal view returns (bool) {
    //     uint i;
    //     for (i = 0; i < adminAddresses.length; i ++)  {
    //         if (adminAddresses[i] == mintAddress) break;
    //     }
    //     if (i == adminAddresses.length) return false;
    //     else return true;
    // }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }

    function updatePrice(uint256 _tokenId, uint256 _price)
        public
        returns (bool)
    {
        uint256 oldPrice = marketItems[_tokenId].price;
        require(
            msg.sender == marketItems[_tokenId].ownerMap,
            "Error, you are not the owner"
        );
        marketItems[_tokenId].price = _price;

        emit PriceUpdate(msg.sender, oldPrice, _price, _tokenId);
        return true;
    }

    function updateListingStatus(
        address nftContract,
        uint256 _tokenId,
        bool shouldBeListed
    ) public returns (bool) {
        require(
            msg.sender == Yieldly(nftContract).ownerOf(_tokenId),
            "Error, you are not the owner"
        );

        marketItems[_tokenId].listedMap = shouldBeListed;

        emit NftListStatus(msg.sender, _tokenId, shouldBeListed);

        return true;
    }

    // ============ Create Auction ============

    function createAuction(
        uint256 tokenId,
        uint256 startDate,
        uint256 duration,
        uint256 reservePrice,
        address nftContract
    ) public nonReentrant whenNotPaused auctionNonExistant(tokenId) {
        // Check basic input requirements are reasonable.
        require(msg.sender != address(0));
        // Initialize the auction details, including null values.

        // if (_isNew) {
        //     _tokenIds.increment();
        //     uint256 newTokenId = _tokenIds.current();
        //     tokenId = newTokenId;
        //     price[tokenId] = reservePrice;
        //     creatorMap[tokenId] = Creator;
        //     Yieldly(nftContract).mint(tokenId, msg.sender, _tokenUri);
        // }
        marketItems[tokenId].ownerMap = msg.sender;
        openTrade(nftContract, tokenId, reservePrice);

        // uint256 auctionStart = block.timestamp;
        require(
            startDate >= block.timestamp,
            "Can't create auction in the past!"
        );
        auctions[tokenId] = Auction({
            duration: duration,
            reservePrice: reservePrice,
            CreatorFeePercent: 50,
            Creator: msg.sender,
            fundsRecipient: payable(adminRecoveryAddress),
            amount: 0,
            firstBidTime: startDate,
            bidder: payable(address(0))
        });

        // Transfer the NFT into this auction contract, from whoever owns it.

        // Emit an event describing the new auction.
        emit AuctionCreated(
            tokenId,
            startDate,
            duration,
            reservePrice,
            msg.sender
        );
    }

    // ============ Create Bid ============

    function createBid(
        address nftContract,
        uint256 tokenId,
        uint256 amount
    )
        external
        payable
        nonReentrant
        whenNotPaused
        auctionExists(tokenId)
        auctionNotExpired(tokenId)
    {
        // Validate that the user's expected bid value matches the MATIC deposit.
        require(amount == msg.value, "Amount doesn't equal msg.value");
        require(amount > 0, "Amount must be greater than 0");
        require(
            auctions[tokenId].firstBidTime <= block.timestamp,
            "Auction is not yet started"
        );
        // Check if the current bid amount is 0.
        if (auctions[tokenId].amount == 0) {
            // If so, it is the first bid.
            auctions[tokenId].firstBidTime = block.timestamp;
            // We only need to check if the bid matches reserve bid for the first bid,
            // since future checks will need to be higher than any previous bid.
            require(
                amount >= auctions[tokenId].reservePrice,
                "Must bid reservePrice or more"
            );
        } else {
            // Check that the new bid is sufficiently higher than the previous bid, by
            // the percentage defined as MIN_BID_INCREMENT_PERCENT.
            require(
                amount >=
                    auctions[tokenId].amount.add(
                        // Add 10% of the current bid to the current bid.
                        auctions[tokenId]
                            .amount
                            .mul(MIN_BID_INCREMENT_PERCENT)
                            .div(100)
                    ),
                "Must bid more than last bid by MIN_BID_INCREMENT_PERCENT amount"
            );

            // Refund the previous bidder.
            transferMATICOrWMATIC(
                auctions[tokenId].bidder,
                auctions[tokenId].amount
            );
        }
        // Update the current auction.
        auctions[tokenId].amount = amount;
        auctions[tokenId].bidder = payable(msg.sender);
        // Compare the auction's end time with the current time plus the 15 minute extension,
        // to see whMATICer we're near the auctions end and should extend the auction.
        if (auctionEnds(tokenId) < block.timestamp.add(TIME_BUFFER)) {
            // We add onto the duration whenever time increment is required, so
            // that the auctionEnds at the current time plus the buffer.
            auctions[tokenId].duration += block.timestamp.add(TIME_BUFFER).sub(
                auctionEnds(tokenId)
            );
        }
        // Emit the event that a bid has been made.
        emit AuctionBid(
            tokenId,
            nftContract,
            msg.sender,
            amount,
            auctions[tokenId].duration
        );
    }

    // ============ End Auction ============

    function endAuction(address nftContract, uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
        auctionComplete(tokenId)
        onlyCreatorOrWinner(tokenId)
    {
        // Store relevant auction data in memory for the life of this function.
        address winner = auctions[tokenId].bidder;
        uint256 amount = auctions[tokenId].amount;
        address Creator = auctions[tokenId].Creator;
        // Remove all auction data for this token from storage.
        delete auctions[tokenId];
        // We don't use safeTransferFrom, to prevent reverts at this point,
        // which would break the auction.
        if (winner == address(0)) {
            Yieldly(nftContract).transferFrom(address(this), Creator, tokenId);
            marketItems[tokenId].ownerMap = Creator;
        } else {
            Yieldly(nftContract).transferFrom(address(this), winner, tokenId);
            uint256 _commissionValue = amount.mul(25).div(1000);
            transferMATICOrWMATIC(
                payable(adminRecoveryAddress),
                _commissionValue
            );
            if (Creator == marketItems[tokenId].creatorMap) {
                transferMATICOrWMATIC(
                    payable(Creator),
                    amount.sub(_commissionValue)
                );
            } else {
                uint256 _royaltyValue = amount
                    .mul(marketItems[tokenId].royaltyMap)
                    .div(100);
                transferMATICOrWMATIC(
                    payable(marketItems[tokenId].creatorMap),
                    _royaltyValue
                );
                transferMATICOrWMATIC(
                    payable(Creator),
                    amount.sub(_royaltyValue).sub(_commissionValue)
                );
            }
            marketItems[tokenId].ownerMap = winner;
        }
        marketItems[tokenId].listedMap = false;
        // Emit an event describing the end of the auction.
        emit AuctionEnded(
            tokenId,
            nftContract,
            Creator,
            winner,
            amount,
            marketItems[tokenId].creatorMap
        );
    }

    // ============ Cancel Auction ============

    function cancelAuction(address nftContract, uint256 tokenId)
        external
        nonReentrant
        auctionExists(tokenId)
        onlyCreator(tokenId)
    {
        // Check that there hasn't already been a bid for this NFT.
        require(
            uint256(auctions[tokenId].amount) == 0,
            "Auction already started"
        );
        // Pull the creator address before removing the auction.
        address Creator = auctions[tokenId].Creator;
        // Remove all data about the auction.
        delete auctions[tokenId];
        // Transfer the NFT back to the Creator.
        Yieldly(nftContract).transferFrom(address(this), Creator, tokenId);
        marketItems[tokenId].listedMap = false;
        marketItems[tokenId].ownerMap = Creator;
        // Emit an event describing that the auction has been canceled.
        emit AuctionCanceled(tokenId, nftContract, Creator);
    }

    function mint(
        address nftContract,
        string memory _tokenURI,
        uint256 _price,
        bool _isListOnMarketplace,
        uint256 _royalty
    ) public {
        require(!_paused, "Can't mint on the paused status");
        require(isWhitelisted(msg.sender), "Not whitelisted");
        require(
            IERC721(nftContract).supportsInterface(ERC721_INTERFACE_ID),
            "Contract at nftContract_ address does not support NFT interface"
        );
        _tokenIds.increment();

        uint256 newTokenId = _tokenIds.current();
        marketItems[newTokenId].price = _price;
        marketItems[newTokenId].royaltyMap = _royalty;
        marketItems[newTokenId].creatorMap = msg.sender;
        marketItems[newTokenId].ownerMap = msg.sender;
        marketItems[newTokenId].listedMap = false;

        // require (msg.value >= price[newTokenId], "msg.value should be equal to the buyAmount");

        Yieldly(nftContract).mint(newTokenId, msg.sender, _tokenURI);

        emit Minted(
            msg.sender,
            _price,
            newTokenId,
            _tokenURI,
            _isListOnMarketplace
        );

        openTrade(nftContract, newTokenId, _price);
    }

    // ============ Admin Functions ============

    // Irrevocably turns off admin recovery.
    function turnOffAdminRecovery() external onlyAdminRecovery {
        _adminRecoveryEnabled = false;
    }

    function pauseContract() external onlyAdminRecovery {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpauseContract() external onlyAdminRecovery {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // Allows the admin to transfer any NFT from this contract
    // to the recovery address.
    // function recoverNFT(uint256 tokenId) external onlyAdminRecovery {
    //     Yieldly(nftContract).transferFrom(
    //         // From the auction contract.
    //         address(this),
    //         // To the recovery account.
    //         adminRecoveryAddress,
    //         // For the specified token.
    //         tokenId
    //     );
    // }

    // Allows the admin to transfer any MATIC from this contract to the recovery address.
    function recoverMATIC(uint256 amount)
        external
        onlyAdminRecovery
        returns (bool success)
    {
        // Attempt an MATIC transfer to the recovery account, and return true if it succeeds.
        success = attemptMATICTransfer(payable(adminRecoveryAddress), amount);
    }

    // ============ Miscellaneous Public and External ============

    // Returns true if the contract is paused.
    function paused() public view returns (bool) {
        return _paused;
    }

    // Returns true if admin recovery is enabled.
    function adminRecoveryEnabled() public view returns (bool) {
        return _adminRecoveryEnabled;
    }

    // Returns the version of the deployed contract.
    function getVersion() external pure returns (uint256 version) {
        version = RESERVE_AUCTION_VERSION;
    }

    // ============ Private Functions ============

    // Will attempt to transfer MATIC, but will transfer WMATIC instead if it fails.
    function transferMATICOrWMATIC(address payable to, uint256 value) private {
        // Try to transfer MATIC to the given recipient.
        if (!attemptMATICTransfer(to, value)) {
            // If the transfer fails, wrap and send as WMATIC, so that
            // the auction is not impeded and the recipient still
            // can claim MATIC via the WMATIC contract (similar to escrow).
            IWMATIC(WMATICAddress).deposit{value: value}();
            IWMATIC(WMATICAddress).transfer(to, value);
            // At this point, the recipient can unwrap WMATIC.
        }
    }

    // Sending MATIC is not guaranteed complete, and the mMATICod used here will return false if
    // it fails. For example, a contract can block MATIC transfer, or might use
    // an excessive amount of gas, thereby griefing a new bidder.
    // We should limit the gas used in transfers, and handle failure cases.
    function attemptMATICTransfer(address payable to, uint256 value)
        private
        returns (bool)
    {
        // Here increase the gas limit a reasonable amount above the default, and try
        // to send MATIC to the recipient.
        // NOTE: This might allow the recipient to attempt a limited reentrancy attack.
        (bool success, ) = to.call{value: value, gas: 30000}("");
        return success;
    }

    // Returns true if the auction's Creator is set to the null address.
    function auctionCreatorIsNull(uint256 tokenId) private view returns (bool) {
        // The auction does not exist if the Creator is the null address,
        // since the NFT would not have been transferred in `createAuction`.
        return auctions[tokenId].Creator == address(0);
    }

    // Returns the timestamp at which an auction will finish.
    function auctionEnds(uint256 tokenId) private view returns (uint256) {
        // Derived by adding the auction's duration to the time of the first bid.
        // NOTE: duration can be extended conditionally after each new bid is added.
        return auctions[tokenId].firstBidTime.add(auctions[tokenId].duration);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
