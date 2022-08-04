// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../AnyCallApp.sol";
import "../ERC20Gateway.sol";
import "../Address.sol";
import "../interfaces/IGatewayClient.sol";
interface ITransfer {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract ERC20Gateway_LP is ERC20Gateway {
    using Address for address;

    constructor (address anyCallProxy, uint256 flag, address token) ERC20Gateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 amount, address sender) internal override returns (bool) {
        return ITransfer(token).transferFrom(sender, address(this), amount);
    }

    function _swapin(uint256 amount, address receiver) internal override returns (bool) {
        return ITransfer(token).transferFrom(address(this), receiver, amount);
    }

    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) internal override returns (bool) {
        bool result = ITransfer(token).transferFrom(address(this), sender, amount);
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(IGatewayClient.notifySwapoutFallback.selector, result, amount, swapoutSeq);
            sender.call(_data);
        }
        return result;
    }
}