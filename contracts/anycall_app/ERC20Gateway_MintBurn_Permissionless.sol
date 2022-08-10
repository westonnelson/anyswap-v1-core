// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "../AnyCallApp.sol";
import "../ERC20Gateway.sol";
import "../Address.sol";
import "../interfaces/IGatewayClient.sol";
import "../interfaces/IMintBurn.sol";

contract ERC20Gateway_MintBurn_Permissionless is ERC20Gateway {
    using Address for address;

    constructor(
        address anyCallProxy,
        address token
    ) ERC20Gateway(anyCallProxy, 0, token) {}

    mapping(uint256 => uint256) public priceTable; // chainID -> price (wei)

    function setPrice(uint256 chainID, uint256 price) external onlyAdmin {
        priceTable[chainID] = price;
    }

    function withdrawFee(address to, uint256 amount) external onlyAdmin {
        require(to.code.length == 0);
        (bool success,) = to.call{value: amount}("");
        require(success);
    }

    function _swapout(uint256 amount, address sender)
        internal
        override
        returns (bool)
    {
        require(msg.value >= priceTable[chainID]);
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
