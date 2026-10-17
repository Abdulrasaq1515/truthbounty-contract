// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title ICriticalPathGasBudgets
 * @notice Critical-path operations benchmarked under V2-SC-038 and V2-SC-072.
 */
interface ICriticalPathGasBudgets {
    enum Operation {
        CLAIM_CREATION,
        EVIDENCE_ATTACHMENT,
        VERIFICATION_VOTE,
        AGGREGATION,
        PROVISIONAL_SETTLEMENT,
        CHALLENGE_OPEN,
        APPEAL_SETTLEMENT,
        FINALIZATION,
        WITHDRAWAL,
        REWARD_CLAIM,
        GOVERNANCE_CONFIGURATION,
        EMERGENCY_PAUSE
    }

    struct GasBudget {
        Operation operation;
        uint256 maxGasAtMaxConfig;
        string boundDescription;
    }

    function getBudget(Operation operation) external view returns (uint256 maxGasAtMaxConfig, string memory boundDescription);

    function budgetCount() external pure returns (uint256);
}
