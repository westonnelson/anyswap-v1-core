// SPDX-License-Identifier: MIT
// Multichain721 NFT demo contract built on top of AnyCall

pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @dev Add on-chain data attach to ERC721 token
 */
contract ERC721WithData is ERC721Enumerable {
    address public nftDataAdmin;
    address public dataOperator;
    struct TokenData {
        uint256 foo;
        uint256 bar;
    }

    mapping(uint256 => TokenData) public data;

    modifier onlyNftDataAdmin() {
        require(_msgSender() == nftDataAdmin);
        _;
    }

    constructor(string memory name_, string memory symbol_, address dataOperator_) ERC721(name_, symbol_) {
        nftDataAdmin = _msgSender();
        dataOperator = dataOperator_;
    }

    function setDataOperator(address _operator) public onlyNftDataAdmin {
        dataOperator = _operator;
    }

    function setNftDataAdmin(address _admin) public onlyNftDataAdmin {
        nftDataAdmin = _admin;
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

abstract contract ERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
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

abstract contract AnyCallClient is Context {
    address public anyCallClientAdmin;
    address public anyCallProxy;

    /// key is destination chain id
    /// value is Multichain721 contract on destination chain
    mapping (uint256 => address) public targets;

    modifier onlyAnyCall() {
        require(_msgSender() == anyCallProxy, "not authorized");
        _;
    }

    modifier onlyAnyCallClientAdmin() {
        require(_msgSender() == anyCallClientAdmin, "not authorized");
        _;
    }

    constructor(address anyCallProxy_) {
        anyCallClientAdmin = _msgSender();
        anyCallProxy = anyCallProxy_;
    }

    function setAnyCallProxy(address anyCallProxy_) public onlyAnyCallClientAdmin {
        anyCallProxy = anyCallProxy_;
    }

    function setAdmin(address admin_) public onlyAnyCallClientAdmin {
        anyCallClientAdmin = admin_;
    }

    function setTarget(address target, uint256 chainId) public onlyAnyCallClientAdmin {
        targets[chainId] = target;
    }

    function anyCallWithdraw(uint256 amount) public onlyAnyCallClientAdmin returns (bool, bytes memory) {
        AnyCallProxy(anyCallProxy).withdraw(amount);
        return anyCallClientAdmin.call{value: amount}("");
    }
}

/**
 * Multichain721
 * Multichain NFT contract utilizing AnyCall
 */
contract Multichain721 is ERC721WithData, ERC721Receiver, AnyCallClient {              
    event LogOutbound(uint256 tokenId);
    event LogOutboundFail(uint256 tokenId);

    uint256 public chainPrefix;

    constructor(string memory name_, string memory symbol_, address anyCallProxy_) ERC721WithData(name_, symbol_, anyCallProxy_) AnyCallClient(anyCallProxy_) {
        chainPrefix = block.chainid;
        chainPrefix <<= 128;
    }

    function claim(uint128 seed) public returns (uint256 tokenId) {
        tokenId = chainPrefix + seed;
        _safeMint(_msgSender(), tokenId);
    }

    function outbound(uint256 tokenId, address receiver, uint256 toChainID) public {
        bytes memory inboundData = abi.encodeWithSignature("inbound(uint256,address,bytes)", tokenId, receiver, encodeTokenData(tokenId));
        _burn(tokenId);
        // anycall inbound
        AnyCallProxy(anyCallProxy).anyCall(targets[toChainID], inboundData, address(this), toChainID);
    }

    /// mint or transfer tokenId to receiver
    function inbound(uint256 tokenId, address receiver, bytes memory tokenData) public onlyAnyCall {
        require(!_exists(tokenId), "tokenId is not available on destination chain");
        _safeMint(receiver, tokenId);
        setTokenDataFromBytes(tokenId, tokenData);
    }

    function anyFallback(address to, bytes calldata data) public onlyAnyCall {
        // TODO check to address
        // decode data
        (uint256 tokenId, address receiver,) = abi.decode(data[4:], (uint256, address, bytes));
        _safeTransfer(address(this), receiver, tokenId, "");
        emit LogOutboundFail(tokenId);
        return;
    }
 }
