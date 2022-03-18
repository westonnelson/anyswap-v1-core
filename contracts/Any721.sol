// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

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

contract Any721 is ERC721Enumerable, AnyCallClient {
  address underlying;

  event LogDeposit(address user, uint tokenId);
  event LogWithdraw(address user, uint tokenId);
  event LogOutbound(uint tokenId, address receiver, uint toChainId);
  event LogInbound(uint tokenId, address receiver, uint fromChainId);
  event LogOutboundFail(uint256 tokenId);

  constructor (string memory name_, string memory symbol_, address underlying_, address anyCallProxy_) ERC721(name_, symbol_) AnyCallClient(anyCallProxy_) {
    underlying = underlying_;
  }

  /// @notice Get extra data bind to tokenId.
  function getExtraData(uint tokenId) external pure returns(bytes memory packedData) {
    /// @dev pack extra data into string
    packedData = "any extra data";
    return packedData;
  }

  /// @notice Set extra data.
  function setExtraData(uint tokenId, bytes memory extraData) internal {
    if (underlying == address(0)) {
      /// @dev unpack extra data and bind it with tokenId
    } else {
      /// @dev unpack extra data and bind it with tokenId
    }
    return;
  }

  /// @notice Deposit underlying 721 nft to this contract and get any721 nft.
  /// @param tokenId Underlying nft id, which is also any721 nft id.
  function deposit(uint tokenId) external {
    IERC721(underlying).safeTransferFrom(msg.sender, address(this), tokenId);
    _safeMint(msg.sender, tokenId);
    emit LogDeposit(msg.sender, tokenId);
  }

  /// @notice Withdraw underlying 721 nft and burn the any721 nft.
  /// @param tokenId Underlying nft id, which is also any721 nft id.
  function withdraw(uint tokenId) external {
    require(msg.sender == ownerOf(tokenId));
    _burn(tokenId);
    IERC721(underlying).safeTransferFrom(address(this), msg.sender, tokenId);
    emit LogWithdraw(msg.sender, tokenId);
  }

  /// @notice Lock in any721 nft or burn underlying nft, emit an outbound log.
  function outbound(uint tokenId, address receiver, uint toChainId) external {
    if (underlying == address(0)) {
      require(msg.sender == ownerOf(tokenId));
      _burn(tokenId);
    } else {
      require(!_exists(tokenId));
      IERC721(underlying).safeTransferFrom(msg.sender, address(this), tokenId);
    }
    bytes memory extraData = this.getExtraData(tokenId);
    bytes memory inboundMsg = abi.encodeWithSignature("inbound(uint256,address,address,bytes)", tokenId, msg.sender, receiver, extraData);
    AnyCallProxy(anyCallProxy).anyCall(targets[toChainId], inboundMsg, address(this), toChainId);
    emit LogOutbound(tokenId, receiver, toChainId);
  }

  /// @notice Call by anycall when there's an outbound log. Unlock underlying nft or mint any721 nft to receiver address.
  function inbound(uint tokenId, address from, address receiver, bytes memory extraData) onlyAnyCall external {
    if (underlying == address(0)) {
      _safeMint(msg.sender, tokenId);
    } else {
      require(!_exists(tokenId));
      IERC721(underlying).safeTransferFrom(address(this), receiver, tokenId);
    }
    setExtraData(tokenId, extraData);
    (, uint256 fromChainId) = AnyCallProxy(anyCallProxy).context();
    emit LogInbound(tokenId, receiver, fromChainId);
  }

  /// @notice Called by anycall when outbound fails. Return nft to its original owner.
  function anyFallback(address to, bytes calldata data) external onlyAnyCall {
    (uint256 tokenId, address from, , bytes memory extraData) = abi.decode(data[4:], (uint256, address, address, bytes));
    if (underlying == address(0)) {
      _safeMint(msg.sender, tokenId);
    } else {
      require(!_exists(tokenId));
      IERC721(underlying).safeTransferFrom(address(this), from, tokenId);
    }
    setExtraData(tokenId, extraData);
    emit LogOutboundFail(tokenId);
  }
}
