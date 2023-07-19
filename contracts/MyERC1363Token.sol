// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "erc-payable-token/contracts/token/ERC1363/ERC1363.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title A mintable and burnable ERC1363 token.
 */
contract MyERC1363Token is ERC1363, ERC20Burnable, Ownable {
    constructor() ERC20("MITHRIL", "MIT") {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
