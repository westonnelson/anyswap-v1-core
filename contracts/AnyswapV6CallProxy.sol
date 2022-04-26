// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

/// IApp interface of the application
interface IApp {
    /// (required) call on the destination chain to exec the interaction
    function anyExecute(bytes calldata _data) external returns (bool success, bytes memory result);

    /// (optional,advised) call back on the originating chain if the cross chain interaction fails
    function anyFallback(address _to, bytes calldata _data) external;
}

/// anycall proxy is a universal protocal to complete cross-chain interaction.
/// 1. the client call `anyCall` on the originating chain
///         to submit a request for a cross chain interaction
/// 2. the mpc network verify the request and call `anyExec` on the destination chain
///         to execute a cross chain interaction
/// 3. if step 2 failed and step 1 has set non-zero fallback,
///         then call `anyFallback` on the originating chain
contract AnyCallV6Proxy {
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

    // App config
    struct AppConfig {
        address app; // the application contract address
        address appAdmin; // account who admin the application's config
        uint256 appFlags; // flags of the application
    }

    // Flags constant
    uint256 public constant FLAG_PAY_FEE_ON_SRC = 0x1;

    // Extra cost of execution (SSTOREs.SLOADs,ADDs,etc..)
    // TODO: analysis to verify the correct overhead gas usage
    uint256 constant EXECUTION_OVERHEAD = 100000;

    // key is app address
    mapping(address => string) public appIdentifier;

    // key is appID, a unique identifier for each project
    mapping(string => AppConfig) public appConfig;
    mapping(string => mapping(address => bool)) public appWhitelist;
    mapping(string => address[]) public appHistoryWhitelist;
    mapping(string => bool) public appBlacklist;
    mapping(string => uint256) public srcDefaultFees;
    mapping(string => mapping(uint256 => uint256)) public srcFees;

    mapping(address => bool) public isAdmin;
    address[] public admins;

    address public mpc;
    address public pendingMPC;

    bool public freeTestMode;
    bool public paused;

    Context public context;

    uint256 public minReserveBudget;
    mapping(address => uint256) public executionBudget;
    FeeData private _feeData;

    mapping(bytes32 => bool) public execCompleted;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1);
        unlocked = 0;
        _;
        unlocked = 1;
    }

    event LogAnyCall(
        address indexed from,
        address indexed to,
        bytes data,
        address _fallback,
        uint256 indexed toChainID,
        uint256 flags,
        string appID
    );

    event LogAnyExec(
        bytes32 indexed txhash,
        address indexed from,
        address indexed to,
        uint256 fromChainID,
        bool success,
        bytes result
    );

    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);
    event SetBlacklist(string appID, bool flag);
    event SetWhitelist(string appID, address indexed whitelist, bool flag);
    event UpdatePremium(uint256 oldPremium, uint256 newPremium);
    event AddAdmin(address admin);
    event RemoveAdmin(address admin);
    event ChangeMPC(address indexed oldMPC, address indexed newMPC, uint256 timestamp);
    event ApplyMPC(address indexed oldMPC, address indexed newMPC, uint256 timestamp);
    event SetAppConfig(string appID, address indexed app, address indexed appAdmin, uint256 appFlags);

    constructor(
        address _admin,
        address _mpc,
        uint128 _premium,
        bool _freeTestMode
    ) {
        if (_admin != address(0)) {
            isAdmin[_admin] = true;
            admins.push(_admin);
        }
        mpc = _mpc;
        _feeData.premium = _premium;
        freeTestMode = _freeTestMode;

        emit ApplyMPC(address(0), _mpc, block.timestamp);
        emit UpdatePremium(0, _premium);
    }

    /// @dev Access control function
    modifier onlyMPC() {
        require(msg.sender == mpc); // dev: only MPC
        _;
    }

    /// @dev Access control function
    modifier onlyAdmin() {
        require(isAdmin[msg.sender]); // dev: only admin
        _;
    }

    /// @dev pausable control function
    modifier whenNotPaused() {
        require(!paused); // dev: when not paused
        _;
    }

    /// @dev set paused flag to pause/unpause functions
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
    }

    function _paySrcFees(uint256 fees) internal {
        require(msg.value >= fees);
        if (fees > 0) { // pay fees
            (bool success,) = mpc.call{value: fees}("");
            require(success);
        }
        if (msg.value > fees) { // return remaining amount
            (bool success,) = msg.sender.call{value: msg.value - fees}("");
            require(success);
        }
    }

    /**
        @notice Submit a request for a cross chain interaction
        @param _to The target to interact with on `_toChainID`
        @param _data The calldata supplied for the interaction with `_to`
        @param _fallback The address to call back on the originating chain
            if the cross chain interaction fails
            for security reason, it must be zero or `msg.sender` address
        @param _toChainID The target chain id to interact with
    */
    function anyCall(
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _toChainID
    ) external payable whenNotPaused {
        require(_fallback == address(0) || _fallback == msg.sender);
        string memory _appID = appIdentifier[msg.sender];

        uint256 _flags;

        if (!freeTestMode) {
            require(!appBlacklist[_appID]); // dev: app is blacklisted

            AppConfig storage config = appConfig[_appID];
            require(msg.sender == config.app); // dev: app not exist

            _flags = config.appFlags;
            if (_flags & FLAG_PAY_FEE_ON_SRC == FLAG_PAY_FEE_ON_SRC) {
                uint256 fees = calcSrcFees(_appID, _toChainID);
                _paySrcFees(fees);
            }
        }

        emit LogAnyCall(msg.sender, _to, _data, _fallback, _toChainID, _flags, _appID);
    }

    /**
        @notice Execute a cross chain interaction
        @dev Only callable by the MPC
        @param _from The request originator
        @param _to The cross chain interaction target
        @param _data The calldata supplied for interacting with target
        @param _fallback The address to call on `_fromChainID` if the interaction fails
        @param _fromChainID The originating chain id
        @param _flags The flags of app on the originating chain
        @param _txhash The corresponding `anyCall` tx hash
        @param _appID The app identifier to check whitelist
    */
    function anyExec(
        address _from,
        address _to,
        bytes calldata _data,
        address _fallback,
        uint256 _fromChainID,
        string calldata _appID,
        uint256 _flags,
        bytes32 _txhash
    ) external lock whenNotPaused onlyMPC {
        uint256 gasUsed;

        if (!freeTestMode) {
            require(appWhitelist[_appID][_to]); // dev: request denied

            // Prepare charge fee on the destination chain
            if ((_flags & FLAG_PAY_FEE_ON_SRC) == 0x0) {
                require(executionBudget[_from] >= minReserveBudget);
                gasUsed = gasleft() + EXECUTION_OVERHEAD;
            }
        }

        require(!execCompleted[_txhash], "exec completed");
        require(_fallback == address(0) || _fallback == _from);
        require(!appBlacklist[_appID]); // dev: app is blacklisted

        // Exec in block to prevent Stack too deep
        bool success;
        {
            bytes memory result;

            context = Context({sender: _from, fromChainID: _fromChainID});
            (success, result) = IApp(_to).anyExecute(_data);
            context = Context({sender: address(0), fromChainID: 0});

            execCompleted[_txhash] = true;

            emit LogAnyExec(_txhash, _from, _to, _fromChainID, success, result);
        }

        // Call the fallback on the originating chain with the call information (to, data)
        if (!success && _fallback != address(0)) {
            bytes memory _fallbackCallData = abi.encodeWithSelector(IApp.anyFallback.selector, _to, _data);
            emit LogAnyCall(_from, _fallback, _fallbackCallData, address(0), _fromChainID, 0, _appID);
        }

        // Charge fee on the dest chain
        if (gasUsed > 0) {
            uint256 totalCost = (gasUsed - gasleft()) * (tx.gasprice + _feeData.premium);
            executionBudget[_from] -= totalCost;
            _feeData.accruedFees += uint128(totalCost);
        }
    }

    /// @notice Deposit native currency crediting `_account` for execution costs on this chain
    /// @param _account The account to deposit and credit for
    function deposit(address _account) external payable {
        executionBudget[_account] += msg.value;
        emit Deposit(_account, msg.value);
    }

    /// @notice Withdraw a previous deposit from your account
    /// @param _amount The amount to withdraw from your account
    function withdraw(uint256 _amount) external {
        executionBudget[msg.sender] -= _amount;
        emit Withdraw(msg.sender, _amount);
        (bool success,) = msg.sender.call{value: _amount}("");
        require(success);
    }

    /// @notice Withdraw all accrued execution fees
    /// @dev The MPC is credited in the native currency
    function withdrawAccruedFees() external {
        uint256 fees = _feeData.accruedFees;
        _feeData.accruedFees = 0;
        (bool success,) = mpc.call{value: fees}("");
        require(success);
    }

    /// @notice Set app blacklist
    function setBlacklist(string calldata _appID, bool _flag) external onlyAdmin {
        appBlacklist[_appID] = _flag;
        emit SetBlacklist(_appID, _flag);
    }

    /// @notice Set app blacklist in batch
    function setBlacklists(string[] calldata _appIDs, bool _flag) external onlyAdmin {
        for (uint256 i = 0; i < _appIDs.length; i++) {
            this.setBlacklist(_appIDs[i], _flag);
        }
    }

    /// @notice Set the premimum for cross chain executions
    /// @param _premium The premium per gas
    function setPremium(uint128 _premium) external onlyMPC {
        emit UpdatePremium(_feeData.premium, _premium);
        _feeData.premium = _premium;
    }

    /// @notice Set minimum exection budget for cross chain executions
    /// @param _minBudget The minimum exection budget
    function setMinReserveBudget(uint128 _minBudget) external onlyMPC {
        minReserveBudget = _minBudget;
    }


    /// @notice Change mpc
    function changeMPC(address _mpc) external onlyMPC {
        pendingMPC = _mpc;
        emit ChangeMPC(mpc, _mpc, block.timestamp);
    }

    /// @notice Apply mpc
    function applyMPC() external {
        require(msg.sender == pendingMPC);
        emit ApplyMPC(mpc, pendingMPC, block.timestamp);
        mpc = pendingMPC;
        pendingMPC = address(0);
    }

    /// @notice Get the total accrued fees in native currency
    /// @dev Fees increase when executing cross chain requests
    function accruedFees() external view returns(uint128) {
        return _feeData.accruedFees;
    }

    /// @notice Get the gas premium cost
    /// @dev This is similar to priority fee in eip-1559, except instead of going
    ///     to the miner it is given to the MPC executing cross chain requests
    function premium() external view returns(uint128) {
        return _feeData.premium;
    }

    /// @notice Add admin
    function addAdmin(address _admin) external onlyMPC {
        require(!isAdmin[_admin]);
        isAdmin[_admin] = true;
        admins.push(_admin);
        emit AddAdmin(_admin);
    }

    /// @notice Remove admin
    function removeAdmin(address _admin) external onlyMPC {
        require(isAdmin[_admin]);
        isAdmin[_admin] = false;
        uint256 length = admins.length;
        for (uint256 i = 0; i < length - 1; i++) {
            if (admins[i] == _admin) {
                admins[i] = admins[length - 1];
                break;
            }
        }
        admins.pop();
        emit RemoveAdmin(_admin);
    }

    /// @notice Get all admins
    function getAllAdmins() external view returns (address[] memory) {
        return admins;
    }

    /// @notice Init app config
    function initAppConfig(
        string calldata _appID,
        address _app,
        address _admin,
        uint256 _flags,
        address[] calldata _whitelist,
        uint256 _defaultFees,
        uint256[] calldata _toChainIDs,
        uint256[] calldata _fees
    ) external onlyMPC {
        require(bytes(_appID).length > 0); // dev: empty appID
        require(_app != address(0)); // dev: zero app address
        appIdentifier[_app] = _appID;

        AppConfig storage config = appConfig[_appID];

        config.app = _app;
        config.appAdmin = _admin;
        config.appFlags = _flags;

        if (_whitelist.length > 0) {
            _setAppWhitelist(_appID, _whitelist, true);
        }

        if ((_flags & FLAG_PAY_FEE_ON_SRC) == FLAG_PAY_FEE_ON_SRC) {
            srcDefaultFees[_appID] = _defaultFees;
            _setSrcFees(_appID, _toChainIDs, _fees);
        }

        emit SetAppConfig(_appID, _app, _admin, _flags);
    }

    /// @notice Update app config
    /// can be operated only by mpc or app admin
    /// the config.app will always keep unchanged here
    function updateAppConfig(
        address _app,
        address _admin,
        uint256 _flags,
        address[] calldata _whitelist
    ) external {
        string memory _appID = appIdentifier[_app];
        AppConfig storage config = appConfig[_appID];

        require(config.app == _app && _app != address(0)); // dev: app not exist
        require(msg.sender == mpc || msg.sender == config.appAdmin);

        if (_admin != address(0)) {
            config.appAdmin = _admin;
        }
        config.appFlags = _flags;
        if (_whitelist.length > 0) {
            _setAppWhitelist(_appID, _whitelist, true);
        }

        emit SetAppConfig(_appID, _app, _admin, _flags);
    }

    // @notice Add whitelist
    function addWhitelist(address _app, address[] memory _whitelist) external {
        string memory _appID = appIdentifier[_app];
        AppConfig storage config = appConfig[_appID];

        require(config.app == _app && _app != address(0)); // dev: app not exist
        require(msg.sender == mpc || msg.sender == config.appAdmin);

        _setAppWhitelist(_appID, _whitelist, true);
    }

    // @notice Remove whitelist
    function removeWhitelist(address _app, address[] memory _whitelist) external {
        string memory _appID = appIdentifier[_app];
        AppConfig storage config = appConfig[_appID];

        require(config.app == _app && _app != address(0)); // dev: app not exist
        require(msg.sender == mpc || msg.sender == config.appAdmin);

        _setAppWhitelist(_appID, _whitelist, false);
    }

    function _setAppWhitelist(string memory _appID, address[] memory _whitelist, bool _flag) internal {
        mapping(address => bool) storage whitelist = appWhitelist[_appID];
        address[] storage historyWhitelist = appHistoryWhitelist[_appID];
        address addr;
        for (uint256 i = 0; i < _whitelist.length; i++) {
            addr = _whitelist[i];
            if (whitelist[addr] == _flag) {
                continue;
            }
            if (_flag) {
                historyWhitelist.push(addr);
            }
            whitelist[addr] = _flag;
            emit SetWhitelist(_appID, addr, _flag);
        }
    }

    /// @notice Get history whitelist length
    function getHistoryWhitelistLength(string memory _appID) external view returns (uint256) {
        return appHistoryWhitelist[_appID].length;
    }

    /// @notice Get all history whitelist
    function getAllHistoryWhitelist(string memory _appID) external view returns (address[] memory) {
        return appHistoryWhitelist[_appID];
    }

    /// @notice Tidy history whitelist to be same with actual whitelist
    function tidyHistoryWhitelist(string memory _appID) external {
        mapping(address => bool) storage actualWhitelist = appWhitelist[_appID];
        address[] storage historyWhitelist = appHistoryWhitelist[_appID];
        uint256 histLength = historyWhitelist.length;
        uint256 popIndex = histLength;
        address addr;
        for (uint256 i = 0; i < popIndex; ) {
            addr = historyWhitelist[i];
            if (actualWhitelist[addr]) {
                i++;
            } else {
                popIndex--;
                historyWhitelist[i] = historyWhitelist[popIndex];
            }
        }
        for (uint256 i = popIndex; i < histLength; i++) {
            historyWhitelist.pop();
        }
    }

    /// @notice Set fee config
    function setSrcFeeConfig(
        address _app,
        uint256 _defaultFees,
        uint256[] calldata _toChainIDs,
        uint256[] calldata _fees
    ) external onlyAdmin {
        string memory _appID = appIdentifier[_app];
        AppConfig storage config = appConfig[_appID];
        require(config.app == _app && _app != address(0)); // dev: app not exist

        srcDefaultFees[_appID] = _defaultFees;
        _setSrcFees(_appID, _toChainIDs, _fees);
    }

    function _setSrcFees(
        string memory _appID,
        uint256[] calldata _toChainIDs,
        uint256[] calldata _fees
    ) internal {
        uint256 length = _toChainIDs.length;
        require(length == _fees.length);
        if (length == 0) {
            return;
        }
        mapping(uint256 => uint256) storage _srcFees = srcFees[_appID];
        for (uint256 i = 0; i < length; i++) {
            _srcFees[_toChainIDs[i]] = _fees[i];
        }
    }

    /// @notice Calc fees
    function calcSrcFees(
        string memory _appID,
        uint256 _toChainID
    ) public view returns (uint256) {
        uint256 fees = srcFees[_appID][_toChainID];
        if (fees == 0) {
            fees = srcDefaultFees[_appID];
        }
        return fees;
    }
}
