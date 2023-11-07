// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDC is ERC20{
    constructor() ERC20('USDC Token', 'USDC') {
        _mint(msg.sender, 2_500_000_000 * 10 ** 18);
    }
}

// 0x1010DD61fe0BFeB4d5Bd32eA465eeCE9f4776FcF - Sepolia Testnet

//["Segunda prueba","descripcion","75","2000000000000000","uriImage","0x0c81f606d5f0e77d8af4229e239d6307ab6aed9e","0x118A3e79260a1411B4ef4CE7295985879d01a53a","991409","0xb1dd0df02ef8671f9b5549dc63fe355207f48045869ed3dc91af40c5c8f73510092c82e0129abeb720aa8230e084d6b504f96364921d50d498dc919f82e1ce5f1c"]