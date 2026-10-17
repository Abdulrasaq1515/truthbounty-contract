// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IV2Module} from "./IV2Module.sol";

/// @notice Protocol treasury bucket accounting interface.
/// @dev The configured implementation owns the asset adapter and withdrawal authority; bucket accounting must be conserved and withdrawals fail closed when underfunded.
interface ITreasury is IV2Module {
    /// @notice Emitted when funds enter a named bucket.
    /// @param from Account supplying funds.
    /// @param amount Amount deposited in asset base units.
    /// @param bucket Stable bucket identifier.
    event FundsDeposited(address indexed from, uint256 amount, bytes32 indexed bucket);

    /// @notice Emitted when funds leave a named bucket.
    /// @param to Account receiving funds.
    /// @param amount Amount withdrawn in asset base units.
    /// @param bucket Stable bucket identifier.
    event FundsWithdrawn(address indexed to, uint256 amount, bytes32 indexed bucket);

    /// @notice Deposits caller funds into a configured bucket.
    /// @dev Must validate bucket existence, adapter, positive amount, and exact received balance before crediting accounting.
    /// @param bucket Stable bucket identifier.
    /// @param amount Amount to deposit in asset base units.
    function deposit(bytes32 bucket, uint256 amount) external;

    /// @notice Withdraws funds from a bucket under the treasury authority.
    /// @dev Must prevent withdrawal of reserved obligations and revert atomically if the configured external token call fails.
    /// @param bucket Stable bucket identifier.
    /// @param to Authorized destination.
    /// @param amount Amount to withdraw in asset base units.
    function withdraw(bytes32 bucket, address to, uint256 amount) external;

    /// @notice Reads the accounted balance of one bucket in the configured treasury asset.
    /// @param bucket Stable bucket identifier.
    /// @return amount Accounted amount in asset base units.
    function balanceOf(bytes32 bucket) external view returns (uint256 amount);
}
