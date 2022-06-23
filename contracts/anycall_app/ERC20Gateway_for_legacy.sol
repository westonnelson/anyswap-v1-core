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
interface IERC20Gateway {
    function name() external view returns (string memory);
    function token() external view returns (address);
    function getPeer(uint256 foreignChainID) external view returns (address);
    function Swapout(uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
    function Swapout_no_fallback(uint256 amount, address receiver, uint256 toChainID) external payable returns (uint256 swapoutSeq);
}

interface IDecimal {
    function decimals() external view returns (uint8);
}

abstract contract ERC20Gateway is IERC20Gateway, AnyCallApp {
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

    function _swapout(uint256 amount, address sender) internal virtual returns (bool);
    function _swapin(uint256 amount, address receiver) internal virtual returns (bool);
    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) internal virtual returns (bool);

    event LogAnySwapOut(uint256 amount, address sender, address receiver, uint256 toChainID, uint256 swapoutSeq);

    function setForeignGateway(uint256[] memory chainIDs, address[] memory  peers, uint8[] memory decimals) external onlyAdmin {
        for (uint i = 0; i < chainIDs.length; i++) {
            peer[chainIDs[i]] = peers[i];
            decimals[chainIDs[i]] = decimals[i];
        }
    }

    function decimal(uint256 chainID) external view returns(uint8) {
        return (decimals[chainID] > 0 ? decimals[chainID] : IDecimal(token).decimals());
    }

    function convertDecimal(uint256 fromChain, uint256 amount) public view returns (uint256) {
        uint8 d_0 = this.decimal(fromChain);
        uint8 d_1 = IDecimal(token).decimals();
        if (d_0 > d_1) {
            for (uint8 i = 0; i < (d_0 - d_1); i++) {
                amount = amount / 10;
            }
        } else {
            for (uint8 i = 0; i < (d_1 - d_0); i++) {
                amount = amount * 10;
            }
        }
        return amount;
    }

    function Swapout(uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        require(_swapout(amount, msg.sender));
        swapoutSeq++;
        bytes memory data = abi.encode(amount, msg.sender, receiver, swapoutSeq);
        _anyCall(peer[destChainID], data, address(this), destChainID);
        emit LogAnySwapOut(amount, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function Swapout_no_fallback(uint256 amount, address receiver, uint256 destChainID) external payable returns (uint256) {
        require(_swapout(amount, msg.sender));
        swapoutSeq++;
        bytes memory data = abi.encode(amount, msg.sender, receiver, swapoutSeq);
        _anyCall(peer[destChainID], data, address(0), destChainID);
        emit LogAnySwapOut(amount, msg.sender, receiver, destChainID, swapoutSeq);
        return swapoutSeq;
    }

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal override returns (bool success, bytes memory result) {
        (uint256 amount, , address receiver,) = abi.decode(
            data,
            (uint256, address, address, uint256)
        );
        amount = convertDecimal(fromChainID, amount);
        require(_swapin(amount, receiver));
    }

    function _anyFallback(bytes calldata data) internal override {
        (uint256 amount, address sender, , uint256 swapoutSeq) = abi.decode(
            data,
            (uint256, address, address, uint256)
        );
        require(_swapoutFallback(amount, sender, swapoutSeq));
    }
}

library Address {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}

interface IGatewayClient {
    function notifySwapoutFallback(bool refundSuccess, uint256 amount, uint256 swapoutSeq) external returns (bool);
}

interface AnyERC20_legacy {
    function Swapout(uint256 amount, address toAddress) external returns (bool); // lock out or mint to
    function Swapin(bytes32 txhash, address account, uint256 amount) external returns (bool); // lock in or burn from
}

contract ERC20Gateway_for_AnyERC20_legacy is ERC20Gateway {
    using Address for address;

    constructor (address anyCallProxy, uint256 flag, address token) ERC20Gateway(anyCallProxy, flag, token) {}

    function _swapout(uint256 amount, address sender) internal override returns (bool) {
        return AnyERC20_legacy(token).Swapout(amount, address(0));
    }

    function _swapin(uint256 amount, address receiver) internal override returns (bool) {
        return AnyERC20_legacy(token).Swapin(bytes32(bytes("")), receiver, amount);
    }

    function _swapoutFallback(uint256 amount, address sender, uint256 swapoutSeq) internal override returns (bool) {
        bool result = AnyERC20_legacy(token).Swapin(bytes32(bytes("")), sender, amount);
        if (sender.isContract()) {
            bytes memory _data = abi.encodeWithSelector(IGatewayClient.notifySwapoutFallback.selector, result, amount, swapoutSeq);
            sender.call(_data);
        }
        return result;
    }
}