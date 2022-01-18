// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.6;

// MPC management means multi-party validation.
// MPC signing likes Multi-Signature is more secure than use private key directly.
abstract contract MPCManageable {
    address public mpc;
    address public pendingMPC;

    uint256 public constant delay = 2 days;
    uint256 public delayMPC;

    modifier onlyMPC() {
        require(msg.sender == mpc, "MPC: only mpc");
        _;
    }

    event LogChangeMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 effectiveTime);

    event LogApplyMPC(
        address indexed oldMPC,
        address indexed newMPC,
        uint256 applyTime);

    constructor(address _mpc) {
        require(_mpc != address(0), "MPC: mpc is the zero address");
        mpc = _mpc;
        emit LogChangeMPC(address(0), mpc, block.timestamp);
    }

    function changeMPC(address _mpc) external onlyMPC {
        require(_mpc != address(0), "MPC: mpc is the zero address");
        pendingMPC = _mpc;
        delayMPC = block.timestamp + delay;
        emit LogChangeMPC(mpc, pendingMPC, delayMPC);
    }

    function applyMPC() external {
        require(msg.sender == pendingMPC, "MPC: only pendingMPC");
        require(block.timestamp >= delayMPC, "MPC: time before delayMPC");
        emit LogApplyMPC(mpc, pendingMPC, block.timestamp);
        mpc = pendingMPC;
        pendingMPC = address(0);
        delayMPC = 0;
    }
}

