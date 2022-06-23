// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

interface IAnycallV6Proxy {
    function anyCall(
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _toChainID,
        uint256 _flags
    ) external payable;

    function executor() external view returns (address);
}

interface IExecutor {
    function context() external returns (address from, uint256 fromChainID, uint256 nonce);
}

contract Administrable {
    address public admin;
    address public pendingAdmin;
    event LogSetAdmin(address admin);
    event LogTransferAdmin(address oldadmin, address newadmin);
    event LogAcceptAdmin(address admin);

    function setAdmin(address admin_) internal {
        admin = admin_;
        emit LogSetAdmin(admin_);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        address oldAdmin = pendingAdmin;
        pendingAdmin = newAdmin;
        emit LogTransferAdmin(oldAdmin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit LogAcceptAdmin(admin);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }
}

abstract contract AnyCallApp is Administrable {
    uint256 public flag; // 0: pay on dest chain, 2: pay on source chain
    address public anyCallProxy;

    mapping(uint256 => address) public peer;

    modifier onlyExecutor() {
        require(msg.sender == IAnycallV6Proxy(anyCallProxy).executor());
        _;
    }

    constructor (address anyCallProxy_, uint256 flag_) {
        anyCallProxy = anyCallProxy_;
        flag = flag_;
    }

    function setPeers(uint256[] memory chainIDs, address[] memory  peers) public onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
        }
    }

    function setAnyCallProxy(address proxy) public onlyAdmin {
        anyCallProxy = proxy;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal virtual returns (bool success, bytes memory result);

    function _anyFallback(bytes calldata data) internal virtual;

    function _anyCall(address _to, bytes memory _data, address _fallback, uint256 _toChainID) internal {
        if (flag == 2) {
            IAnycallV6Proxy(anyCallProxy).anyCall{value: msg.value}(_to, _data, _fallback, _toChainID, flag);
        } else {
            IAnycallV6Proxy(anyCallProxy).anyCall(_to, _data, _fallback, _toChainID, flag);
        }
    }

    function anyExecute(bytes calldata data) external onlyExecutor returns (bool success, bytes memory result) {
        (address callFrom, uint256 fromChainID,) = IExecutor(IAnycallV6Proxy(anyCallProxy).executor()).context();
        require(peer[fromChainID] == callFrom, "call not allowed");
        _anyExecute(fromChainID, data);
    }

    function anyFallback(address to, bytes calldata data) external onlyExecutor {
        (address callFrom, ,) = IExecutor(IAnycallV6Proxy(anyCallProxy).executor()).context();
        require(address(this) == callFrom, "call not allowed");
        _anyFallback(data);
    }
}

// interface of ERC20Gateway
interface IERC1155Gateway {
    function name() external view returns (string memory);
    function token() external view returns (address);
    function getPeer(uint256 foreignChainID) external view returns (address);
    function Swapout(uint256 tokenId, uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
    function Swapout_no_fallback(uint256 tokenId, uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
}

abstract contract ERC1155Gateway is IERC1155Gateway, AnyCallApp {
    address public token;
    mapping(uint256 => uint8) public decimals;
    uint256 public swapoutSeq;
    string public name;

    constructor (address anyCallProxy, uint256 flag, address token_) AnyCallApp(anyCallProxy, flag) {
        setAdmin(msg.sender);
        token = token_;
    }

    function getPeer(uint256 foreignChainID) external view returns (address) {
        return peer[foreignChainID];
    }

    function _swapout(address sender, uint256 tokenId, uint256 amount) internal virtual returns (bool, bytes memory);
    function _swapin(uint256 tokenId, uint256 amount, address receiver, bytes memory extraMsg) internal virtual returns (bool);
    function _swapoutFallback(uint256 tokenId, uint256 amount, address sender, uint256 swapoutSeq, bytes memory extraMsg) internal virtual returns (bool);

    event LogAnySwapOut(uint256 tokenId, address sender, address receiver, uint256 toChainID, uint256 swapoutSeq);

    function setForeignGateway(uint256[] memory chainIDs, address[] memory  peers) external onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
        }
    }

    function Swapout(uint256 tokenId, uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        (bool ok, bytes memory extraMsg) = _swapout(msg.sender, tokenId, amount);
        require(ok);
        swapoutSeq++;
        bytes memory data = abi.encode(tokenId, amount, msg.sender, receiver, swapoutSeq, extraMsg);
        _anyCall(peer[destChainID], data, address(this), destChainID);
        emit LogAnySwapOut(tokenId, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function Swapout_no_fallback(uint256 tokenId, uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        (bool ok, bytes memory extraMsg) = _swapout(msg.sender, tokenId, amount);
        require(ok);
        swapoutSeq++;
        bytes memory data = abi.encode(tokenId, amount, msg.sender, receiver, swapoutSeq, extraMsg);
        _anyCall(peer[destChainID], data, address(0), destChainID);
        emit LogAnySwapOut(tokenId, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal override returns (bool success, bytes memory result) {
        (uint256 tokenId, uint256 amount, , address receiver,,bytes memory extraMsg) = abi.decode(
            data,
            (uint256, uint256, address, address, uint256, bytes)
        );
        require(_swapin(tokenId, amount, receiver, extraMsg));
    }

    function _anyFallback(bytes calldata data) internal override {
        (uint256 tokenId, uint256 amount, address sender, , uint256 swapoutSeq, bytes memory extraMsg) = abi.decode(
            data,
            (uint256, uint256, address, address, uint256, bytes)
        );
        require(_swapoutFallback(tokenId, amount, sender, swapoutSeq, extraMsg));
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}

interface IMintBurn1155 {
    function mint(address account, uint256 tokenId, uint256 amount) external;
    // function mint(address account, uint256 tokenId, uint256 amount, bytes memory data) external;
    function burn(address account, uint256 tokenId, uint256 amount) external;
    // function burn(address account, uint256 tokenId, uint256 amount, bytes memory data) external;
}

interface IGatewayClient {
    function notifySwapoutFallback(bool refundSuccess, uint256 tokenId, uint256 amount, uint256 swapoutSeq) external returns (bool);
}

contract ERC1155Gateway_MintBurn is ERC1155Gateway {
    using Address for address;

    constructor (address anyCallProxy, uint256 flag, address token) ERC1155Gateway(anyCallProxy, flag, token) {}

    function _swapout(address sender, uint256 tokenId, uint256 amount) internal override virtual returns (bool, bytes memory) {
        try IMintBurn1155(token).burn(sender, tokenId, amount) {
            return (true, "");
        } catch {
            return (false, "");
        }
    }

    function _swapin(uint256 tokenId, uint256 amount, address receiver, bytes memory extraMsg) internal override returns (bool) {
        try IMintBurn1155(token).mint(receiver, tokenId, amount) {
            return true;
        } catch {
            return false;
        }
    }
    
    function _swapoutFallback(uint256 tokenId, uint256 amount, address sender, uint256 swapoutSeq, bytes memory extraMsg) internal override returns (bool result) {
        try IMintBurn1155(token).mint(sender, tokenId, amount) {
            result = true;
        } catch {
            result = false;
        }
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(IGatewayClient.notifySwapoutFallback.selector, result, tokenId, amount, swapoutSeq);
            sender.call(_data);
        }
        return result;
    }
}