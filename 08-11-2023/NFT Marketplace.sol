// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

interface royalty {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address, uint96);
}

contract NFTMarketplace is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address payable;
    using SafeERC20 for IERC20;

    /// @notice Events for the contract
    event ItemListed(
        address indexed owner,
        address indexed nft,
        uint256 tokenId,
        uint256 quantity,
        address payToken,
        uint256 pricePerItem,
        uint256 startingTime
    );
    event ItemSold(
        address indexed seller,
        address indexed buyer,
        address indexed nft,
        uint256 tokenId,
        uint256 quantity,
        address payToken,
        uint256 pricePerItem
    );
    event ItemUpdated(
        address indexed owner,
        address indexed nft,
        uint256 tokenId,
        address payToken,
        uint256 newPrice
    );
    event ItemCanceled(
        address indexed owner,
        address indexed nft,
        uint256 tokenId
    );
    event OfferCreated(
        address indexed creator,
        address indexed nft,
        uint256 tokenId,
        uint256 quantity,
        address payToken,
        uint256 pricePerItem,
        uint256 deadline
    );
    event OfferCanceled(
        address indexed creator,
        address indexed nft,
        uint256 tokenId
    );

    event UpdatePlatformFee(uint16 platformFee);
    event UpdatePlatformFeeRecipient(address payable platformFeeRecipient);
    event UpdateTokenRegistery(address tokenRegistery);

    /// @notice Structure for listed items
    struct Listing {
        uint256 quantity;
        address payToken;
        uint256 pricePerItem;
        uint256 startingTime;
    }

    /// @notice Structure for offer
    struct Offer {
        IERC20 payToken;
        uint256 quantity;
        uint256 pricePerItem;
        uint256 deadline;
    }

    struct Escrow {
        address nft;
        address buyer;
        address payToken;
        uint256 amount;
        uint256 tokenID;
        bool exists;
    }

    bytes4 private constant INTERFACE_ID_ERC721 = 0x80ac58cd;
    bytes4 private constant INTERFACE_ID_ERC1155 = 0xd9b67a26;
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    /// @notice NftAddress -> Token ID -> Owner -> Listing item
    mapping(address => mapping(uint256 => mapping(address => Listing)))
        public listings;

    /// @notice NftAddress -> Token ID -> Offerer -> Offer
    mapping(address => mapping(uint256 => mapping(address => Offer)))
        public offers;

    mapping(address => Escrow[]) public escrow;

    /// @notice Platform fee
    uint16 public platformFee;

    /// @notice Platform fee receipient
    address payable public platformFeeReceipient;

    /// @notice Token registry
    address public tokenRegistry;

    modifier isListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity > 0, "not listed item");
        _;
    }

    modifier notListed(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listing = listings[_nftAddress][_tokenId][_owner];
        require(listing.quantity == 0, "already listed");
        _;
    }

    modifier validListing(
        address _nftAddress,
        uint256 _tokenId,
        address _owner
    ) {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _owner, "not owning item");
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_owner, _tokenId) >= listedItem.quantity,
                "not owning item"
            );
        } else {
            revert("invalid nft address");
        }
        require(_getNow() >= listedItem.startingTime, "item not buyable");
        _;
    }

    modifier offerExists(
        address _nftAddress,
        uint256 _tokenId,
        address _creator
    ) {
        Offer memory offer = offers[_nftAddress][_tokenId][_creator];
        require(
            offer.quantity > 0 && offer.deadline > _getNow(),
            "offer not exists or expired"
        );
        _;
    }

    modifier offerNotExists(
        address _nftAddress,
        uint256 _tokenId,
        address _creator
    ) {
        Offer memory offer = offers[_nftAddress][_tokenId][_creator];
        require(
            offer.quantity == 0 || offer.deadline <= _getNow(),
            "offer already created"
        );
        _;
    }

    /// @notice Contract initializer
    constructor(
        address initialOwner,
        address _tokenRegistry,
        address payable _platformFeeReceipient,
        uint16 _platformFee
    ) Ownable(initialOwner) {
        require(
            _platformFee <= 1000,
            "Platform fee can not be greater than 10%"
        );
        tokenRegistry = _tokenRegistry;
        platformFee = _platformFee;
        platformFeeReceipient = _platformFeeReceipient;
    }

    /*
     @notice Method for listing NFT
     @param _nftAddress Address of NFT contract
     @param _tokenId Token ID of NFT
     @param _quantity token amount to list (needed for ERC-1155 NFTs, set as 1 for ERC-721)
     @param _payToken Paying token
     @param _pricePerItem sale price for each iteam
     @param _startingTime scheduling for a future sale
    */
    function listItem(
        address _nftAddress,
        uint256 _tokenId,
        uint256 _quantity,
        address _payToken,
        uint256 _pricePerItem,
        uint256 _startingTime
    ) public notListed(_nftAddress, _tokenId, _msgSender()) {
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
            require(
                nft.isApprovedForAll(_msgSender(), address(this)),
                "item not approved"
            );
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= _quantity,
                "must hold enough nfts"
            );
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

        require(
            _startingTime > _getNow(),
            "Start time should be greater than current time"
        );

        listings[_nftAddress][_tokenId][_msgSender()] = Listing(
            _quantity,
            _payToken,
            _pricePerItem,
            _startingTime
        );
        emit ItemListed(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            _payToken,
            _pricePerItem,
            _startingTime
        );
    }

    /// @notice Method for canceling listed NFT
    function cancelListing(address _nftAddress, uint256 _tokenId)
        external
        nonReentrant
        isListed(_nftAddress, _tokenId, _msgSender())
    {
        Listing memory listedItem = listings[_nftAddress][_tokenId][
            _msgSender()
        ];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= listedItem.quantity,
                "not owning item"
            );
        } else {
            revert("invalid nft address");
        }

        delete (listings[_nftAddress][_tokenId][_msgSender()]);
        emit ItemCanceled(_msgSender(), _nftAddress, _tokenId);
    }

    /*
     @notice Method for updating listed NFT
     @param _nftAddress Address of NFT contract
     @param _tokenId Token ID of NFT
     @param _payToken payment token
     @param _newPrice New sale price for each item
    */
    function updateListing(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        uint256 _newPrice
    ) external nonReentrant isListed(_nftAddress, _tokenId, _msgSender()) {
        Listing storage listedItem = listings[_nftAddress][_tokenId][
            _msgSender()
        ];
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= listedItem.quantity,
                "not owning item"
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

        listedItem.payToken = _payToken;
        listedItem.pricePerItem = _newPrice;
        emit ItemUpdated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _payToken,
            _newPrice
        );
    }

    /*
     @notice Method for buying listed NFT
     @param _nftAddress NFT contract address
     @param _tokenId TokenId
     TODO combine both the functions
    */
    function buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address payable _owner
    )
        external
        payable
        nonReentrant
        isListed(_nftAddress, _tokenId, _owner)
        validListing(_nftAddress, _tokenId, _owner)
    {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        require(listedItem.payToken == address(0), "invalid pay token");
        require(
            msg.value >= listedItem.pricePerItem.mul(listedItem.quantity),
            "insufficient balance to buy"
        );

        _buyItem(_nftAddress, _tokenId, address(0), _owner);
    }

    /*
     @notice Method for buying listed NFT
     @param _nftAddress NFT contract address
     @param _tokenId TokenId
    */
    function buyItemWithERC20(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        address _owner
    )
        external
        nonReentrant
        isListed(_nftAddress, _tokenId, _owner)
        validListing(_nftAddress, _tokenId, _owner)
    {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];
        require(listedItem.payToken == _payToken, "invalid pay token");

        _buyItem(_nftAddress, _tokenId, _payToken, _owner);
    }

    /* 
     @notice Method for offering item
     @param _nftAddress NFT contract address
     @param _tokenId TokenId
     @param _payToken Paying token
     @param _quantity Quantity of items
     @param _pricePerItem Price per item
     @param _deadline Offer expiration
    */
    function createOffer(
        address _nftAddress,
        uint256 _tokenId,
        IERC20 _payToken,
        uint256 _quantity,
        uint256 _pricePerItem,
        uint256 _deadline
    ) external offerNotExists(_nftAddress, _tokenId, _msgSender()) {
        require(
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721) ||
                IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155),
            "invalid nft address"
        );
        require(_deadline > _getNow(), "invalid expiration");
        require(
            (tokenRegistry != address(0) &&
                ITokenRegistry(tokenRegistry).enabled(address(_payToken))),
            "invalid pay token"
        );

        offers[_nftAddress][_tokenId][_msgSender()] = Offer(
            _payToken,
            _quantity,
            _pricePerItem,
            _deadline
        );

        emit OfferCreated(
            _msgSender(),
            _nftAddress,
            _tokenId,
            _quantity,
            address(_payToken),
            _pricePerItem,
            _deadline
        );
    }

    /*
     @notice Method for canceling the offer
     @param _nftAddress NFT contract address
     @param _tokenId TokenId
    */
    function cancelOffer(address _nftAddress, uint256 _tokenId)
        external
        offerExists(_nftAddress, _tokenId, _msgSender())
    {
        delete (offers[_nftAddress][_tokenId][_msgSender()]);
        emit OfferCanceled(_msgSender(), _nftAddress, _tokenId);
    }

    /*
     @notice Method for accepting the offer
     @param _nftAddress NFT contract address
     @param _tokenId TokenId
     @param _creator Offer creator address
    */
    function acceptOffer(
        address _nftAddress,
        uint256 _tokenId,
        address _creator
    ) external nonReentrant offerExists(_nftAddress, _tokenId, _creator) {
        Offer memory offer = offers[_nftAddress][_tokenId][_creator];

        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721 nft = IERC721(_nftAddress);
            require(nft.ownerOf(_tokenId) == _msgSender(), "not owning item");
        } else if (
            IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC1155)
        ) {
            IERC1155 nft = IERC1155(_nftAddress);
            require(
                nft.balanceOf(_msgSender(), _tokenId) >= offer.quantity,
                "not owning item"
            );
        } else {
            revert("invalid nft address");
        }

        _acceptOffer(_nftAddress, _tokenId, _creator);
    }

    //-----------------------------------Admin Functions-------------------------------------

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
     @notice Method for updating platform fee
     @dev Only admin
     @param _platformFee uint16 the platform fee to set
     */
    function updatePlatformFee(uint16 _platformFee) external onlyOwner {
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
        platformFeeReceipient = _platformFeeRecipient;
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

    //--------------------------------Internal and Private------------------------------

    function _acceptOffer(
        address _nftAddress,
        uint256 _tokenId,
        address _creator
    ) private {
        Offer memory offer = offers[_nftAddress][_tokenId][_creator];

        uint256 price = offer.pricePerItem.mul(offer.quantity);
        uint256 platformFeeAmount = price.mul(platformFee).div(1e4);

        offer.payToken.safeTransferFrom(
            _creator,
            platformFeeReceipient,
            platformFeeAmount
        );

        if (IERC165(_nftAddress).supportsInterface(_INTERFACE_ID_ERC2981)) {
            (address royaltyFeeRecipient, uint256 royaltyAmount) = royalty(
                _nftAddress
            ).royaltyInfo(_tokenId, price - platformFeeAmount);

            uint256 totalFeeAmount = platformFeeAmount.add(royaltyAmount);
            offer.payToken.safeTransferFrom(
                _creator,
                royaltyFeeRecipient,
                royaltyAmount
            );
            offer.payToken.safeTransferFrom(
                _creator,
                address(this),
                price.sub(totalFeeAmount)
            );

            escrow[_msgSender()].push(
                Escrow(
                    _nftAddress,
                    _creator,
                    address(offer.payToken),
                    price.sub(totalFeeAmount),
                    _tokenId,
                    true
                )
            );
        } else {
            offer.payToken.safeTransferFrom(
                _creator,
                address(this),
                price.sub(platformFeeAmount)
            );
            escrow[_msgSender()].push(
                Escrow(
                    _nftAddress,
                    _creator,
                    address(offer.payToken),
                    price.sub(platformFeeAmount),
                    _tokenId,
                    true
                )
            );
        }

        // Transfer NFT to buyer
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(
                _msgSender(),
                _creator,
                _tokenId
            );
        } else {
            IERC1155(_nftAddress).safeTransferFrom(
                _msgSender(),
                _creator,
                _tokenId,
                offer.quantity,
                bytes("")
            );
        }

        delete (listings[_nftAddress][_tokenId][_msgSender()]);
        delete (offers[_nftAddress][_tokenId][_creator]);

        emit ItemSold(
            _msgSender(),
            _creator,
            _nftAddress,
            _tokenId,
            offer.quantity,
            address(offer.payToken),
            offer.pricePerItem
        );
    }

    function _buyItem(
        address _nftAddress,
        uint256 _tokenId,
        address _payToken,
        address _owner
    ) private {
        Listing memory listedItem = listings[_nftAddress][_tokenId][_owner];

        uint256 price = listedItem.pricePerItem.mul(listedItem.quantity);
        uint256 platformFeeAmount = price.mul(platformFee).div(1e4);

        if (IERC165(_nftAddress).supportsInterface(_INTERFACE_ID_ERC2981)) {
            (address royaltyFeeRecipient, uint256 _royaltyAmount) = royalty(
                _nftAddress
            ).royaltyInfo(_tokenId, price - platformFeeAmount);

            uint256 totalFeeAmount = platformFeeAmount.add(_royaltyAmount);

            if (_payToken == address(0)) {
                (bool feeTransferSuccess, ) = platformFeeReceipient.call{
                    value: platformFeeAmount
                }("");
                require(feeTransferSuccess, "fee transfer failed");

                (bool royaltyTransferSuccess, ) = payable(royaltyFeeRecipient)
                    .call{value: _royaltyAmount}("");
                require(royaltyTransferSuccess, "royalty fee transfer failed");
            } else {
                IERC20(_payToken).safeTransferFrom(
                    _msgSender(),
                    platformFeeReceipient,
                    platformFeeAmount
                );
                IERC20(_payToken).safeTransferFrom(
                    _msgSender(),
                    royaltyFeeRecipient,
                    _royaltyAmount
                );
                IERC20(_payToken).safeTransferFrom(
                    _msgSender(),
                    address(this),
                    price.sub(totalFeeAmount)
                );
            }

            escrow[_owner].push(
                Escrow(
                    _nftAddress,
                    _msgSender(),
                    _payToken,
                    price.sub(totalFeeAmount),
                    _tokenId,
                    true
                )
            );
        } else {
            if (_payToken == address(0)) {
                (bool feeTransferSuccess, ) = platformFeeReceipient.call{
                    value: platformFeeAmount
                }("");
                require(feeTransferSuccess, "fee transfer failed");
            } else {
                IERC20(_payToken).safeTransferFrom(
                    _msgSender(),
                    platformFeeReceipient,
                    platformFeeAmount
                );

                IERC20(_payToken).safeTransferFrom(
                    _msgSender(),
                    address(this),
                    price.sub(price - platformFeeAmount)
                );
            }

            escrow[_owner].push(
                Escrow(
                    _nftAddress,
                    _msgSender(),
                    _payToken,
                    price.sub(price - platformFeeAmount),
                    _tokenId,
                    true
                )
            );
        }

        // Transfer NFT to buyer
        if (IERC165(_nftAddress).supportsInterface(INTERFACE_ID_ERC721)) {
            IERC721(_nftAddress).safeTransferFrom(
                _owner,
                _msgSender(),
                _tokenId
            );
        } else {
            IERC1155(_nftAddress).safeTransferFrom(
                _owner,
                _msgSender(),
                _tokenId,
                listedItem.quantity,
                bytes("")
            );
        }

        emit ItemSold(
            _owner,
            _msgSender(),
            _nftAddress,
            _tokenId,
            listedItem.quantity,
            _payToken,
            price.div(listedItem.quantity)
        );
        delete (listings[_nftAddress][_tokenId][_owner]);
    }

    function _getNow() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    function etherBalance() public view returns (uint256) {
        return address(this).balance;
    }
}

//0x0000000000000000000000000000000000000000
