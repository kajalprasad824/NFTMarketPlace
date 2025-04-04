// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenRegistry is Ownable {
    /// @dev Events of the contract
    event TokenAdded(address token);
    event TokenRemoved(address token);

    /// @notice ERC20 Address -> Bool
    mapping(address => bool) public enabled;

    /**
  @notice Method for adding payment token
  @dev Only admin
  @param token ERC20 token address
  */
    function add(address token) external onlyOwner {
        require(!enabled[token], "token already added");
        enabled[token] = true;
        emit TokenAdded(token);
    }

    /**
  @notice Method for removing payment token
  @dev Only admin
  @param token ERC20 token address
  */
    function remove(address token) external onlyOwner {
        require(enabled[token], "token not exist");
        enabled[token] = false;
        emit TokenRemoved(token);
    }
}

//0x67fA9A24E015E5f207528C8507f6A17D224DBda7 - Sepolia Testnet