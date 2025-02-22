// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Context.sol";

interface IERC721Mintburnable is IERC721 {
    function mint(address to, uint256 tokenId) external virtual;

    function burn(uint256 tokenId) external virtual;
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

    function anyCall(
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _toChainID
    ) external virtual;

    function withdraw(uint256 _amount) external virtual;
}

abstract contract AnyCallClient is Context {
    address public anyCallClientAdmin;
    address public anyCallProxy;

    /// key is destination chain id
    /// value is Multichain721 contract on destination chain
    mapping(uint256 => address) public counterparts;

    modifier onlyAnyCall() {
        require(_msgSender() == anyCallProxy, "not authorized");
        (address from, uint256 fromChainId) = AnyCallProxy(anyCallProxy)
            .context();
        require(counterparts[fromChainId] == from, "caller is not allowed");
        _;
    }

    modifier onlyAnyCallFallback() {
        require(_msgSender() == anyCallProxy, "not authorized");
        (address from, uint256 fromChainId) = AnyCallProxy(anyCallProxy)
            .context();
        require(address(this) == from, "caller is not allowed");
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

    function setAnyCallProxy(address anyCallProxy_)
        public
        onlyAnyCallClientAdmin
    {
        anyCallProxy = anyCallProxy_;
    }

    function setAdmin(address admin_) public onlyAnyCallClientAdmin {
        anyCallClientAdmin = admin_;
    }

    function setCounterpart(address counterpart, uint256 chainId)
        public
        onlyAnyCallClientAdmin
    {
        counterparts[chainId] = counterpart;
    }

    function anyCallWithdraw(uint256 amount)
        public
        onlyAnyCallClientAdmin
        returns (bool, bytes memory)
    {
        AnyCallProxy(anyCallProxy).withdraw(amount);
        return anyCallClientAdmin.call{value: amount}("");
    }

    function _anyFallback(address to, bytes calldata data) external virtual;

    function anyFallback(address to, bytes calldata data) onlyAnyCallFallback external virtual {
        this._anyFallback(to, data);
    }
}

contract Any721Router is AnyCallClient {
    event LogOutbound(
        address token,
        uint256 tokenId,
        address receiver,
        uint256 toChainId
    );
    event LogInbound(
        address token,
        uint256 tokenId,
        address receiver,
        uint256 fromChainId
    );
    event LogOutboundFail(address token, uint256 tokenId);

    bytes32 public constant ERC721_MINT_BURN = keccak256("ERC721_MINT_BURN");
    bytes32 public constant ERC721_PREMINT = keccak256("ERC721_PREMINT");

    mapping(address => mapping(uint256 => address)) public tokenMap;
    mapping(address => bytes32) public tokenType;
    address public routerAdmin;

    mapping(address => uint256) public fee;

    modifier charge(address token) {
        require(msg.value >= fee[token]);
        _;
    }

    constructor(address routerAdmin_, address anyCallProxy_)
        AnyCallClient(anyCallProxy_)
    {
        routerAdmin = routerAdmin_;
    }

    function setPremintToken(address originToken) public {
        require(msg.sender == routerAdmin);
        tokenType[originToken] = ERC721_PREMINT;
    }

    function setMintBurnToken(address originToken) public {
        require(msg.sender == routerAdmin);
        tokenType[originToken] = ERC721_MINT_BURN;
    }

    function setTokenMap(
        address originToken,
        uint256 toChainId,
        address targetToken
    ) public {
        require(msg.sender == routerAdmin);
        tokenMap[originToken][toChainId] = targetToken;
    }

    function setFee(address token, uint256 fee_) public {
        require(msg.sender == routerAdmin);
        fee[token] = fee_;
    }

    function withdrawFee(address to, uint256 amount) public {
        require(msg.sender == routerAdmin);
        (bool success, ) = to.call{value: amount}("");
        require(success);
    }

    function outbound(
        address token,
        uint256 tokenId,
        address receiver,
        uint256 toChainId
    ) external charge(token) payable {
        if (tokenType[token] == ERC721_MINT_BURN) {
            outboundMintBurn(token, tokenId, receiver, toChainId);
        } else if (tokenType[token] == ERC721_PREMINT) {
            outboundPremint(token, tokenId, receiver, toChainId);
        }
        return;
    }

    function inbound(
        address token,
        uint256 tokenId,
        address from,
        address receiver
    ) external onlyAnyCall {
        if (tokenType[token] == ERC721_MINT_BURN) {
            inboundMintBurn(token, tokenId, from, receiver);
        } else if (tokenType[token] == ERC721_PREMINT) {
            inboundPremint(token, tokenId, from, receiver);
        }
        return;
    }

    function _anyFallback(address to, bytes calldata data) external override onlyAnyCallFallback {
        (address token, uint256 tokenId, address from, ) = abi.decode(
            data[4:],
            (address, uint256, address, address)
        );
        if (tokenType[token] == ERC721_MINT_BURN) {
            _anyFallbackMintBurn(token, tokenId, from);
        } else if (tokenType[token] == ERC721_PREMINT) {
            _anyFallbackPremint(token, tokenId, from);
        }
        return;
    }

    /// @notice Lock in any721 nft or burn underlying nft, emit an outbound log.
    function outboundMintBurn(
        address token,
        uint256 tokenId,
        address receiver,
        uint256 toChainId
    ) internal {
        IERC721Mintburnable(token).burn(tokenId); // require approval
        bytes memory inboundMsg = abi.encodeWithSignature(
            "inbound(address,uint256,address,address)",
            tokenMap[token][toChainId],
            tokenId,
            msg.sender,
            receiver
        );
        AnyCallProxy(anyCallProxy).anyCall(
            counterparts[toChainId],
            inboundMsg,
            address(this),
            toChainId
        );
        emit LogOutbound(token, tokenId, receiver, toChainId);
    }

    /// @notice Call by anycall when there's an outbound log. Unlock underlying nft or mint any721 nft to receiver address.
    function inboundMintBurn(
        address token,
        uint256 tokenId,
        address from,
        address receiver
    ) internal {
        IERC721Mintburnable(token).mint(receiver, tokenId);
        (, uint256 fromChainId) = AnyCallProxy(anyCallProxy).context();
        emit LogInbound(token, tokenId, receiver, fromChainId);
    }

    /// @notice Called by anycall when outbound fails. Return nft to its original owner.
    function _anyFallbackMintBurn(address token, uint256 tokenId, address from)
        internal
    {
        IERC721Mintburnable(token).mint(from, tokenId);
        emit LogOutboundFail(token, tokenId);
    }

    /// @notice Lock in any721 nft or burn underlying nft, emit an outbound log.
    function outboundPremint(
        address token,
        uint256 tokenId,
        address receiver,
        uint256 toChainId
    ) internal {
        IERC721(token).safeTransferFrom(msg.sender, address(this), tokenId);
        bytes memory inboundMsg = abi.encodeWithSignature(
            "inbound(address,uint256,address,address)",
            tokenMap[token][toChainId],
            tokenId,
            msg.sender,
            receiver
        );
        AnyCallProxy(anyCallProxy).anyCall(
            counterparts[toChainId],
            inboundMsg,
            address(this),
            toChainId
        );
        emit LogOutbound(token, tokenId, receiver, toChainId);
    }

    /// @notice Call by anycall when there's an outbound log. Unlock underlying nft or mint any721 nft to receiver address.
    function inboundPremint(
        address token,
        uint256 tokenId,
        address from,
        address receiver
    ) internal {
        IERC721(token).safeTransferFrom(address(this), receiver, tokenId); // asserting tokenId has been premint to this contract
        (, uint256 fromChainId) = AnyCallProxy(anyCallProxy).context();
        emit LogInbound(token, tokenId, receiver, fromChainId);
    }

    /// @notice Called by anycall when outbound fails. Return nft to its original owner.
    function _anyFallbackPremint(address token, uint256 tokenId, address from)
        internal
    {
        IERC721(token).safeTransferFrom(address(this), from, tokenId);
        emit LogOutboundFail(token, tokenId);
    }
}
