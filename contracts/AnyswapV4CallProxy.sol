// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

contract AnyCallProxy {
    // Context information for destination chain targets
    struct Context {
        address sender;
        uint256 fromChainID;
    }

    // Packed fee information (only 1 storage slot)
    struct FeeData {
        uint128 accruedFees;
        uint128 premium;
    }

    // Packed MPC transfer info (only 1 storage slot)
    struct TransferData {
        uint96 effectiveTime;
        address pendingMPC;
    }

    // Extra cost of execution (SSTOREs.SLOADs,ADDs,etc..)
    uint256 constant EXECUTION_OVERHEAD = 100000;
    // Delay for ownership transfer
    uint256 constant TRANSFER_DELAY = 2 days;

    address public mpc;
    TransferData private _transferData;

    mapping(address => bool) public blacklist;
    mapping(address => mapping(address => mapping(uint256 => bool))) public whitelist;
    
    Context public context;

    mapping(address => uint256) public executionBudget;
    FeeData private _feeData;

    event AnyCall(
        address indexed from,
        address indexed to,
        bytes data,
        address callback,
        uint256 indexed toChainID
    );

    event AnyExec(
        address indexed from,
        address indexed to,
        bytes data,
        bool success,
        bytes result,
        address callback,
        uint256 indexed fromChainID
    );

    event AnyCallback(
        address indexed from,
        address indexed to,
        bytes data,
        bool success,
        bytes result,
        uint256 indexed toChainID,
        bool callbackSuccess,
        bytes callbackResult
    );

    event Deposit(address indexed account, uint256 amount);
    event Withdrawl(address indexed account, uint256 amount);
    event SetBlacklist(address indexed account, bool flag);
    event SetWhitelist(
        address indexed from,
        address indexed to,
        uint256 indexed toChainID,
        bool flag
    );
    event TransferMPC(address oldMPC, address newMPC, uint256 effectiveTime);
    event UpdatePremium(uint256 oldPremium, uint256 newPremium);

    constructor(address _mpc, uint128 _premium) {
        mpc = _mpc;
        _feeData.premium = _premium;

        emit TransferMPC(address(0), _mpc, block.timestamp);
        emit UpdatePremium(0, _premium);
    }

    modifier onlyMPC() {
        require(msg.sender == mpc); // dev: only MPC
        _;
    }

    modifier charge(address _from) {
        uint256 gasUsed = gasleft() + EXECUTION_OVERHEAD;
        _;
        uint256 totalCost = (gasUsed - gasleft()) * (tx.gasprice + _feeData.premium);

        executionBudget[_from] -= totalCost;
        _feeData.accruedFees += uint128(totalCost);
    }

    /**
        @notice Submit a request for a cross chain interaction
        @param _to The target to interact with on `_toChainID`
        @param _data The calldata supplied for the interaction with `_to`
        @param _callback The address to call back on the originating chain
            with execution information about the cross chain interaction
        @param _toChainID The target chain id to interact with
    */
    function anyCall(
        address _to,
        bytes calldata _data,
        address _callback,
        uint256 _toChainID
    ) external {
        require(!blacklist[msg.sender]); // dev: caller is blacklisted
        require(whitelist[msg.sender][_to][_toChainID]); // dev: request denied

        emit AnyCall(msg.sender, _to, _data, _callback, _toChainID);
    }

    function anyExec(
        address _from,
        address _to,
        bytes calldata _data,
        address _callback,
        uint256 _fromChainID
    ) external charge(_from) onlyMPC {
        context = Context({sender: _from, fromChainID: _fromChainID});
        (bool success, bytes memory result) = _to.call(_data);
        context = Context({sender: address(0), fromChainID: 0});

        emit AnyExec(_from, _to, _data, success, result, _callback, _fromChainID);
    }

    function deposit(address _account) external payable {
        executionBudget[_account] += msg.value;
        emit Deposit(_account, msg.value);
    }

    function withdraw(uint256 _amount) external {
        executionBudget[msg.sender] -= _amount;
        emit Withdrawl(msg.sender, _amount);
        msg.sender.call{value: _amount}("");
    }

    function withdrawAccruedFees() external {
        uint256 fees = _feeData.accruedFees;
        _feeData.accruedFees = 0;
        mpc.call{value: fees}("");
    }

    function setWhitelist(
        address _from,
        address _to,
        uint256 _toChainID,
        bool _flag
    ) external onlyMPC {
        whitelist[_from][_to][_toChainID] = _flag;
        emit SetWhitelist(_from, _to, _toChainID, _flag);
    }

    function setBlacklist(address _account, bool _flag) external onlyMPC {
        blacklist[_account] = _flag;
        emit SetBlacklist(_account, _flag);
    }

    function setPremium(uint128 _premium) external onlyMPC {
        emit UpdatePremium(_feeData.premium, _premium);
        _feeData.premium = _premium;
    }

    function changeMPC(address _newMPC) external onlyMPC {
        _transferData = TransferData({
            effectiveTime: uint96(block.timestamp + TRANSFER_DELAY),
            pendingMPC: _newMPC
        });
        emit TransferMPC(mpc, _newMPC, block.timestamp + TRANSFER_DELAY);
    }

    function accruedFees() external view returns(uint128) {
        return _feeData.accruedFees;
    }

    function premium() external view returns(uint128) {
        return _feeData.premium;
    }

    function effectiveTime() external view returns(uint256) {
        return _transferData.effectiveTime;
    }
    
    function pendingMPC() external view returns(address) {
        return _transferData.pendingMPC;
    }
}
