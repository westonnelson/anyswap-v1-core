// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../AnyCallApp.sol";
import "../ERC20Gateway.sol";
import "../Address.sol";
import "../interfaces/IGatewayClient.sol";
import "../interfaces/IMintBurn.sol";

contract ERC20Gateway_MintBurn is ERC20Gateway {
    using Address for address;

    constructor(
        address anyCallProxy,
        uint256 flag,
        address token
    ) ERC20Gateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 amount, address sender)
        internal
        override
        returns (bool)
    {
        try IMintBurn(token).burnFrom(sender, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _swapin(uint256 amount, address receiver)
        internal
        override
        returns (bool)
    {
        try IMintBurn(token).mint(receiver, amount) {
            return true;
        } catch {
            return false;
        }
    }

    function _swapoutFallback(
        uint256 amount,
        address sender,
        uint256 swapoutSeq
    ) internal override returns (bool result) {
        try IMintBurn(token).mint(sender, amount) {
            result = true;
        } catch {
            result = false;
        }
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(
                IGatewayClient.notifySwapoutFallback.selector,
                result,
                amount,
                swapoutSeq
            );
            sender.call(_data);
        }
        return result;
    }
}
