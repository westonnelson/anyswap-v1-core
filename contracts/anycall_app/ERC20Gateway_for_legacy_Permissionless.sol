// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../AnyCallApp.sol";
import "../ERC20Gateway.sol";
import "../Address.sol";
import "../interfaces/IGatewayClient.sol";
import "../interfaces/IAnyERC20_legacy.sol";

contract ERC20Gateway_for_AnyERC20_legacy_Permissionless is ERC20Gateway {
    using Address for address;

    constructor (address anyCallProxy, address token) ERC20Gateway(anyCallProxy, 0, token) {}

    mapping(uint256 => uint256) public priceTable; // chainID -> price (wei)

    function setPrice(uint256 chainID, uint256 price) external onlyAdmin {
        priceTable[chainID] = price;
    }

    function withdrawFee(address to, uint256 amount) external onlyAdmin {
        require(to.code.length == 0);
        (bool success,) = to.call{value: amount}("");
        require(success);
    }

    function _swapout(uint256 amount, address sender) internal override returns (bool) {
        require(msg.value >= priceTable[chainID]);
        return IAnyERC20_legacy(token).Swapout(amount, address(0));
    }

    function _swapin(uint256 amount, address receiver) internal override returns (bool) {
        return IAnyERC20_legacy(token).Swapin(bytes32(bytes("")), receiver, amount);
    }

    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) internal override returns (bool) {
        bool result = IAnyERC20_legacy(token).Swapin(bytes32(bytes("")), sender, amount);
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(IGatewayClient.notifySwapoutFallback.selector, result, amount, swapoutSeq);
            sender.call(_data);
        }
        return result;
    }
}