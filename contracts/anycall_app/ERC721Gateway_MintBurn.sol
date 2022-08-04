// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../AnyCallApp.sol";
import "../ERC721Gateway.sol";
import "../Address.sol";
import "../interfaces/IGatewayClient721.sol";
import "../interfaces/IMintBurn721.sol";

contract ERC721Gateway_MintBurn is ERC721Gateway {
    using Address for address;

    constructor (address anyCallProxy, uint256 flag, address token) ERC721Gateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 tokenId) internal override virtual returns (bool, bytes memory) {
        require(IMintBurn721(token).ownerOf(tokenId) == msg.sender, "not allowed");
        try IMintBurn721(token).burn(tokenId) {
            return (true, "");
        } catch {
            return (false, "");
        }
    }

    function _swapin(uint256 tokenId, address receiver, bytes memory extraMsg) internal override returns (bool) {
        try IMintBurn721(token).mint(receiver, tokenId) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _swapoutFallback(uint256 tokenId, address sender, uint256 swapoutSeq, bytes memory extraMsg) internal override returns (bool result) {
        try IMintBurn721(token).mint(sender, tokenId) {
            result = true;
        } catch {
            result = false;
        }
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(IGatewayClient721.notifySwapoutFallback.selector, result, tokenId, swapoutSeq);
            sender.call(_data);
        }
        return result;
    }
}