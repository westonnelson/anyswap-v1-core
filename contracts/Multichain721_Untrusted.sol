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
 * Multichain721_Untrusted
 */
contract Multichain721_Untrusted is ERC721Enumerable, ERC721Receiver, AnyCallClient {
    using Address for address;

    uint256 public chainPrefix;

    uint256 public constant RelayTimeout = 5 days;
    uint256 public constant ReceiveTimeout = 6 days;
    uint256 public constant CancelTimeout = 11 days;
    uint120 nonce;

    /// Outbound lock struct
    /// owner is the original owner
    struct Message {
        uint64 fromChainID;
        uint64 toChainID;
        address owner;
        uint96 timestamp;
        uint120 nonce;
        bool processed;
    }

    /// key is tokenId
    mapping (uint256 => Message) public outboundMessages;

    mapping (uint256 => Message) public inboundMessages;

    /// key is tokenId
    /// value is if conflict or not
    mapping (uint256 => bool) public conflict;

    event LogOutbound(uint256 tokenId, Message message, bytes32 hash);
    event LogCancelOutbound(uint256 tokenId, Message message);
    event LogInbound(uint256 tokenId, Message message);
    event LogReceive(uint256 tokenId, Message message, uint8 v, bytes32 r, bytes32 s);
    event LogFinish(uint256 tokenId, Message message);
    event LogTokenConflict(uint256 tokenId);

    constructor(string memory name_, string memory symbol_, address anyCallProxy_) ERC721(name_, symbol_) AnyCallClient(anyCallProxy_) {
        chainPrefix = block.chainid;
        chainPrefix <<= 128;
    }

    function claim(uint256 seed) public returns (uint256 tokenId) {
        tokenId = chainPrefix + seed;
        _safeMint(_msgSender(), tokenId);
    }

    function newNonce() internal returns (uint120) {
        return ++nonce;
    }

    function outbound(uint256 tokenId, uint256 toChainID) public returns (bytes32 hash) {
        require(Address.isContract(_msgSender()) == false);
        _safeTransfer(_msgSender(), address(this), tokenId, "");

        // build message
        uint64 fromChainID;
        assembly {
            fromChainID := chainid()
        }
        uint120 outnonce = newNonce();
        Message memory message = Message(fromChainID, uint64(toChainID), _msgSender(), uint96(block.timestamp), outnonce, false);

        outboundMessages[tokenId] = message;

        // anycall inbound
        bytes memory inboundData = abi.encodeWithSignature("inbound(uint256,address,uint256,uint256,bytes)", tokenId, _msgSender(), block.timestamp, uint256(outnonce));
        AnyCallProxy(anyCallProxy).anyCall(targets[toChainID], inboundData, address(0), toChainID);

        hash = keccak256(abi.encode(tokenId, message));

        emit LogOutbound(tokenId, message, hash);
        return hash;
    }

    /// only when timeout
    function cancelOutbound(uint256 tokenId) public {
        Message memory message = outboundMessages[tokenId];

        require(message.processed == false, "cannot cancel processed message");
        require(message.owner != address(0) && message.timestamp > 0);
        require(block.timestamp > uint256(message.timestamp) + CancelTimeout, "cannot cancel before timeout");

        outboundMessages[tokenId] = Message(0, 0, address(0), 0, 0, false);

        _safeTransfer(address(this), message.owner, tokenId, "");
        emit LogCancelOutbound(tokenId, message);
    }

    /// check if not processed
    /// lock tokenId
    /// add to inboundMessage
    function inbound(uint256 tokenId, address receiver, uint256 timestamp, uint256 sourceChainNonce) public onlyAnyCall {
        require(block.timestamp < timestamp + RelayTimeout, "inbound call out of date");

        if (!_exists(tokenId)) {
            _safeMint(address(this), tokenId);
        } else if (ownerOf(tokenId) == address(this)) {
        } else {
            conflict[tokenId] = true;
            emit LogTokenConflict(tokenId);
            return;
        }

        (, uint256 fromChainID) = AnyCallProxy(anyCallProxy).context();
        uint64 toChainID;
        assembly {
            toChainID := chainid()
        }
        Message memory message = Message(uint64(fromChainID), toChainID, receiver, uint96(timestamp), uint120(sourceChainNonce), false);
        inboundMessages[tokenId] = message;

        emit LogInbound(tokenId, message);
    }

    /// check signature
    /// unlock and transfer token to receiver
    /// anyCall onReceive
    function signAndReceive(uint256 tokenId, uint8 v, bytes32 r, bytes32 s) public {
        require(inboundMessages[tokenId].processed == false, "inbound already received");
        require(block.timestamp < uint256(inboundMessages[tokenId].timestamp) + ReceiveTimeout, "inbound message out of date");

        bytes32 hash = keccak256(abi.encode(tokenId, inboundMessages[tokenId]));
        address signer = ecrecover(hash, v, r, s);
        require(signer == inboundMessages[tokenId].owner, "wrong signature");

        _safeTransfer(address(this), inboundMessages[tokenId].owner, tokenId, "");
        inboundMessages[tokenId].processed = true;

        // anyCall onReceive
        uint256 fromChainID = uint256(inboundMessages[tokenId].fromChainID);
        bytes memory inboundData = abi.encodeWithSignature("onReceive(uint256,uint8,bytes32,bytes32)", tokenId, v, r, s);
        AnyCallProxy(anyCallProxy).anyCall(targets[fromChainID], inboundData, address(0), fromChainID);

        emit LogReceive(tokenId, inboundMessages[tokenId], v, r, s);
        return;
    }

    /// check if hash is already processed
    /// check signature
    /// clear lock
    /// permenantly lock tokenId or burn it
    function onReceive(uint256 tokenId, uint8 v, bytes32 r, bytes32 s) public {
        if (ownerOf(tokenId) != address(this)) {
            conflict[tokenId] = true;
            emit LogTokenConflict(tokenId);
            return;
        }
        Message memory message = outboundMessages[tokenId];
        message.processed = false;
        bytes32 hash = keccak256(abi.encode(tokenId, message));
        address signer = ecrecover(hash, v, r, s);
        require(signer == message.owner, "wrong signature");

        outboundMessages[tokenId].processed = true;
        emit LogFinish(tokenId, outboundMessages[tokenId]);
    }
}
