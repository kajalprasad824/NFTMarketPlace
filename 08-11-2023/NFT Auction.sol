// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface royalty {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address, uint256);
}

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract NFTAuction is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address payable;
    using SafeERC20 for IERC20;

    event AuctionCreated(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address payToken
    );

    event UpdateAuctionEndTime(
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 endTime
    );

    event UpdateAuctionStartTime(
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 startTime
    );

    event UpdateAuctionReservePrice(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address payToken,
        uint256 reservePrice
    );

    event UpdatePlatformFee(uint256 platformFee);

    event UpdatePlatformFeeRecipient(address payable platformFeeRecipient);

    event UpdateMinBidIncrement(uint256 minBidIncrement);

    event UpdateBidWithdrawalLockTime(uint256 bidWithdrawalLockTime);

    event BidPlaced(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 bid
    );

    event BidWithdrawn(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 bid
    );

    event BidRefunded(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address indexed bidder,
        uint256 bid
    );

    event AuctionResulted(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address indexed winner,
        address payToken,
        uint256 winningBid
    );

    event AuctionCancelled(address indexed nftAddress, uint256 indexed tokenId);
    event UpdateTokenRegistery(address registry);

    /// @notice Parameters of an auction
    struct Auction {
        address owner;
        address payToken;
        uint256 reservePrice;
        uint256 startTime;
        uint256 endTime;
        bool onAuction;
    }
    /// @notice ERC721 Address -> Token ID -> Auction Parameters
    mapping(address => mapping(uint256 => Auction)) public auctions;

    struct bidderInfo {
        uint256 highBid;
        address payable higherBidder;
        uint256 index;
        address[] bidderAddress;
        uint256[] bidAmount;
    }
    mapping(address => mapping(uint256 => bidderInfo)) public biddingInfo;

    struct buyerInfo {
        bool isBidder;
        uint256 bidTime;
        uint256 amount;
        uint256 index;
    }
    mapping(address => mapping(uint256 => mapping(address => buyerInfo)))
        public BuyerInfo;

    struct Escrow {
        address nft;
        address buyer;
        address payToken;
        uint256 amount;
        uint256 tokenID;
        bool exists;
    }

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    mapping(address => Escrow[]) public escrow;

    /// @notice globally and across all auctions, the amount by which a bid has to increase
    uint256 public minBidIncrement = 0.05 ether;

    /// @notice global bid withdrawal lock time
    uint256 public bidWithdrawalLockTime = 20 minutes;

    /// @notice global platform fee, assumed to always be to 1 decimal place i.e. 25 = 2.5%
    uint256 public platformFee;

    /// @notice where to send platform fee funds to
    address payable public platformFeeRecipient;

    /// @notice Token registry
    address public tokenRegistry;

    /// @notice Contract initializer
    constructor(
        address initialOwner,
        address _tokenRegistry,
        address payable _platformFeeRecipient,
        uint256 _platformFee
    ) Ownable(initialOwner) {
        require(
            _platformFeeRecipient != address(0),
            "Auction: Invalid Platform Fee Recipient"
        );

        require(
            _platformFee <= 1000,
            "Platform fee can not be greater than 10%"
        );

        platformFeeRecipient = _platformFeeRecipient;
        platformFee = _platformFee;
        tokenRegistry = _tokenRegistry;
    }

    /**
     @notice Creates a new auction for a given item
     @dev Only the owner of item can create an auction and must have approved the contract
     @dev In addition to owning the item, the sender also has to have the MINTER role.
     @dev End time for the auction must be in the future.
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the item being auctioned
     @param _payToken Paying token
     @param _reservePrice Item cannot be sold for less than this or minBidIncrement, whichever is higher
     @param _startTimestamp Unix epoch in seconds for the auction start time
     @param _endTimestamp Unix epoch in seconds for the auction end time.
     */
    function createAuction(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        uint256 _reservePrice,
        uint256 _startTimestamp,
        uint256 _endTimestamp
    ) public {
        // Ensure this contract is approved to move the token
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "item not approved"
            );
        } else {
            revert("invalid nft address");
        }

        require(
            _payToken == address(0) ||
                (tokenRegistry != address(0) &&
                    ITokenRegistry(tokenRegistry).enabled(_payToken)),
            "invalid pay token"
        );

        // Ensure a token cannot be re-listed if previously successfully sold
        require(
            !auctions[_nftAddress][_tokenId].onAuction,
            "auction already exist"
        );

        // Check end time not before start time and that end is in the future
        require(
            _startTimestamp > block.timestamp,
            "start time should be greater than current time"
        );

        require(
            _endTimestamp > _startTimestamp,
            "end time must be greater than start"
        );

        // Setup the auction
        auctions[_nftAddress][_tokenId] = Auction({
            owner: _msgSender(),
            payToken: _payToken,
            reservePrice: _reservePrice,
            startTime: _startTimestamp,
            endTime: _endTimestamp,
            onAuction: true
        });

        emit AuctionCreated(_nftAddress, _tokenId, _payToken);
    }

    /**
     @notice Places a new bid, out bidding the existing bidder if found and criteria is reached
     @dev Only callable when the auction is open
     @dev Bids from smart contracts are prohibited to prevent griefing with always reverting receiver
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the item being auctioned
     */
    function placeBid(address _nftAddress, uint256 _tokenId)
        external
        payable
        nonReentrant
    {
        // require(
        //     payable(_msgSender()).isContract() == false,
        //     "no contracts permitted"
        // );

        // Check the auction to see if this is a valid bid
        Auction memory auction = auctions[_nftAddress][_tokenId];

        // Ensure auction is in flight
        require(
            block.timestamp >= auction.startTime &&
                block.timestamp <= auction.endTime,
            "bidding outside of the auction window"
        );
        require(auction.payToken == address(0), "invalid pay token");

        _placeBid(_nftAddress, _tokenId, msg.value);
    }

    /**
     @notice Places a new bid, out bidding the existing bidder if found and criteria is reached
     @dev Only callable when the auction is open
     @dev Bids from smart contracts are prohibited to prevent griefing with always reverting receiver
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the item being auctioned
     @param _bidAmount Bid amount
     */
    function placeBidWithERC20(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _bidAmount
    ) external nonReentrant {
        // require(
        //     payable(_msgSender()).isContract() == false,
        //     "no contracts permitted"
        // );

        // Check the auction to see if this is a valid bid
        Auction memory auction = auctions[_nftAddress][_tokenId];

        // Ensure auction is in flight
        require(
            block.timestamp >= auction.startTime &&
                block.timestamp <= auction.endTime,
            "bidding outside of the auction window"
        );

        _placeBid(_nftAddress, _tokenId, _bidAmount);
    }

    function _placeBid(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _bidAmount
    ) internal {
        Auction storage auction = auctions[_nftAddress][_tokenId];

        bidderInfo storage bidderinfo = biddingInfo[_nftAddress][_tokenId];

        uint256 minBidRequired = bidderinfo.highBid.add(minBidIncrement);

        require(
            _bidAmount >= minBidRequired,
            "failed to outbid highest bidder"
        );

        require(
            !BuyerInfo[_nftAddress][_tokenId][msg.sender].isBidder,
            "You already bid for this nft"
        );

        if (auction.payToken != address(0)) {
            IERC20 payToken = IERC20(auction.payToken);
            require(
                payToken.transferFrom(_msgSender(), address(this), _bidAmount),
                "insufficient balance or not approved"
            );
        } else if (auction.payToken == address(0)) {
            payable(address(this)).transfer(_bidAmount);
        }

        BuyerInfo[_nftAddress][_tokenId][msg.sender] = buyerInfo(
            true,
            block.timestamp,
            _bidAmount,
            bidderinfo.index
        );

        bidderinfo.highBid = _bidAmount;
        bidderinfo.higherBidder = payable(msg.sender);
        //bidderinfo.index = bidderinfo.index;
        bidderinfo.index++;
        bidderinfo.bidderAddress.push(msg.sender);
        bidderinfo.bidAmount.push(_bidAmount);

        emit BidPlaced(_nftAddress, _tokenId, _msgSender(), _bidAmount);
    }

    /**
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the item being auctioned
     */
    function withdrawBid(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
    {
        buyerInfo memory buyerinfo = BuyerInfo[_nftAddress][_tokenId][
            msg.sender
        ];
        require(
            buyerinfo.isBidder == true,
            "you are not the bidder, So you can not cancel bid"
        );

        require(
            block.timestamp > (buyerinfo.bidTime + bidWithdrawalLockTime),
            "Please wait for withdrawal lock time"
        );

        _refundBidder(
            _nftAddress,
            _tokenId,
            payable(_msgSender()),
            buyerinfo.amount
        );

        emit BidWithdrawn(
            _nftAddress,
            _tokenId,
            _msgSender(),
            buyerinfo.amount
        );
    }

    /**
     @param _bidder Address of the bidder
     @param _bid Ether or Mona amount in WEI that the bidder sent when placing their bid
     */
    function _refundBidder(
        address _nftAddress,
        uint256 _tokenId,
        address payable _bidder,
        uint256 _bid
    ) private {
        Auction memory auction = auctions[_nftAddress][_tokenId];
        bidderInfo storage bidderinfo = biddingInfo[_nftAddress][_tokenId];

        if (auction.payToken == address(0)) {
            (bool successRefund, ) = _bidder.call{value: _bid}("");
            require(successRefund, "failed to refund previous bidder");
        } else {
            IERC20 payToken = IERC20(auction.payToken);
            require(
                payToken.transfer(_bidder, _bid),
                "failed to refund previous bidder"
            );
        }

        bidderinfo.bidAmount[
            BuyerInfo[_nftAddress][_tokenId][msg.sender].index
        ] = 0;
        bidderinfo.bidderAddress[
            BuyerInfo[_nftAddress][_tokenId][msg.sender].index
        ] = address(0);

        if (bidderinfo.higherBidder == msg.sender) {
            if (BuyerInfo[_nftAddress][_tokenId][msg.sender].index == 0) {
                bidderinfo.higherBidder = payable(address(0));
                bidderinfo.highBid = 0;
            } else {
                uint256 i = BuyerInfo[_nftAddress][_tokenId][msg.sender].index;

                while (bidderinfo.bidAmount[i] == 0) {
                    bidderinfo.higherBidder = payable(
                        bidderinfo.bidderAddress[i - 1]
                    );
                    bidderinfo.highBid = bidderinfo.bidAmount[i - 1];
                    i--;
                }
            }
        }

        delete BuyerInfo[_nftAddress][_tokenId][msg.sender];

        emit BidRefunded(_nftAddress, _tokenId, _bidder, _bid);
    }

    function resultAuction(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
    {
        Auction storage auction = auctions[_nftAddress][_tokenId];
        require(auction.onAuction, "This nft is not listed for auction");
        require(
            auction.endTime <= block.timestamp,
            "Can not transfer the NFT before the auction ends"
        );

        require(
            auction.owner == _msgSender() || owner() == _msgSender(),
            "not owning item"
        );
        require(
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721),
            "invalid nft address"
        );

        address winner = biddingInfo[_nftAddress][_tokenId].higherBidder;
        uint256 winningBid = biddingInfo[_nftAddress][_tokenId].highBid;

        if (winner == address(0)) {
            delete auctions[_nftAddress][_tokenId];
        } else {
            // Work out platform fee from above reserve amount
            uint256 platformFeeAmount = winningBid.mul(platformFee).div(10000);

            if (IERC165(_nftAddress).supportsInterface(_INTERFACE_ID_ERC2981)) {
                (address royaltyFeeRecipient, uint256 _royaltyAmount) = royalty(
                    _nftAddress
                ).royaltyInfo(_tokenId, winningBid - platformFeeAmount);

                uint256 payAmount = winningBid -
                    (platformFeeAmount + _royaltyAmount);
                if (auction.payToken == address(0)) {
                    // Send platform fee
                    (bool platformTransferSuccess, ) = platformFeeRecipient
                        .call{value: platformFeeAmount}("");
                    require(
                        platformTransferSuccess,
                        "failed to send platform fee"
                    );

                    (bool royaltyTransferSuccess, ) = payable(
                        royaltyFeeRecipient
                    ).call{value: _royaltyAmount}("");
                    require(
                        royaltyTransferSuccess,
                        "failed to send the owner their royalties"
                    );
                } else {
                    IERC20 payToken = IERC20(auction.payToken);
                    require(
                        payToken.transfer(
                            platformFeeRecipient,
                            platformFeeAmount
                        ),
                        "failed to send platform fee"
                    );

                    require(
                        payToken.transfer(royaltyFeeRecipient, _royaltyAmount),
                        "failed to send the royalties"
                    );
                }
                escrow[auction.owner].push(
                    Escrow(
                        _nftAddress,
                        winner,
                        auction.payToken,
                        payAmount,
                        _tokenId,
                        true
                    )
                );
            } else {
                if (auction.payToken == address(0)) {
                    // Send platform fee
                    (bool platformTransferSuccess, ) = platformFeeRecipient
                        .call{value: platformFeeAmount}("");
                    require(
                        platformTransferSuccess,
                        "failed to send platform fee"
                    );
                } else {
                    IERC20 payToken = IERC20(auction.payToken);
                    require(
                        payToken.transfer(
                            platformFeeRecipient,
                            platformFeeAmount
                        ),
                        "failed to send platform fee"
                    );
                }

                escrow[auction.owner].push(
                    Escrow(
                        _nftAddress,
                        winner,
                        auction.payToken,
                        winningBid - platformFeeAmount,
                        _tokenId,
                        true
                    )
                );
            }

            // Transfer the token to the winner
            if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
                IERC721(_nftAddress).safeTransferFrom(
                    auction.owner,
                    winner,
                    _tokenId
                );
            }

            _resultAuction(_nftAddress, _tokenId, winner, winningBid);
        }
    }

    /**
     @notice Results a finished auction
     @dev Only admin or smart contract
     @dev Auction can only be resulted if there has been a bidder and reserve met.
     @dev If there have been no bids, the auction needs to be cancelled instead using `cancelAuction()`
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the item being auctioned
     */
    function _resultAuction(
        address _nftAddress,
        uint256 _tokenId,
        address winner,
        uint256 winningBid
    ) internal {
        Auction storage auction = auctions[_nftAddress][_tokenId];
        bidderInfo storage bidderinfo = biddingInfo[_nftAddress][_tokenId];

        for (
            uint256 i = 0;
            i < BuyerInfo[_nftAddress][_tokenId][bidderinfo.higherBidder].index;
            i++
        ) {
            if (auction.payToken == address(0)) {
                if (
                    bidderinfo.bidderAddress[i] != address(0) &&
                    bidderinfo.bidAmount[i] != 0
                ) {
                    payable(bidderinfo.bidderAddress[i]).transfer(
                        bidderinfo.bidAmount[i]
                    );
                }
            } else if (auction.payToken != address(0)) {
                if (
                    bidderinfo.bidderAddress[i] != address(0) &&
                    bidderinfo.bidAmount[i] != 0
                ) {
                    IERC20(auction.payToken).transfer(
                        bidderinfo.bidderAddress[i],
                        bidderinfo.bidAmount[i]
                    );
                }
            }

            delete BuyerInfo[_nftAddress][_tokenId][
                biddingInfo[_nftAddress][_tokenId].bidderAddress[i]
            ];
        }

        delete biddingInfo[_nftAddress][_tokenId];

        delete auctions[_nftAddress][_tokenId];

        delete BuyerInfo[_nftAddress][_tokenId][winner];

        emit AuctionResulted(
            _nftAddress,
            _tokenId,
            winner,
            auction.payToken,
            winningBid
        );
    }

    /*
     @notice Method for paying escrow
     @dev Only contract owner can pay escrow
     @param _owner Owner of the NFT
    */
    function payEscrow(address _owner) external onlyOwner {
        Escrow[] memory escrowItems = escrow[_owner];
        require(escrowItems.length != 0, "No escrow items");
        for (uint256 i = 0; i < escrowItems.length; i++) {
            Escrow memory escrowItem = escrowItems[i];
            if (!escrowItem.exists) {
                continue;
            }
            if (escrowItem.payToken == address(0)) {
                (bool transferSuccess, ) = (_owner).call{
                    value: escrowItem.amount
                }("");
                require(transferSuccess, "transfer failed");
            } else {
                IERC20(escrowItem.payToken).safeTransfer(
                    _owner,
                    escrowItem.amount
                );
            }

            escrowItem.exists = false;
        }
        delete (escrow[_owner]);
    }

    /**
     @dev Only item owner
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the NFT being auctioned
     */
    function cancelAuction(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
    {
        // Check valid and not resulted
        Auction storage auction = auctions[_nftAddress][_tokenId];
        bidderInfo storage bidderinfo = biddingInfo[_nftAddress][_tokenId];

        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
        } else {
            revert("invalid nft address");
        }

        // Check auction is real
        require(
            auction.endTime > block.timestamp,
            "cannot cancel after auction ends"
        );
        // Check auction not already resulted
        require(auction.onAuction, "auction did not exist");

        for (uint256 i = 0; i < bidderinfo.index; i++) {
            if (auction.payToken == address(0)) {
                if (
                    bidderinfo.bidderAddress[i] != address(0) &&
                    bidderinfo.bidAmount[i] != 0
                ) {
                    payable(bidderinfo.bidderAddress[i]).transfer(
                        bidderinfo.bidAmount[i]
                    );
                }
            } else if (auction.payToken != address(0)) {
                if (
                    bidderinfo.bidderAddress[i] != address(0) &&
                    bidderinfo.bidAmount[i] != 0
                ) {
                    IERC20(auction.payToken).transfer(
                        bidderinfo.bidderAddress[i],
                        bidderinfo.bidAmount[i]
                    );
                }
            }

            delete BuyerInfo[_nftAddress][_tokenId][
                bidderinfo.bidderAddress[i]
            ];
        }

        delete auctions[_nftAddress][_tokenId];

        delete biddingInfo[_nftAddress][_tokenId];

        // _cancelAuction(_nftAddress, _tokenId);
        emit AuctionCancelled(_nftAddress, _tokenId);
    }

    /**
     @notice Update the amount by which bids have to increase, across all auctions
     @dev Only admin
     @param _minBidIncrement New bid step in WEI
     */
    function updateMinBidIncrement(uint256 _minBidIncrement)
        external
        onlyOwner
    {
        minBidIncrement = _minBidIncrement;
        emit UpdateMinBidIncrement(_minBidIncrement);
    }

    /**
     @notice Update the global bid withdrawal lockout time
     @dev Only admin
     @param _bidWithdrawalLockTime New bid withdrawal lock time
     */
    function updateBidWithdrawalLockTime(uint256 _bidWithdrawalLockTime)
        external
        onlyOwner
    {
        bidWithdrawalLockTime = _bidWithdrawalLockTime;
        emit UpdateBidWithdrawalLockTime(_bidWithdrawalLockTime);
    }

    /**
     @notice Update the current reserve price for an auction
     @dev Only admin
     @dev Auction must exist
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the NFT being auctioned
     @param _reservePrice New Ether reserve price (WEI value)
     */
    function updateAuctionReservePrice(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _reservePrice
    ) external {
        Auction storage auction = auctions[_nftAddress][_tokenId];

        require(_msgSender() == auction.owner, "sender must be item owner");
        require(auction.endTime > 0, "no auction exists");

        auction.reservePrice = _reservePrice;
        emit UpdateAuctionReservePrice(
            _nftAddress,
            _tokenId,
            auction.payToken,
            _reservePrice
        );
    }

    /**
     @notice Update the current start time for an auction
     @dev Only admin
     @dev Auction must exist
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the NFT being auctioned
     @param _startTime New start time (unix epoch in seconds)
     */
    function updateAuctionStartTime(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _startTime
    ) external {
        Auction storage auction = auctions[_nftAddress][_tokenId];

        require(_msgSender() == auction.owner, "sender must be owner");
        require(auction.onAuction, "no auction exists");
        require(
            block.timestamp < auction.startTime,
            "can not change time after auction starts"
        );
        require(
            _startTime < auction.endTime,
            "start time must be before end time"
        );
        auction.startTime = _startTime;
        emit UpdateAuctionStartTime(_nftAddress, _tokenId, _startTime);
    }

    /**
     @notice Update the current end time for an auction
     @dev Only admin
     @dev Auction must exist
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the NFT being auctioned
     @param _endTimestamp New end time (unix epoch in seconds)
     */
    function updateAuctionEndTime(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _endTimestamp
    ) external {
        Auction storage auction = auctions[_nftAddress][_tokenId];

        require(_msgSender() == auction.owner, "sender must be owner");
        require(auction.endTime > 0, "no auction exists");
        require(
            block.timestamp < auction.startTime,
            "can not change time after auction starts"
        );
        require(
            auction.startTime < _endTimestamp,
            "end time must be greater than start"
        );
        require(_endTimestamp > block.timestamp, "invalid end time");

        auction.endTime = _endTimestamp;
        emit UpdateAuctionEndTime(_nftAddress, _tokenId, _endTimestamp);
    }

    /**
     @notice Method for updating platform fee
     @dev Only admin
     @param _platformFee uint256 the platform fee to set
     */
    function updatePlatformFee(uint256 _platformFee) external onlyOwner {
        require(
            _platformFee <= 1000,
            "Platform fee can not be greater than 10%"
        );
        platformFee = _platformFee;
        emit UpdatePlatformFee(_platformFee);
    }

    /**
     @notice Method for updating platform fee address
     @dev Only admin
     @param _platformFeeRecipient payable address the address to sends the funds to
     */
    function updatePlatformFeeRecipient(address payable _platformFeeRecipient)
        external
        onlyOwner
    {
        require(_platformFeeRecipient != address(0), "zero address");

        platformFeeRecipient = _platformFeeRecipient;
        emit UpdatePlatformFeeRecipient(_platformFeeRecipient);
    }

    /**
     @notice Update tokenRegistry contract
     @dev Only admin
     */
    function updateTokenRegistry(address _registry) external onlyOwner {
        tokenRegistry = _registry;
        emit UpdateTokenRegistery(_registry);
    }

    ///////////////
    // Accessors //
    ///////////////

    /**
     @notice Method for getting all info about the auction
     @param _nftAddress ERC 721 Address
     @param _tokenId Token ID of the NFT being auctioned
     */
    function getAuction(address _nftAddress, uint256 _tokenId)
        external
        view
        returns (
            address _owner,
            address _payToken,
            uint256 _reservePrice,
            uint256 _startTime,
            uint256 _endTime,
            bool _resulted
        )
    {
        Auction storage auction = auctions[_nftAddress][_tokenId];
        return (
            auction.owner,
            auction.payToken,
            auction.reservePrice,
            auction.startTime,
            auction.endTime,
            auction.onAuction
        );
    }

    // function reclaimERC20(address _tokenContract) external onlyOwner {
    //     require(_tokenContract != address(0), "Invalid address");
    //     IERC20 token = IERC20(_tokenContract);
    //     uint256 balance = token.balanceOf(address(this));
    //     require(token.transfer(_msgSender(), balance), "Transfer failed");
    // }
}

//

//0x0000000000000000000000000000000000000000
