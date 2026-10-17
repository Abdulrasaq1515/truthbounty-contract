// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoundedSafeERC20 as SafeERC20} from "../libraries/BoundedSafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IFinalRewardAllocator} from "./interfaces/IFinalRewardAllocator.sol";
import {IModuleRegistry} from "./interfaces/IModuleRegistry.sol";
import {V2Precision} from "./libraries/V2Precision.sol";
import {PauseMatrix} from "./libraries/PauseMatrix.sol";
import {V2PauseGuard} from "./libraries/V2PauseGuard.sol";

/// @title FinalRewardAllocator
/// @notice Records pull-based reward entitlements from one immutable final outcome.
/// @dev The settlement module is the sole writer. It must pass frozen effective weights
///      and an explicit recipient for integer-division remainders.
///
///      Pause matrix (V2-SC-162, `PauseMatrix` v1): the pause authority is resolved from
///      `moduleRegistry` under `EMERGENCY_CONTROLS`. `fund` and `finalizeRewards` fail closed under
///      `SCOPE_SETTLEMENT`; `claim` of an already-final entitlement is a RISK_REDUCING exit that is
///      never scope-gated and freezes only at protocol SHUTDOWN.
contract FinalRewardAllocator is IFinalRewardAllocator, V2PauseGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_SETTLEMENT = keccak256("SETTLEMENT");
    uint256 public immutable maxRecipients;
    IModuleRegistry public immutable moduleRegistry;

    mapping(address => uint256) private _funded;
    mapping(address => uint256) private _allocated;
    mapping(address => mapping(address => uint256)) private _claimable;
    mapping(bytes32 => mapping(address => uint256)) private _settlementFunded;
    mapping(bytes32 => mapping(address => uint256)) private _settlementAllocated;
    mapping(bytes32 => bool) private _finalized;
    mapping(bytes32 => FinalOutcome) private _finalOutcome;

    error UnauthorizedSettlementModule(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipientCount();
    error InvalidRemainderRecipient();
    error ZeroEffectiveWeight();
    error InconsistentWeights();
    error PoolExceeded(uint256 requested, uint256 available);
    error SettlementAlreadyFinalized(bytes32 settlementId);
    error InsufficientClaimable(uint256 requested, uint256 available);
    error DuplicateCategory();

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IFinalRewardAllocator).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    constructor(address registry, uint256 recipientLimit) {
        if (registry == address(0) || recipientLimit == 0) revert ZeroAddress();
        moduleRegistry = IModuleRegistry(registry);
        maxRecipients = recipientLimit;
    }

    function protocolVersion() external pure override returns (uint16 major, uint16 minor) {
        return (2, 0);
    }

    function fund(address asset, uint256 amount, bytes32 settlementId) external override {
        _onlySettlementModule();
        _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _funded[asset] += amount;
        _settlementFunded[settlementId][asset] += amount;
        emit RewardPoolFunded(asset, amount, settlementId);
    }

    function finalizeRewards(
        bytes32 settlementId,
        address asset,
        FinalOutcome outcome,
        Allocation[] calldata allocations
    ) external override {
        _onlySettlementModule();
        _requireScopeNotPaused(PauseMatrix.SCOPE_SETTLEMENT);
        if (_finalized[settlementId]) revert SettlementAlreadyFinalized(settlementId);
        if (asset == address(0)) revert ZeroAddress();
        if (allocations.length > 5) revert InvalidRecipientCount();

        uint256 totalAmount;
        uint256 categoryMask;
        for (uint256 i; i < allocations.length; ++i) {
            Allocation calldata allocation = allocations[i];
            uint256 categoryBit = 1 << uint8(allocation.category);
            if (categoryMask & categoryBit != 0) revert DuplicateCategory();
            categoryMask |= categoryBit;
            uint256 count = allocation.accounts.length;
            if (count == 0 || count > maxRecipients || count != allocation.effectiveWeights.length) {
                revert InvalidRecipientCount();
            }
            if (allocation.remainderRecipient == address(0)) revert InvalidRemainderRecipient();
            if (allocation.amount == 0) revert ZeroAmount();
            _allocateCategory(settlementId, asset, allocation);
            totalAmount += allocation.amount;
        }

        uint256 available = _settlementFunded[settlementId][asset] - _settlementAllocated[settlementId][asset];
        if (totalAmount > available) revert PoolExceeded(totalAmount, available);
        _allocated[asset] += totalAmount;
        _settlementAllocated[settlementId][asset] += totalAmount;
        _finalized[settlementId] = true;
        _finalOutcome[settlementId] = outcome;
        emit RewardsFinalized(settlementId, asset, outcome, totalAmount);
    }

    /// @notice Pulls the caller's already-final reward entitlement.
    /// @dev V2-SC-162: RISK_REDUCING exit. Never scope-gated; frozen only at protocol SHUTDOWN.
    ///      Idempotent: claiming more than the remaining entitlement reverts with `InsufficientClaimable`.
    function claim(address asset, uint256 amount) external override {
        _requireExitsNotShutdown();
        uint256 available = _claimable[asset][msg.sender];
        if (amount == 0 || amount > available) revert InsufficientClaimable(amount, available);
        _claimable[asset][msg.sender] = available - amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit RewardClaimed(asset, msg.sender, amount);
    }

    function claimable(address asset, address account) external view override returns (uint256) {
        return _claimable[asset][account];
    }

    function funded(address asset) external view override returns (uint256) {
        return _funded[asset];
    }

    function allocated(address asset) external view override returns (uint256) {
        return _allocated[asset];
    }

    function finalized(bytes32 settlementId) external view override returns (bool) {
        return _finalized[settlementId];
    }

    function finalOutcome(bytes32 settlementId) external view override returns (FinalOutcome) {
        return _finalOutcome[settlementId];
    }

    /// @dev Pause authority resolved from the module registry (timelocked replacement path).
    function _pauseAuthority() internal view override returns (bool resolved, address authority) {
        return _registryPauseAuthority(address(moduleRegistry));
    }

    function _onlySettlementModule() internal view {
        (address implementation,,) = moduleRegistry.module(MODULE_SETTLEMENT);
        if (implementation != msg.sender) revert UnauthorizedSettlementModule(msg.sender);
    }

    function _allocateCategory(bytes32 settlementId, address asset, Allocation calldata allocation) internal {
        uint256 totalWeight;
        uint256 count = allocation.accounts.length;
        for (uint256 i; i < count; ++i) {
            if (allocation.accounts[i] == address(0)) revert ZeroAddress();
            if (allocation.effectiveWeights[i] == 0) revert ZeroEffectiveWeight();
            totalWeight += allocation.effectiveWeights[i];
        }

        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            // Rounding is pro-rata and truncating, via V2Precision (V2-SC-100).
            //
            // Down is the correct direction for a payout: every recipient is
            // paid no more than their exact entitlement, so the parts can only
            // sum to at most `allocation.amount` and the shortfall is dust that
            // `remainderRecipient` receives below. Rounding up here would let
            // the sum of shares exceed the funded amount.
            //
            // mulDivDown also computes the product over 512 bits. The previous
            // inline form multiplied before dividing, so a large amount times a
            // large effective weight could overflow and revert a settlement that
            // is arithmetically valid.
            uint256 share = V2Precision.mulDivDown(allocation.amount, allocation.effectiveWeights[i], totalWeight);
            distributed += share;
            if (share != 0) {
                _claimable[asset][allocation.accounts[i]] += share;
                emit RewardAllocated(settlementId, allocation.category, asset, allocation.accounts[i], share);
            }
        }

        uint256 remainder = allocation.amount - distributed;
        if (remainder != 0) {
            _claimable[asset][allocation.remainderRecipient] += remainder;
            emit RewardAllocated(settlementId, allocation.category, asset, allocation.remainderRecipient, remainder);
        }
    }
}