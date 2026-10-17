// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../governance/GovernanceOwnable.sol";

/**
 * @title TreasuryAccounting
 * @dev Implements full protocol treasury accounting with mathematical invariants
 * @notice Every token movement must preserve the fundamental accounting equation:
 *         totalAssets = stakingReserve + rewardsPool + protocolFees + governanceReserves + ecosystemFund
 *         This ensures complete auditability and protocol solvency
 */
contract TreasuryAccounting is AccessControl, ReentrancyGuard, GovernanceOwnable {
    using SafeERC20 for IERC20;

    // ============ ROLES ============
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    bytes32 public constant REWARD_ENGINE_ROLE = keccak256("REWARD_ENGINE_ROLE");
    bytes32 public constant SLASHING_CONTRACT_ROLE = keccak256("SLASHING_CONTRACT_ROLE");

    // ============ ACCOUNTING CATEGORIES ============

    enum TreasuryAccount {
        STAKING_RESERVE,      // Tokens actively staked by users
        REWARDS_POOL,         // Reserved for reward distribution
        PROTOCOL_FEES,        // Accumulated protocol fees
        GOVERNANCE_RESERVES,  // Governance-controlled reserve fund
        ECOSYSTEM_FUND,       // Future ecosystem development fund
        SLASHED_TREASURY,     // Tokens slashed from verifiers
        EXTERNAL              // Off-ledger source or destination marker
    }

    // ============ STRUCTS ============

    struct AccountSnapshot {
        uint256 timestamp;
        uint256 blockNumber;
        uint256[6] balances;  // Mirrors TreasuryAccount enum order
        uint256 totalAssets;
        address snapshotSender;
    }

    struct TokenMovement {
        uint256 timestamp;
        address from;
        address to;
        uint256 amount;
        TreasuryAccount fromAccount;
        TreasuryAccount toAccount;
        string movementType;
        bytes32 transactionId;
    }

    // ============ STATE VARIABLES ============

    // The protocol's main token
    IERC20 public immutable protocolToken;

    // Accounting balances for each treasury account (indexed by TreasuryAccount enum)
    uint256[6] private _accountBalances;

    // Historical snapshots for auditing
    AccountSnapshot[] public snapshots;
    uint256 public snapshotCount;

    // Transaction history
    mapping(bytes32 => TokenMovement) public transactions;
    bytes32[] public transactionIds;
    uint256 public transactionCount;

    // Accounting invariants configuration (percentage allocations)
    uint256 public constant PERCENT_DENOMINATOR = 10000; // Basis points (100% = 10000)
    uint256 public maxRewardsWithdrawalBPS = 500;        // Max 5% of rewards pool per withdrawal
    uint256 public minStakingReserveRatio = 1000;         // Min 10% of total assets must be in staking reserve

    // Track last transaction for each account to prevent double-spending
    mapping(TreasuryAccount => uint256) public lastTransactionBlock;

    // ============ EVENTS ============

    event FundsTransferred(
        bytes32 indexed transactionId,
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        address indexed operator,
        string movementType
    );

    event ExternalDeposit(
        bytes32 indexed transactionId,
        TreasuryAccount targetAccount,
        uint256 amount,
        address indexed depositor
    );

    event ExternalWithdrawal(
        bytes32 indexed transactionId,
        TreasuryAccount sourceAccount,
        uint256 amount,
        address indexed recipient,
        address indexed operator
    );

    event AccountSnapshotCreated(
        uint256 indexed snapshotIndex,
        uint256 timestamp,
        uint256 totalAssets,
        address indexed snapshotter
    );

    event AllocationConfigUpdated(
        string configName,
        uint256 oldValue,
        uint256 newValue
    );

    event ContractRoleUpdated(
        bytes32 indexed role,
        address indexed account,
        bool granted
    );

    // ============ ERRORS ============

    error InsufficientAccountBalance(TreasuryAccount account, uint256 requested, uint256 available);
    error InvariantViolation(string reason, uint256 expected, uint256 actual);
    error InvalidAccountTransfer(TreasuryAccount from, TreasuryAccount to);
    error WithdrawalExceedsLimit(uint256 requested, uint256 maxAllowed);
    error InvalidAddress(address account);
    error SameBlockTransaction(TreasuryAccount account);
    error UnauthorizedAccountTransfer();

    /**
     * @dev Constructor initializes the treasury accounting engine
     * @param _protocolToken Address of the main ERC20 token
     * @param _governanceController Address of the governance controller
     * @param _initialAdmin Initial admin address
     */
    constructor(
        address _protocolToken,
        address _governanceController,
        address _initialAdmin
    ) {
        if (_protocolToken == address(0)) revert InvalidAddress(_protocolToken);
        if (_initialAdmin == address(0)) revert InvalidAddress(_initialAdmin);

        protocolToken = IERC20(_protocolToken);
        
        // Initialize roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(ADMIN_ROLE, _initialAdmin);
        _grantRole(TREASURY_MANAGER_ROLE, _initialAdmin);

        _setRoleAdmin(STAKING_CONTRACT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REWARD_ENGINE_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SLASHING_CONTRACT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_MANAGER_ROLE, ADMIN_ROLE);

        // Initialize governance
        _initializeGovernance(_governanceController, _initialAdmin, _initialAdmin);
    }

    // ============ EXTERNAL DEPOSITS (TOKENS ENTERING PROTOCOL) ============

    /**
     * @dev Deposit tokens from external sources into a specific treasury account
     * @param targetAccount The treasury account to credit
     * @param amount Amount of tokens to deposit
     */
    function depositToAccount(TreasuryAccount targetAccount, uint256 amount) external nonReentrant {
        if (amount == 0) revert InsufficientAccountBalance(targetAccount, 0, 0);
        
        // Transfer tokens from sender to this contract
        uint256 balanceBefore = protocolToken.balanceOf(address(this));
        protocolToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualReceived = protocolToken.balanceOf(address(this)) - balanceBefore;
        
        // Credit the target account
        _accountBalances[uint256(targetAccount)] += actualReceived;
        
        // Generate transaction record
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            msg.sender,
            address(this),
            actualReceived,
            TreasuryAccount.EXTERNAL, // External source marker
            targetAccount,
            "external_deposit"
        );

        emit ExternalDeposit(transactionId, targetAccount, actualReceived, msg.sender);
        
        // Verify invariants after operation
        _validateInvariants();
    }

    // ============ INTERNAL TRANSFERS (BETWEEN TREASURY ACCOUNTS) ============

    /**
     * @dev Transfer funds between internal treasury accounts (authorized contracts only)
     * @param fromAccount Source treasury account
     * @param toAccount Target treasury account
     * @param amount Amount to transfer
     * @param movementType Description of the transfer for auditing
     */
    function transferBetweenAccounts(
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        uint256 amount,
        string calldata movementType
    ) external nonReentrant onlyRoleAuthorizedForTransfer(fromAccount) {
        if (fromAccount == toAccount) revert InvalidAccountTransfer(fromAccount, toAccount);
        if (amount == 0) revert InsufficientAccountBalance(fromAccount, 0, _accountBalances[uint256(fromAccount)]);
        if (_accountBalances[uint256(fromAccount)] < amount) {
            revert InsufficientAccountBalance(fromAccount, amount, _accountBalances[uint256(fromAccount)]);
        }

        // Prevent multiple transactions in the same block for the same source account
        if (block.number <= lastTransactionBlock[fromAccount]) {
            revert SameBlockTransaction(fromAccount);
        }
        lastTransactionBlock[fromAccount] = block.number;

        // Execute the transfer in accounting ledgers
        _accountBalances[uint256(fromAccount)] -= amount;
        _accountBalances[uint256(toAccount)] += amount;

        // Record the transaction
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            address(this),
            amount,
            fromAccount,
            toAccount,
            movementType
        );

        emit FundsTransferred(transactionId, fromAccount, toAccount, amount, msg.sender, movementType);

        // Validate all invariants are maintained
        _validateInvariants();
    }

    // ============ EXTERNAL WITHDRAWALS (TOKENS LEAVING PROTOCOL) ============

    /**
     * @dev Withdraw funds from a treasury account to an external address (treasury managers only)
     * @param sourceAccount Source treasury account
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFromAccount(
        TreasuryAccount sourceAccount,
        address recipient,
        uint256 amount
    ) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        if (recipient == address(0)) revert InvalidAddress(recipient);
        if (amount == 0) revert InsufficientAccountBalance(sourceAccount, 0, _accountBalances[uint256(sourceAccount)]);
        if (_accountBalances[uint256(sourceAccount)] < amount) {
            revert InsufficientAccountBalance(sourceAccount, amount, _accountBalances[uint256(sourceAccount)]);
        }

        // Enforce withdrawal limits based on account type
        _enforceWithdrawalLimits(sourceAccount, amount);

        // Prevent same-block transactions
        if (block.number <= lastTransactionBlock[sourceAccount]) {
            revert SameBlockTransaction(sourceAccount);
        }
        lastTransactionBlock[sourceAccount] = block.number;

        // Execute the withdrawal in accounting
        _accountBalances[uint256(sourceAccount)] -= amount;

        // Transfer tokens to recipient
        protocolToken.safeTransfer(recipient, amount);

        // Record transaction
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            recipient,
            amount,
            sourceAccount,
            TreasuryAccount.EXTERNAL, // External destination
            "external_withdrawal"
        );

        emit ExternalWithdrawal(transactionId, sourceAccount, amount, recipient, msg.sender);

        // Validate invariants
        _validateInvariants();
    }

    // ============ STAKING CONTRACT SPECIFIC FUNCTIONS ============

    /**
     * @dev Record user stake into staking reserve (called by staking contract)
     * @param user User address that staked
     * @param amount Amount staked
     */
    function recordStake(address user, uint256 amount) external onlyRole(STAKING_CONTRACT_ROLE) {
        _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] += amount;
        
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            user,
            address(this),
            amount,
            TreasuryAccount.EXTERNAL,
            TreasuryAccount.STAKING_RESERVE,
            "user_stake"
        );

        emit ExternalDeposit(transactionId, TreasuryAccount.STAKING_RESERVE, amount, user);
        _validateInvariants();
    }

    /**
     * @dev Record user unstake from staking reserve (called by staking contract)
     * @param user User address that unstaked
     * @param amount Amount unstaked
     */
    function recordUnstake(address user, uint256 amount) external onlyRole(STAKING_CONTRACT_ROLE) {
        if (_accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] < amount) {
            revert InsufficientAccountBalance(TreasuryAccount.STAKING_RESERVE, amount, _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]);
        }
        
        _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] -= amount;
        
        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            user,
            amount,
            TreasuryAccount.STAKING_RESERVE,
            TreasuryAccount.EXTERNAL,
            "user_unstake"
        );

        emit ExternalWithdrawal(transactionId, TreasuryAccount.STAKING_RESERVE, amount, user, msg.sender);
        _validateInvariants();
    }

    // ============ SLASHING CONTRACT SPECIFIC FUNCTIONS ============

    /**
     * @dev Record slashing event - move funds from staking reserve to slashed treasury
     * @param verifier Verifier address that was slashed
     * @param amount Amount slashed
     */
    function recordSlash(address verifier, uint256 amount) external onlyRole(SLASHING_CONTRACT_ROLE) {
        if (_accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] < amount) {
            revert InsufficientAccountBalance(TreasuryAccount.STAKING_RESERVE, amount, _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)]);
        }

        _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)] -= amount;
        _accountBalances[uint256(TreasuryAccount.SLASHED_TREASURY)] += amount;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            address(this),
            amount,
            TreasuryAccount.STAKING_RESERVE,
            TreasuryAccount.SLASHED_TREASURY,
            "verifier_slash"
        );

        emit FundsTransferred(transactionId, TreasuryAccount.STAKING_RESERVE, TreasuryAccount.SLASHED_TREASURY, amount, msg.sender, "slashing");
        _validateInvariants();
    }

    // ============ REWARD ENGINE SPECIFIC FUNCTIONS ============

    /**
     * @dev Record reward distribution from rewards pool
     * @param recipient Reward recipient
     * @param amount Reward amount
     */
    function recordRewardDistribution(address recipient, uint256 amount) external onlyRole(REWARD_ENGINE_ROLE) {
        if (_accountBalances[uint256(TreasuryAccount.REWARDS_POOL)] < amount) {
            revert InsufficientAccountBalance(TreasuryAccount.REWARDS_POOL, amount, _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)]);
        }

        _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)] -= amount;

        bytes32 transactionId = _generateTransactionId();
        _recordTransaction(
            transactionId,
            address(this),
            recipient,
            amount,
            TreasuryAccount.REWARDS_POOL,
            TreasuryAccount.EXTERNAL,
            "reward_distribution"
        );

        emit ExternalWithdrawal(transactionId, TreasuryAccount.REWARDS_POOL, amount, recipient, msg.sender);
        _validateInvariants();
    }

    // ============ AUDIT & SNAPSHOT FUNCTIONS ============

    /**
     * @dev Create a snapshot of all account balances for auditing
     */
    function createSnapshot() external {
        uint256[6] memory currentBalances = getAccountBalances();
        uint256 total = calculateTotalAssets();

        AccountSnapshot storage newSnapshot = snapshots.push();
        newSnapshot.timestamp = block.timestamp;
        newSnapshot.blockNumber = block.number;
        newSnapshot.balances = currentBalances;
        newSnapshot.totalAssets = total;
        newSnapshot.snapshotSender = msg.sender;

        snapshotCount++;

        emit AccountSnapshotCreated(snapshotCount - 1, block.timestamp, total, msg.sender);
    }

    /**
     * @dev Get all current account balances
     */
    function getAccountBalances() public view returns (uint256[6] memory) {
        return _accountBalances;
    }

    /**
     * @dev Get balance of a specific account
     */
    function getAccountBalance(TreasuryAccount account) public view returns (uint256) {
        return _accountBalances[uint256(account)];
    }

    /**
     * @dev Calculate total assets across all accounts (must equal contract token balance)
     */
    function calculateTotalAssets() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < 6; i++) {
            total += _accountBalances[i];
        }
        return total;
    }

    /**
     * @dev Get full transaction history
     */
    function getTransactionHistory(uint256 offset, uint256 limit) external view returns (TokenMovement[] memory history) {
        uint256 end = offset + limit;
        if (end > transactionIds.length) {
            end = transactionIds.length;
        }
        history = new TokenMovement[](end - offset);
        
        for (uint256 i = offset; i < end; i++) {
            history[i - offset] = transactions[transactionIds[i]];
        }
        return history;
    }

    // ============ ADMIN CONFIGURATION FUNCTIONS ============

    /**
     * @dev Update maximum rewards withdrawal basis points
     */
    function setMaxRewardsWithdrawalBPS(uint256 newBPS) external onlyRole(ADMIN_ROLE) {
        if (newBPS > PERCENT_DENOMINATOR) revert InvalidAddress(address(0));
        uint256 old = maxRewardsWithdrawalBPS;
        maxRewardsWithdrawalBPS = newBPS;
        emit AllocationConfigUpdated("maxRewardsWithdrawalBPS", old, newBPS);
    }

    /**
     * @dev Update minimum staking reserve ratio
     */
    function setMinStakingReserveRatio(uint256 newBPS) external onlyRole(ADMIN_ROLE) {
        if (newBPS > PERCENT_DENOMINATOR) revert InvalidAddress(address(0));
        uint256 old = minStakingReserveRatio;
        minStakingReserveRatio = newBPS;
        emit AllocationConfigUpdated("minStakingReserveRatio", old, newBPS);
    }

    // ============ INTERNAL VALIDATION & HELPERS ============

    /**
     * @dev Validate all financial invariants are maintained
     */
    function _validateInvariants() internal view {
        uint256 accountedTotal = calculateTotalAssets();
        uint256 actualBalance = protocolToken.balanceOf(address(this));

        // Fundamental invariant: Sum of all accounting balances must equal actual token balance
        if (accountedTotal != actualBalance) {
            revert InvariantViolation(
                "Total accounting mismatch: accounted != actual balance",
                accountedTotal,
                actualBalance
            );
        }

        // Staking reserve invariant: minimum ratio maintained
        uint256 stakingBalance = _accountBalances[uint256(TreasuryAccount.STAKING_RESERVE)];
        uint256 minRequired = (accountedTotal * minStakingReserveRatio) / PERCENT_DENOMINATOR;
        if (stakingBalance < minRequired && accountedTotal > 0) {
            revert InvariantViolation(
                "Staking reserve below minimum required ratio",
                minRequired,
                stakingBalance
            );
        }

        // All account balances must be non-negative (guaranteed by Solidity, but explicit for clarity)
        for (uint256 i = 0; i < 6; i++) {
            if (_accountBalances[i] > type(uint256).max) {
                revert InvariantViolation("Account balance overflow", 0, _accountBalances[i]);
            }
        }
    }

    /**
     * @dev Enforce withdrawal limits per account type
     */
    function _enforceWithdrawalLimits(TreasuryAccount sourceAccount, uint256 amount) internal view {
        if (sourceAccount == TreasuryAccount.REWARDS_POOL) {
            uint256 poolBalance = _accountBalances[uint256(TreasuryAccount.REWARDS_POOL)];
            uint256 maxWithdrawal = (poolBalance * maxRewardsWithdrawalBPS) / PERCENT_DENOMINATOR;
            if (amount > maxWithdrawal) {
                revert WithdrawalExceedsLimit(amount, maxWithdrawal);
            }
        }

        // Cannot withdraw from staking reserve except by staking contract via recordUnstake
        if (sourceAccount == TreasuryAccount.STAKING_RESERVE) {
            revert UnauthorizedAccountTransfer();
        }
    }

    /**
     * @dev Record a transaction in the transaction history
     */
    function _recordTransaction(
        bytes32 transactionId,
        address from,
        address to,
        uint256 amount,
        TreasuryAccount fromAccount,
        TreasuryAccount toAccount,
        string memory movementType
    ) internal {
        TokenMovement storage txn = transactions[transactionId];
        txn.timestamp = block.timestamp;
        txn.from = from;
        txn.to = to;
        txn.amount = amount;
        txn.fromAccount = fromAccount;
        txn.toAccount = toAccount;
        txn.movementType = movementType;
        txn.transactionId = transactionId;

        transactionIds.push(transactionId);
        transactionCount++;
    }

    /**
     * @dev Generate a unique transaction ID
     */
    function _generateTransactionId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.timestamp,
            block.number,
            msg.sender,
            transactionCount
        ));
    }

    /**
     * @dev Modifier to check if caller is authorized to transfer from an account
     */
    modifier onlyRoleAuthorizedForTransfer(TreasuryAccount fromAccount) {
        if (fromAccount == TreasuryAccount.STAKING_RESERVE) {
            if (!hasRole(STAKING_CONTRACT_ROLE, msg.sender) && !hasRole(SLASHING_CONTRACT_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        } else if (fromAccount == TreasuryAccount.REWARDS_POOL) {
            if (!hasRole(REWARD_ENGINE_ROLE, msg.sender)) {
                revert UnauthorizedAccountTransfer();
            }
        } else if (!hasRole(TREASURY_MANAGER_ROLE, msg.sender)) {
            revert UnauthorizedAccountTransfer();
        }
        _;
    }
}