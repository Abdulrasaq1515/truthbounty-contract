import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

export interface CanonicalV2Suite {
  deployer: SignerWithAddress;
  governanceController: any;
  token: any;
  oracle: any;
  claimRegistry: any;
  truthBountyWeighted: any;
  aggregator: any;
  provisionalSettlementEngine: any;
  appealVerificationRound: any;
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
  finalizeDeployerRoles?: boolean;
}

/**
 * @notice Deploys the complete canonical TruthBounty V2 suite in deterministic dependency order.
 * @param deployer The signer executing the deployment.
 * @param options Optional configuration parameters.
 */
export async function deployCanonicalV2(
  deployer: SignerWithAddress,
  options: DeploymentOptions = {}
): Promise<CanonicalV2Suite> {
  const initialSupply = options.initialSupply ?? ethers.parseEther("10000000");
  const minVerificationCount = options.minVerificationCount ?? 1n;
  const minTotalWeight = options.minTotalWeight ?? 0n;
  const minConfidenceBps = options.minConfidenceBps ?? 0n;
  const challengeWindowDuration = options.challengeWindowDuration ?? 3 * 24 * 3600;
  const appealDuration = options.appealDuration ?? 3 * 24 * 3600;
  const minAppealStake = options.minAppealStake ?? ethers.parseEther("200");
  const appealMultiplierBps = options.appealMultiplierBps ?? 15000;
  const maxWeightCap = options.maxWeightCap ?? ethers.parseEther("100000");
  const finalizeDeployerRoles = options.finalizeDeployerRoles ?? false;

  // 1. Governance Controller
  const GovFactory = await ethers.getContractFactory("GovernanceController", deployer);
  const governanceController = await GovFactory.deploy(deployer.address);
  await governanceController.waitForDeployment();

  // 2. Token
  const TokenFactory = await ethers.getContractFactory("RewardToken", deployer);
  const token = await TokenFactory.deploy(deployer.address, initialSupply);
  await token.waitForDeployment();

  // 3. Reputation Oracle
  const OracleFactory = await ethers.getContractFactory("MockReputationOracle", deployer);
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
  };
  const appealVerificationRound = await AppealFactory.deploy(
    await token.getAddress(),
    await claimRegistry.getAddress(),
    await oracle.getAddress(),
    initialAppealConfig,
    await governanceController.getAddress(),
    deployer.address
  );
  await appealVerificationRound.waitForDeployment();

  // 9. Wire Roles & Permissions
  const REGISTRY_UPDATER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_UPDATER_ROLE"));
  await claimRegistry.grantRole(REGISTRY_UPDATER_ROLE, await provisionalSettlementEngine.getAddress());

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
  };
}

async function main() {
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
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
