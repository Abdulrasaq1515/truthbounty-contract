import { network } from "hardhat";
import type { Signer } from "ethers";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { validateCanonicalV2Parameters } from "./validateDeploymentConfig";

export type DeploymentSigner = Signer & {
  address: string;
};
export interface CanonicalV2Suite {
  deployer: DeploymentSigner;
  governanceController: any;
  token: any;
  oracle: any;
  claimRegistry: any;
  truthBountyWeighted: any;
  aggregator: any;
  provisionalSettlementEngine: any;
  appealVerificationRound: any;
  bondVault: any;
}

export interface DeploymentOptions {
  initialSupply?: bigint;
  minVerificationCount?: bigint;
  minTotalWeight?: bigint;
  minConfidenceBps?: bigint;
  challengeWindowDuration?: number;
  appealDuration?: number;
  minAppealStake?: bigint;
  appealMultiplierBps?: number;
  maxWeightCap?: bigint;
  maxAppealRounds?: bigint;
  appealBond?: bigint;
  appealBondEscalationBps?: bigint;
  maxAppealBond?: bigint;
  maxVotersPerRound?: bigint;
  finalizeDeployerRoles?: boolean;
}

/**
 * @notice Deploys the complete canonical TruthBounty V2 suite in deterministic dependency order.
 * @param deployer The signer executing the deployment.
 * @param options Optional configuration parameters.
 */
