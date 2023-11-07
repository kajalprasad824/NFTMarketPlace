//SPDX-License-Identifier: Unlicense

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface ITokenRegistry {
    function enabled(address) external view returns (bool);
}

contract NFT1155 is ERC1155, Ownable, ReentrancyGuard, EIP712, AccessControl{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Strings for uint256;
    using ECDSA for bytes32;

    //bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    bool public paused = false;
    address public tokenRegistry;

    event mintedId(uint tokenId);

    mapping(uint256 => string) private _tokenURIs;
    mapping(uint256 => bool) public isNonceUsed;

    // string private _baseURIextended;

    /// @notice Represents an un-minted NFT, which has not yet been recorded into the blockchain. A signed voucher can be redeemed for a real NFT using the redeem function.
    struct NFTVoucher {
        ///@notice name of this token.
        string name;
        ///@notice description about this token.
        string description;
        /// @notice The id of the token to be redeemed. Must be unique - if another token with this ID already exists, the redeem function will revert.
        uint256 tokenId;
        /// @notice The amount of tokens to be minted.
        uint256 quantity;
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

    constructor(
        string memory dapp,
        string memory version,
        address _tokenRegistry
    ) ERC1155("") EIP712(dapp, version) ReentrancyGuard() {
        tokenRegistry = _tokenRegistry;
    }

    /// @notice Redeems an NFTVoucher for an actual NFT, creating it in the process.
    /// @param voucher An NFTVoucher that describes the NFT to be redeemed.
    function redeem(NFTVoucher calldata voucher) public payable {
        require(!paused, "NFT: contract is paused");
        require(!isNonceUsed[voucher.nonce], "NFT: nonce is used");

        if (voucher.token == address(0)) {
            require(
                msg.value >= voucher.minPrice * voucher.quantity,
                "Insufficient funds to redeem"
            );
            payable(voucher.creator).transfer(msg.value);
            
        } else {
            require(
                ITokenRegistry(tokenRegistry).enabled(voucher.token),
                "Token not accepted"
            );
            uint creatorFee = (voucher.minPrice * voucher.quantity);
            IERC20(voucher.token).safeTransferFrom(
                msg.sender,
                voucher.creator,
                creatorFee
            );
        }
        isNonceUsed[voucher.nonce] = true;
        _mint(voucher.creator, voucher.tokenId, voucher.quantity, "");
        _setTokenURI(voucher.tokenId, voucher.uri);
        _safeTransferFrom(
            voucher.creator,
            msg.sender,
            voucher.tokenId,
            voucher.quantity,
            ""
        );
        emit mintedId(voucher.tokenId);
    }

    function _setTokenURI(uint tokenId, string calldata _tokenURI) internal {
        _tokenURIs[tokenId] = _tokenURI;
    }

    ///@notice fetches the URI associated with a token
    ///@param tokenId the id of the token
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }

    ///@notice toggles paused state
    function togglePauseState() external onlyOwner {
        paused = !paused;
    }

    function _hash(
        NFTVoucher calldata voucher
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "NFTVoucher(string name,string description,uint256 tokenId,uint256 quantity,uint256 minPrice,string uri,address creator,address token,uint256 nonce)"
                        ),
                        keccak256(bytes(voucher.name)),
                        keccak256(bytes(voucher.description)),
                        voucher.tokenId,
                        voucher.quantity,
                        voucher.minPrice,
                        keccak256(bytes(voucher.uri)),
                        voucher.creator,
                        voucher.token,
                        voucher.nonce
                    )
                )
            );
    }

    function _verify(
        NFTVoucher calldata voucher
    ) public view returns (address) {
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

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, ERC1155) returns (bool) {
        return
            ERC1155.supportsInterface(interfaceId) ||
            AccessControl.supportsInterface(interfaceId);
    }

    function mint(address account, uint256 id, uint256 amount, bytes memory data)
        public
        onlyOwner
    {
        _mint(account, id, amount, data);
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data)
        public
        onlyOwner
    {
        _mintBatch(to, ids, amounts, data);
    }
}




