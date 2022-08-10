// SPDX-License-Identifier: MIT
// Simplized from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC721/IERC721.sol)
// Only for testing

pragma solidity ^0.8.0;

import "../ERC721.sol";
import "../interfaces/IMintBurn721.sol";

contract SimpleMintBurnERC721 is ERC721, IMintBurn721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address account, uint256 tokenId) override external {
        _safeMint(account, tokenId);
    }

    function burn(uint256 tokenId) override external {
        _burn(tokenId);
    }
    
    function ownerOf(uint256 tokenId) public view virtual override(ERC721,IMintBurn721) returns (address) {
        return super.ownerOf(tokenId);
    }
}