export async function deployCanonicalV2(
  deployer: DeploymentSigner,
  options: DeploymentOptions = {}
): Promise<CanonicalV2Suite> {
  const { ethers } = await network.connect();
  const initialSupply = options.initialSupply ?? ethers.parseEther("10000000");
  const minVerificationCount = options.minVerificationCount ?? 1n;
  const minTotalWeight = options.minTotalWeight ?? 0n;
  const minConfidenceBps = options.minConfidenceBps ?? 0n;
  const challengeWindowDuration = options.challengeWindowDuration ?? 3 * 24 * 3600;
  const appealDuration = options.appealDuration ?? 3 * 24 * 3600;
  const minAppealStake = options.minAppealStake ?? ethers.parseEther("200");
  const appealMultiplierBps = options.appealMultiplierBps ?? 15000;
  const maxWeightCap = options.maxWeightCap ?? ethers.parseEther("100000");
  const maxAppealRounds = options.maxAppealRounds ?? 1n;
  const appealBond = options.appealBond ?? ethers.parseEther("1000");
  const appealBondEscalationBps = options.appealBondEscalationBps ?? 15000;
  const maxAppealBond = options.maxAppealBond ?? ethers.parseEther("5000");
  const maxVotersPerRound = options.maxVotersPerRound ?? 200n;
  const finalizeDeployerRoles = options.finalizeDeployerRoles ?? false;

  validateCanonicalV2Parameters({
    initialSupply,
    minVerificationCount,
    minTotalWeight,
    minConfidenceBps,
    challengeWindowDuration,
    appealDuration,
    minAppealStake,
    appealMultiplierBps,
    maxWeightCap,
  });
  console.log("Deployment config validated:", deployer.address);

  // 1. Governance Controller
  const GovFactory = await ethers.getContractFactory("GovernanceController", deployer);
  const governanceController = await GovFactory.deploy(deployer.address);
  await governanceController.waitForDeployment();

  // 2. Token
  const TokenFactory = await ethers.getContractFactory("RewardToken", deployer);
  const token = await TokenFactory.deploy(deployer.address, initialSupply);
  await token.waitForDeployment();

  // 2b. Bond-Custody StakeVault (V2-SC-016/059 appeal bonds live here, never in the module)
  const StakeVaultFactory = await ethers.getContractFactory(
    "contracts/StakeVault.sol:StakeVault",
    deployer,
  );
  const bondVault = await StakeVaultFactory.deploy(deployer.address, await token.getAddress());
  await bondVault.waitForDeployment();

  // 3. Reputation Oracle
  const OracleFactory = await ethers.getContractFactory(
    "contracts/MockReputationOracle.sol:MockReputationOracle",
    deployer,
  );
  const oracle = await OracleFactory.deploy();
  await oracle.waitForDeployment();

  // 4. ClaimRegistry
  const ParamFactory = await ethers.getContractFactory("ParameterVersionRegistry", deployer);
  const parameterVersionRegistry = await ParamFactory.deploy(deployer.address, deployer.address);
  await parameterVersionRegistry.waitForDeployment();

  const RegistryFactory = await ethers.getContractFactory("ClaimRegistry", deployer);
  const claimRegistry = await RegistryFactory.deploy(
    deployer.address,
    await parameterVersionRegistry.getAddress()
  );
  await claimRegistry.waitForDeployment();

  // 5. Verification Source (TruthBountyWeighted)
  const TBFactory = await ethers.getContractFactory("TruthBountyWeighted", deployer);
  const truthBountyWeighted = await TBFactory.deploy(
    await token.getAddress(),
    await oracle.getAddress(),
    deployer.address,
    await governanceController.getAddress()
  );
  await truthBountyWeighted.waitForDeployment();

  // 6. Deterministic Verification Aggregator
  const AggFactory = await ethers.getContractFactory("VerificationAggregator", deployer);
  const aggregator = await AggFactory.deploy(
    await truthBountyWeighted.getAddress(),
    deployer.address,
    minVerificationCount,
    minTotalWeight,
    minConfidenceBps
  );
  await aggregator.waitForDeployment();

  // 7. Provisional Settlement Engine
  const SettlementFactory = await ethers.getContractFactory("ProvisionalSettlementEngine", deployer);
  const provisionalSettlementEngine = await SettlementFactory.deploy(
    await claimRegistry.getAddress(),
    await aggregator.getAddress(),
    challengeWindowDuration,
    await governanceController.getAddress(),
    deployer.address
  );
  await provisionalSettlementEngine.waitForDeployment();

  // 8. Appeal Verification Round
  const AppealFactory = await ethers.getContractFactory("AppealVerificationRound", deployer);
  const initialAppealConfig = {
    roundDuration: appealDuration,
    minStakeAmount: minAppealStake,
    stakeMultiplierBps: appealMultiplierBps,
    maxWeightCap: maxWeightCap,
    parameterVersion: 1n,
    maxAppealRounds: maxAppealRounds,
    appealBond: appealBond,
    appealBondEscalationBps: appealBondEscalationBps,
    maxAppealBond: maxAppealBond,
    maxVotersPerRound: maxVotersPerRound,
  };
  const appealVerificationRound = await AppealFactory.deploy(
    await token.getAddress(),
    await claimRegistry.getAddress(),
    await oracle.getAddress(),
    await bondVault.getAddress(),
    initialAppealConfig,
    await governanceController.getAddress(),
    deployer.address
  );
  await appealVerificationRound.waitForDeployment();

  // 9. Wire Roles & Permissions
  const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
  await claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, await provisionalSettlementEngine.getAddress());

  // Authorise the appeal module to lock appeal bonds in the vault
  const OPERATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE"));
  await bondVault.grantRole(OPERATOR_ROLE, await appealVerificationRound.getAddress());

  // 10. Role finalization if requested
  if (finalizeDeployerRoles) {
    // Renounce deployer's REGISTRY_UPDATER_ROLE if held
    if (await claimRegistry.hasRole(REGISTRY_UPDATER_ROLE, deployer.address)) {
      await claimRegistry.renounceRole(REGISTRY_UPDATER_ROLE, deployer.address);
    }
  }

  return {
    deployer,
    governanceController,
    token,
    oracle,
    claimRegistry,
    truthBountyWeighted,
    aggregator,
    provisionalSettlementEngine,
    appealVerificationRound,
    bondVault,
  };
}

async function main() {
  const { ethers } = await network.connect();
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Canonical V2 Suite with deployer:", deployer.address);
  const suite = await deployCanonicalV2(deployer);
  console.log("Canonical V2 Suite deployed successfully:");
  console.log("- GovernanceController:", await suite.governanceController.getAddress());
  console.log("- Token:", await suite.token.getAddress());
  console.log("- ReputationOracle:", await suite.oracle.getAddress());
  console.log("- ClaimRegistry:", await suite.claimRegistry.getAddress());
  console.log("- TruthBountyWeighted:", await suite.truthBountyWeighted.getAddress());
  console.log("- VerificationAggregator:", await suite.aggregator.getAddress());
  console.log("- ProvisionalSettlementEngine:", await suite.provisionalSettlementEngine.getAddress());
  console.log("- AppealVerificationRound:", await suite.appealVerificationRound.getAddress());
  console.log("- BondVault:", await suite.bondVault.getAddress());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
