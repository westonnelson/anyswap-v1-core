// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IAnycallV6Proxy {
    function anyCall(
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _toChainID,
        uint256 _flags
    ) external payable;
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
        emit LogAcceptAdmin(admin);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }
}

abstract contract AnyCallApp is Administrable {
    uint256 public constant flag = 0;
    address public anyCallProxy;
    address public anyCallExecutor;

    mapping(uint256 => address) public peer;

    modifier onlyExecutor() {
        require(msg.sender == anyCallExecutor);
        _;
    }

    constructor (address anyCallProxy_, address anyCallExecutor_) {
        anyCallProxy = anyCallProxy_;
        anyCallExecutor = anyCallExecutor_;
    }

    function setPeers(uint256[] memory chainIDs, address[] memory  peers) public onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
        }
    }

    function setAnyCallProxy(address proxy) public onlyAdmin {
        anyCallProxy = proxy;
    }

    function setAnyCallExecutor(address executor) public onlyAdmin {
        anyCallExecutor = executor;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal virtual returns (bool success, bytes memory result);

    function _anyFallback(bytes calldata data) internal virtual;

    function _anyCall(address _to, bytes memory _data, address _fallback, uint256 _toChainID) internal {
        IAnycallV6Proxy(anyCallProxy).anyCall{value: msg.value}(_to, _data, _fallback, _toChainID, flag);
    }

    function anyExecute(bytes calldata data) external onlyExecutor returns (bool success, bytes memory result) {
        (address callFrom, uint256 fromChainID,) = IExecutor(anyCallExecutor).context();
        require(peer[fromChainID] == callFrom, "call not allowed");
        _anyExecute(fromChainID, data);
    }

    function anyFallback(address to, bytes calldata data) external onlyExecutor {
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

    constructor (address anyCallProxy, address anyCallExecutor, address token_) AnyCallApp(anyCallProxy, anyCallExecutor) {
        setAdmin(msg.sender);
        token = token_;
    }

    function getPeer(uint256 foreignChainID) external view returns (address) {
        return peer[foreignChainID];
    }

    function _swapout(address sender, uint256 tokenId, uint256 amount) internal virtual returns (bool, bytes calldata);
    function _swapin(uint256 tokenId, uint256 amount, address receiver, bytes memory extraMsg) internal virtual returns (bool);
    function _swapoutFallback(uint256 tokenId, uint256 amount, address sender, uint256 swapoutSeq, bytes memory extraMsg) internal virtual returns (bool);

    event LogAnySwapOut(uint256 tokenId, address sender, address receiver, uint256 toChainID, uint256 swapoutSeq);

    function setForeignGateway(uint256[] memory chainIDs, address[] memory  peers) external onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
        }
    }

    function Swapout(uint256 tokenId, uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        (bool ok, bytes calldata extraMsg) = _swapout(msg.sender, tokenId, amount);
        require(ok);
        swapoutSeq++;
        bytes memory data = abi.encode(tokenId, amount, msg.sender, receiver, swapoutSeq, extraMsg);
        _anyCall(peer[destChainID], data, address(this), destChainID);
        emit LogAnySwapOut(tokenId, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function Swapout_no_fallback(uint256 tokenId, uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        (bool ok, bytes calldata extraMsg) = _swapout(msg.sender, tokenId, amount);
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
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != 0x0 && codehash != accountHash);
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

    constructor (address anyCallProxy, address anyCallExecutor, address token) ERC1155Gateway(anyCallProxy, anyCallExecutor, token) {}

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
            try IGatewayClient(sender).notifySwapoutFallback(result, tokenId, amount, swapoutSeq) returns (bool) {

            } catch {

            }
        }
        return result;
    }
}