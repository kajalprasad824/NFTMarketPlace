//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract NFT721 is
    ERC721,
    ERC721URIStorage,
    Ownable,
    ReentrancyGuard,
    EIP712,
    ERC2981
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Strings for uint256;
    using ECDSA for bytes32;

    uint256 public platformFees = 500;
    bool public paused = false;

    address public tokenRegistry;

    event mintedId(uint256 tokenId);

    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => bool) public isNonceUsed;

    /// @notice Represents an un-minted NFT, which has not yet been recorded into the blockchain. A signed voucher can be redeemed for a real NFT using the redeem function.
    struct NFTVoucher {
        ///@notice name of this token.
        string name;
        ///@notice description about this token.
        string description;
        /// @notice The id of the token to be redeemed. Must be unique - if another token with this ID already exists, the redeem function will revert.
        uint256 tokenId;
        /// @notice The percentage of royalties that NFT creator will recieve.
        uint96 royalty;
        /// @notice The minimum price (in wei) that the NFT creator is willing to accept for the initial sale of this NFT.
        uint256 minPrice;
        /// @notice The metadata URI to associate with this token.
        string uri;
        /// @notice The original creator of this token.
        address creator;
        /// @notice address of accepted token
        address token;
        /// @notice unique nonce
        uint256 nonce;
        /// @notice the EIP-712 signature of all other fields in the NFTVoucher struct. For a voucher to be valid, it must be signed by an account with the MINTER_ROLE.
        bytes signature;
    }

    //["hola","hola","71","5000000000000000","uriImage","0x0c81f606d5f0e77d8af4229e239d6307ab6aed9e","0xd8b934580fcE35a11B58C6D73aDeE468a2833fa8","567463","0x69e7b7671adcb1cbfb9958a1b671afb5ff8da792674d1c23affbf0832485b43a7552d9f72a23c8c2bec2e274b2b1480e556fd39313232bdb2c14536548f1d17f1c"]
    //["1","1000000000000000000","ipfs","0x5B38Da6a701c568545dCfcB03FcB875f56beddC4","0xD7ACd2a9FD159E69Bb102A1ca21C9a3e3A5F771B","1"]

    constructor(
        string memory dapp,
        string memory version,
        address _tokenRegistry
    ) ERC721("Fabian", "FAB") EIP712(dapp, version) ReentrancyGuard() {
        tokenRegistry = _tokenRegistry;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    //["1","10","10","Offer1","0xC0cf38A6B952Aab887c8f32aEa540721e6595444","0xD04B22251c90076952fC6E574ef91235484bdC9C","1","0xce00ddaf297bdb47eb5d98b4b548aff8b3aae68a858bdc0761eab397f267d7da174c2c3f986a68b4dcd613dad63914f2b55f5a15c60a8dc2c5d542b4721f0bd01c"]

    /// @notice Redeems an NFTVoucher for an actual NFT, creating it in the process.
    /// @param voucher An NFTVoucher that describes the NFT to be redeemed.
    function redeem(NFTVoucher calldata voucher) external payable {
        require(!paused, "NFT: contract is paused");
        require(voucher.royalty <= 1000, "Royalty can't be greater than 10%");
        require(!isNonceUsed[voucher.nonce], "NFT: nonce is used");

        uint256 platformFeeAmount = (platformFees * voucher.minPrice) / 10000;

        if (voucher.token == address(0)) {
            require(
                msg.value >= voucher.minPrice,
                "Insufficient funds to redeem"
            );
            uint256 creatorFee = msg.value - platformFeeAmount;
            payable(voucher.creator).transfer(creatorFee);
            payable(owner()).transfer(platformFeeAmount);
        } else {
            require(
                ITokenRegistry(tokenRegistry).enabled(voucher.token),
                "Token not accepted"
            );
            uint256 creatorFee = voucher.minPrice - platformFeeAmount;
            IERC20(voucher.token).safeTransferFrom(
                msg.sender,
                voucher.creator,
                creatorFee
            );
            IERC20(voucher.token).safeTransferFrom(
                msg.sender,
                owner(),
                platformFeeAmount
            );
        }
        isNonceUsed[voucher.nonce] = true;
        _safeMint(voucher.creator, voucher.tokenId);
        _setTokenURI(voucher.tokenId, voucher.uri);
        _transfer(voucher.creator, msg.sender, voucher.tokenId);
        _setTokenRoyalty(voucher.tokenId, voucher.creator, voucher.royalty);
        emit mintedId(voucher.tokenId);
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    ///@notice Sets platform fees
    ///@param _platformFees is the platform fees
    function setPlatformFees(uint256 _platformFees) external onlyOwner {
        require(
            _platformFees <= 1000,
            "Platform fees can not be greater than 10%"
        );
        platformFees = _platformFees;
    }

    ///@notice toggles paused state
    function togglePauseState() external onlyOwner {
        paused = !paused;
    }

    ///@notice Withdraws platform fees
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }

    function directMint(
        address _to,
        uint256 _tokenId,
        uint96 _royalty,
        string calldata _uri
    ) external {

        require(!paused, "NFT: contract is paused");
        require(_royalty <= 1000, "Royalty can't be greater than 10%");
       
        _safeMint(_to, _tokenId);
        _setTokenURI(_tokenId, _uri);
        _setTokenRoyalty(_tokenId, _to, _royalty);
        emit mintedId(_tokenId);
    }

    function updateTokenRegistery(address _tokenRegistry) external onlyOwner {
        tokenRegistry = _tokenRegistry;
    }

    function _hash(NFTVoucher calldata voucher)
        internal
        view
        returns (bytes32)
    {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "NFTVoucher(string name,string description,uint256 tokenId,uint96 royalty,uint256 minPrice,string uri,address creator,address token,uint256 nonce)"
                        ),
                        keccak256(bytes(voucher.name)),
                        keccak256(bytes(voucher.description)),
                        voucher.tokenId,
                        voucher.royalty,
                        voucher.minPrice,
                        keccak256(bytes(voucher.uri)),
                        voucher.creator,
                        voucher.token,
                        voucher.nonce
                    )
                )
            );
    }

    function _verify(NFTVoucher calldata voucher)
        internal
        view
        returns (address)
    {
        bytes32 digest = _hash(voucher);
        return ECDSA.recover(digest, voucher.signature);
    }

    function getChainID() external view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        //override(AccessControl, ERC721URIStorage, ERC721, ERC2981)
        override(ERC721URIStorage, ERC721, ERC2981)
        returns (bool)
    {
        return
            ERC721URIStorage.supportsInterface(interfaceId) ||
           // AccessControl.supportsInterface(interfaceId) ||
            ERC721.supportsInterface(interfaceId) ||
            ERC2981.supportsInterface(interfaceId);
    }
}


