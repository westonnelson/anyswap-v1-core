// SPDX-License-Identifier: MIT
// Multichain721 NFT demo contract built on top of AnyCall

pragma solidity ^0.8.0;

import "github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @dev Add on-chain data attach to ERC721 token
 */
contract ERC721WithData is ERC721Enumerable {
    address public dataOperator;
    struct TokenData {
        uint256 foo;
        uint256 bar;
    }

    mapping(uint256 => TokenData) public data;

    constructor(string memory name_, string memory symbol_, address dataOperator_) ERC721(name_, symbol_) {
        dataOperator = dataOperator_;
    }

    function setTokenData(uint256 tokenId, uint256 _foo, uint256 _bar) internal {
        data[tokenId].foo = _foo;
        data[tokenId].bar = _bar;
    }

    function encodeTokenData(uint256 tokenId) public view returns (bytes memory data_) {
        data_ = abi.encode(data[tokenId].foo, data[tokenId].bar);
    }

    function setTokenDataFromBytes(uint256 tokenId, bytes memory data_) internal {
        (uint256 foo, uint256 bar) = abi.decode(data_, (uint256, uint256));
        setTokenData(tokenId, foo, bar);
    }

    function ownerSetTokenData(uint256 tokenId, uint256 _foo, uint256 _bar) public {
        require(_msgSender() == ownerOf(tokenId), "not authorized");
        setTokenData(tokenId, _foo, _bar);
    }
}

abstract contract AnyCallProxy {
    struct Context {
        address sender;
        uint256 fromChainID;
    }

    Context public context;

    function anyCall(address _to, bytes calldata _data, address _fallback, uint256 _toChainID) virtual external;
    function withdraw(uint256 _amount) virtual external;
}

contract Multichain721 is ERC721WithData {
    address public admin;
    address public anyCallProxy;

    uint256 public constant PrepareTimeout = 7 days;

    /// Outbound prepare struct
    /// caller is the original owner
    struct Prepare {
        address caller;
        uint96 timestamp;
    }

    /// key is tokenId
    mapping (uint256 => Prepare) public prepares;

    /// key is destination chain id
    /// value is Multichain721 contract on destination chain
    mapping (uint256 => address) public targets;
    mapping (address => uint256) public chains;

    event LogPrepare(uint256 tokenId, Prepare lock);
    event LogCancelPrepare(uint256 tokenId, Prepare lock);
    event LogOutboundSuccess(uint256 tokenId);
    event LogOutboundFail(uint256 tokenId);

    modifier onlyAnyCall() {
        require(_msgSender() == anyCallProxy, "not authorized");
        _;
    }

    modifier onlyAdmin() {
        require(_msgSender() == admin, "not authorized");
        _;
    }

    constructor(string memory name_, string memory symbol_, address anyCallProxy_) ERC721WithData(name_, symbol_, anyCallProxy_) {
        admin = _msgSender();
        anyCallProxy = anyCallProxy_;
    }

    function isLocked(uint256 tokenId) view public returns (bool) {
        return (ownerOf(tokenId) == address(this));
    }

    function claim(uint256 tokenId) public {
        _safeMint(_msgSender(), tokenId);
    }

    function setAnyCallProxy(address anyCallProxy_) public onlyAdmin {
        anyCallProxy = anyCallProxy_;
        dataOperator = anyCallProxy_;
    }

    function setAdmin(address admin_) public onlyAdmin {
        admin = admin_;
    }

    function setTarget(address target, uint256 chainId) public onlyAdmin {
        targets[chainId] = target;
        chains[target] = chainId;
    }

    function prepare(uint256 tokenId) internal {
        _safeTransfer(_msgSender(), address(this), tokenId, "");
        Prepare memory lock = Prepare(_msgSender(), uint96(block.timestamp));
        prepares[tokenId] = lock;
        emit LogPrepare(tokenId, lock);
    }

    function cancelPrepare(uint256 tokenId) internal {
        address caller = prepares[tokenId].caller;
        uint96 timestamp = prepares[tokenId].timestamp;
        require(caller != address(0) && timestamp > 0);
        require(block.timestamp >= uint256(timestamp) + PrepareTimeout, "cannot cancel before timeout");
        _safeTransfer(address(this), prepares[tokenId].caller, tokenId, "");
        Prepare memory lock = prepares[tokenId];
        prepares[tokenId] = Prepare(address(0), uint96(0));
        emit LogCancelPrepare(tokenId, lock);
    }

    /// add tokenId to prepare (temporarily locked)
    /// call anyCall
    function outbound(uint256 tokenId, address receiver, uint256 toChainID) public {
        prepare(tokenId);
        bytes memory inboundData = abi.encodeWithSignature("inbound(uint256,address,bytes)", tokenId, receiver, encodeTokenData(tokenId));
        // anycall inbound
        AnyCallProxy(anyCallProxy).anyCall(targets[toChainID], inboundData, address(this), toChainID);
    }

    /// mint or transfer tokenId to receiver
    function inbound(uint256 tokenId, address receiver, bytes memory tokenData) public onlyAnyCall {
        if (ownerOf(tokenId) == address(0)) {
            _safeMint(receiver, tokenId);
            setTokenDataFromBytes(tokenId, tokenData);
        } else if (ownerOf(tokenId) == address(this)) {
            _safeTransfer(address(this), receiver, tokenId, "");
            setTokenDataFromBytes(tokenId, tokenData);
        } else {
            revert("tokenId is not available on destination chain");
        }
        // anycall outboundCallback
        (, uint256 fromChainID) = AnyCallProxy(anyCallProxy).context();
        bytes memory callbackData = abi.encodeWithSignature("outboundCallback(uint256)", tokenId);
        AnyCallProxy(anyCallProxy).anyCall(targets[fromChainID], callbackData, address(0), fromChainID);
    }

    /// remove prepare, lock tokenId in this contract
    /// burn tokenId (optional)
    function outboundCallback(uint256 tokenId) public onlyAnyCall {
        prepares[tokenId] = Prepare(address(0), uint96(0));
        _burn(tokenId);
        emit LogOutboundSuccess(tokenId);
    }

    function anyFallback(address to, bytes calldata data) public onlyAnyCall {
        require(chains[to] > 0, "unknown target contract");
        // decode data
        (uint256 tokenId, ,) = abi.decode(data[4:], (uint256, address, bytes));
        cancelPrepare(tokenId);
        emit LogOutboundFail(tokenId);
        return;
    }

    function withdraw(uint256 amount) public onlyAdmin {
        AnyCallProxy(anyCallProxy).withdraw(amount);admin.call{value: amount}("");
        admin.call{value: amount}("");
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
