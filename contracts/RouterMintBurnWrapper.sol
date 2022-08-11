// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.10;

// ITokenMintBurn is the interface the target token to be wrapped actually supports.
// We should adjust these functions according to the token itself,
// and wrapper them to support `IRouterMintBurn`
// Notice: the parameters and return type should be same
interface ITokenMintBurn {
    function mint(address to, uint256 amount) external returns (bool);
    function burnFrom(address from, uint256 amount) external returns (bool);
}

// IRouterMintBurn is required for Multichain Router
// Notice: the parameters and return type should be same
interface IRouterMintBurn {
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from, uint256 amount) external returns (bool);
}

// TokenType token type enumerations
// When in `need approve` situations, the user should approve to this wrapper contract,
// not to the Router contract, and not to the target token to be wrapped.
// If not, this wrapper will fail its function.
enum TokenType {
    MintBurnAny,  // mint and burn(address from, uint256 amount), don't need approve
    MintBurnFrom, // mint and burnFrom(address from, uint256 amount), need approve
    MintBurnSelf, // mint and burn(uint256 amount), call transferFrom first, need approve
    Transfer,     // transfer and transferFrom, need approve
    TransferDeposit, // transfer and transferFrom, deposit and withdraw, need approve, block when lack of liquidity
    TransferDeposit2 // transfer and transferFrom, deposit and withdraw, need approve, don't block when lack of liquidity
}

// RouterMintBurnWrapper is a wrapper for token that supports `ITokenMintBurn` to support `IRouterMintBurn`
contract RouterMintBurnWrapper is IRouterMintBurn {
    // the target token to be wrapped, must support `ITokenMintBurn`
    address public immutable token;
    TokenType public constant tokenType = TokenType.MintBurnFrom;

    // set of minters, can be this bridge or other bridges
    mapping(address => bool) public isMinter;
    address[] public minters;

    // primary controller of this contract
    address public vault;

    modifier onlyAuth() {
        require(isMinter[msg.sender], "onlyAuth");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "onlyVault");
        _;
    }

    event LogChangeVault(address indexed oldVault, address indexed newVault, uint indexed effectiveTime);

    constructor(address _token, address _vault) {
        require(_token != address(0) && _token != address(this), "zero token address");
        token = _token;

        require(_vault != address(0), "zero vault address");
        vault = _vault;
    }

    function changeVault(address newVault) external onlyVault returns (bool) {
        require(newVault != address(0), "zero vault address");
        emit LogChangeVault(vault, newVault, block.timestamp);
        vault = newVault;
        return true;
    }

    function addMinter(address _minter) external onlyVault {
        require(_minter != address(0), "zero minter address");
        require(!isMinter[_minter], "minter exists");
        isMinter[_minter] = true;
        minters.push(_minter);
    }

    function revokeMinter(address _minter) external onlyVault {
        require(isMinter[_minter], "minter not exists");
        isMinter[_minter] = false;
    }

    function getAllMinters() external view returns (address[] memory) {
        return minters;
    }

    function mint(address to, uint256 amount) external onlyAuth returns (bool) {
        assert(ITokenMintBurn(token).mint(to, amount));
        return true;
    }

    function burn(address from, uint256 amount) external onlyAuth returns (bool) {
        assert(ITokenMintBurn(token).burnFrom(from, amount));
        return true;
    }
}