// support limit operations to whitelist
abstract contract Whitelistable is MPCManageable {
    mapping(address => mapping(uint256 => mapping(address => bool))) public isInWhitelist;
    mapping(address => mapping(uint256 => address[])) public whitelists;
    mapping(address => bool) public isBlacklisted;

    event LogSetWhitelist(address indexed from, uint256 indexed chainID, address indexed to, bool flag);

    modifier onlyWhitelisted(address from, uint256 chainID, address[] memory to) {
        mapping(address => bool) storage map = isInWhitelist[from][chainID];
        for (uint256 i = 0; i < to.length; i++) {
            require(map[to[i]], "AnyCall: to address is not in whitelist");
        }
        _;
    }

    constructor(address _mpc) MPCManageable(_mpc) {}

    /**
        @notice Query the number of elements in the whitelist of `whitelists[from][chainID]`
        @param from The initiator of a cross chain interaction
        @param chainID The target chain's identifier
        @return uint256 The length of addresses `from` is allowed to call on `chainID`
    */
    function whitelistLength(address from, uint256 chainID) external view returns (uint256) {
        return whitelists[from][chainID].length;
    }

    /**
        @notice Approve/Revoke a caller's permissions to initiate a cross chain interaction
        @param from The initiator of a cross chain interaction
        @param chainID The target chain's identifier
        @param to The address of the target `from` is being allowed/disallowed to call
        @param flag Boolean denoting whether permissions is being granted/denied
    */
    function whitelist(address from, uint256 chainID, address to, bool flag) external onlyMPC {
        require(isInWhitelist[from][chainID][to] != flag, "nothing change");
        address[] storage list = whitelists[from][chainID];
        if (flag) {
            list.push(to);
        } else {
            uint256 length = list.length;
            for (uint i = 0; i < length; i++) {
                if (list[i] == to) {
                    if (i + 1 < length) {
                        list[i] = list[length-1];
                    }
                    list.pop();
                    break;
                }
            }
        }
        isInWhitelist[from][chainID][to] = flag;
        emit LogSetWhitelist(from, chainID, to, flag);
    }

    function blacklist(address account, bool flag) external onlyMPC {
        isBlacklisted[account] = flag;
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IBillManager {
    function billCaller(address caller) external;
    function billTarget(address target, uint256 cost) external;
}

contract MultichainBillManager {
    event FundTarget(address indexed beneficiary, address indexed funder, uint256 amount);
    event FundCaller(address indexed beneficiary, address indexed funder, address indexed token, uint256 amount);

    mapping(address => bool) public payByOriginator; // key is caller, value is if call is paid by tx originator or not
    mapping(address => address) public callerFeeTokens; // key is caller, value is erc20 token address
    mapping(address => uint256) public feePerCall; // fee per call
    mapping(address => int256) public callerFunds; // caller funds (erc20 token funded)
    mapping(address => int256) public targetFunds; // target funds (native token funded)

    mapping(address => uint256) public tokenExpenses; // erc20 token used by caller
    uint256 public expenses; // native token used by target

    address public admin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "must admin");
        _;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function billCaller(address caller) external {
        if (payByOriginator[caller]) {
            IERC20(callerFeeTokens[caller]).transferFrom(tx.origin, address(this), feePerCall[caller]);
            tokenExpenses[callerFeeTokens[caller]] += feePerCall[caller];
            return;
        }
        require(callerFunds[caller] > 0, "insufficient balance");
        uint256 fee = feePerCall[caller];
        callerFunds[caller] -= int256(fee);
        tokenExpenses[callerFeeTokens[caller]] += fee;
    }

    function billTarget(address target, uint256 gasUsed) external {
        uint256 cost = gasUsed * tx.gasprice;
        require(targetFunds[target] > 0, "insufficient balance");
        targetFunds[target] -= int256(cost); // potential insufficient balances
        expenses += cost;
    }

    function setPayByOriginator(address caller, bool _payByOriginator) external onlyAdmin {
        payByOriginator[caller] = _payByOriginator;
    }

    function setCallerFee(address caller, address token, uint256 tokenPerCall) external onlyAdmin {
        callerFeeTokens[caller] = token;
        feePerCall[caller] = tokenPerCall;
    }

    function fundCaller(address caller, uint256 amount) external {
        IERC20(callerFeeTokens[caller]).transferFrom(msg.sender, address(this), amount);
        callerFunds[caller] += int256(amount);
        emit FundCaller(caller, caller, callerFeeTokens[caller], amount);
    }

    function fundTarget(address funder) external payable {
        targetFunds[funder] += int256(msg.value);
        emit FundTarget(funder, funder, msg.value);
    }

    function refundNative(address receiver) external onlyAdmin {
        uint256 amount = expenses;
        if (address(this).balance >= amount) {
            expenses = 0;
            receiver.call{value: amount}("");
        } else {
            expenses = amount - address(this).balance;
            receiver.call{value: address(this).balance}("");
        }
    }

    function refundToken(address token, address receiver) external onlyAdmin {
        uint256 amount = tokenExpenses[token];
        if (IERC20(token).balanceOf(address(this)) >= amount) {
            tokenExpenses[token] = 0;
            IERC20(token).transfer(receiver, amount);
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            tokenExpenses[token] = amount - balance;
            IERC20(token).transfer(receiver, balance);
        }
    }
}

abstract contract Billable is Whitelistable {
    address public billManager;

    modifier billCaller(address caller) {
        IBillManager(billManager).billCaller(caller);
        _;
    }

    modifier billTarget(address[] memory targets) {
        uint256 gas = gasleft();
        _;
        uint256 gasUsed = (gas - gasleft());
        for (uint8 i = 0; i < targets.length; i++) {
            IBillManager(billManager).billTarget(targets[i], gasUsed);
        }
    }

    constructor(address _billManager) {
        billManager = _billManager;
    }

    function changeBillManager(address newBillManager) external onlyMPC {
        billManager = newBillManager;
    }
}

contract AnyCallProxy is Billable {
    event LogAnyCall(address indexed from, address[] to, bytes[] data,
                     address[] fallbacks, uint256[] nonces, uint256 fromChainID, uint256 toChainID);
    event LogAnyExec(address indexed from, address[] to, bytes[] data, bool[] success, bytes[] result,
                     address[] fallbacks, uint256[] nonces, uint256 fromChainID, uint256 toChainID);

    struct Context {
        address sender;
        uint256 fromChainID;
    }

    Context public context;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'AnyCall: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor(address _mpc, address _billManager) Whitelistable(_mpc) Billable(_billManager) {}

    // @notice Query the chainID of this contract
    // @dev Implemented as a view function so it is less expensive. CHAINID < PUSH32
    function cID() external view returns (uint256) {
        return block.chainid;
    }

    /**
        @notice Trigger a cross-chain contract interaction
        @param to - list of addresses to call
        @param data - list of data payloads to send / call
        @param fallbacks - the fallbacks on the fromChainID to call when target chain call fails
        `anyCallFallback(uint256 nonce)`
        @param nonces - the nonces (ordering) to include for the resulting fallback
        @param toChainID - the recipient chain that will receive the events
    */
    function anyCall(
        address[] memory to,
        bytes[] memory data,
        address[] memory fallbacks,
        uint256[] memory nonces,
        uint256 toChainID
    ) external onlyWhitelisted(msg.sender, toChainID, to) billCaller(msg.sender) {
        require(toChainID != block.chainid, "AnyCall: FORBID");
        require(!isBlacklisted[msg.sender]);
        emit LogAnyCall(msg.sender, to, data, fallbacks, nonces, block.chainid, toChainID);
    }

    function anyCall(
        address from,
        address[] memory to,
        bytes[] memory data,
        address[] memory fallbacks,
        uint256[] memory nonces,
        uint256 fromChainID
    ) external billTarget(to) onlyMPC lock {
        require(from != address(this) && from != address(0), "AnyCall: FORBID");
        require(!isBlacklisted[from]);

        uint256 length = to.length;
        bool[] memory success = new bool[](length);
        bytes[] memory results = new bytes[](length);

        context = Context({sender: from, fromChainID: fromChainID});

        for (uint256 i = 0; i < length; i++) {
            address _to = to[i];
            if (isInWhitelist[from][block.chainid][_to]) {
                (success[i], results[i]) = _to.call{value:0}(data[i]);
            } else {
                (success[i], results[i]) = (false, "forbid calling");
            }
        }
        context = Context({sender: from, fromChainID: 0});
        emit LogAnyExec(from, to, data, success, results, fallbacks, nonces, fromChainID, block.chainid);
    }
}