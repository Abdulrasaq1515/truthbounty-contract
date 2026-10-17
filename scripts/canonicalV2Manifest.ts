import { getAddress, getCreateAddress, keccak256, toUtf8Bytes, ZeroAddress } from "ethers";
import {
  DeploymentManifest,
  ManifestValue,
  canonicalManifestValue,
  validateManifest,
} from "./deploymentManifest.js";

export interface CanonicalV2ManifestInputs {
  chainId: bigint | number | string;
  protocolVersion: string;
  deployer: string;
  startingNonce: number;
  libraries: Record<string, string>;
  initialSupply: string;
  minVerificationCount: string;
  minTotalWeight: string;
  minConfidenceBps: string;
  challengeWindowDuration: number;
  appealDuration: number;
  minAppealStake: string;
  appealMultiplierBps: number;
  maxWeightCap: string;
}

export interface ArtifactReader {
  readArtifact(name: string): Promise<{
    bytecode: string;
    deployedBytecode: string;
    linkReferences: Record<string, Record<string, Array<{ length: number; start: number }>>>;
  }>;
}

const compiler = {
  version: "0.8.28",
  evmVersion: "cancun",
  viaIR: true,
  optimizer: { enabled: true, runs: 200 },
};

const contracts = [
  "GovernanceController",
  "RewardToken",
  "MockReputationOracle",
  "ClaimRegistry",
  "TruthBountyWeighted",
  "VerificationAggregator",
  "ProvisionalSettlementEngine",
  "AppealVerificationRound",
] as const;

const artifactNames: Record<string, string> = {
  MockReputationOracle: "contracts/MockReputationOracle.sol:MockReputationOracle",
};

const referenceToContract: Record<string, string> = {
  governanceController: "GovernanceController",
  token: "RewardToken",
  reputationOracle: "MockReputationOracle",
  claimRegistry: "ClaimRegistry",
  truthBountyWeighted: "TruthBountyWeighted",
  verificationAggregator: "VerificationAggregator",
  provisionalSettlementEngine: "ProvisionalSettlementEngine",
  appealVerificationRound: "AppealVerificationRound",
};

function ref(name: string): ManifestValue {
  return { "$ref": name };
}

function inputHash(value: ManifestValue): string {
  return keccak256(toUtf8Bytes(canonicalManifestValue(value)));
}

export async function buildCanonicalV2Manifest(
  artifacts: ArtifactReader,
  inputs: CanonicalV2ManifestInputs,
): Promise<DeploymentManifest> {
  const deployer = getAddress(inputs.deployer);
  if (deployer === ZeroAddress) {
    throw new Error("Manifest deployer cannot be the zero address");
  }
  if (!Number.isSafeInteger(inputs.startingNonce) || inputs.startingNonce < 0) {
    throw new Error("Manifest starting nonce must be a non-negative safe integer");
  }

  const constructorArgs: ManifestValue[][] = [
    [ref("deployer")],
    [ref("deployer"), inputs.initialSupply],
    [],
    [ref("deployer")],
    [ref("token"), ref("reputationOracle"), ref("deployer"), ref("governanceController")],
    [ref("truthBountyWeighted"), ref("deployer"), inputs.minVerificationCount, inputs.minTotalWeight, inputs.minConfidenceBps],
    [ref("claimRegistry"), ref("verificationAggregator"), inputs.challengeWindowDuration, ref("governanceController"), ref("deployer")],
    [
      ref("token"),
      ref("claimRegistry"),
      ref("reputationOracle"),
      {
        roundDuration: inputs.appealDuration,
        minStakeAmount: inputs.minAppealStake,
        stakeMultiplierBps: inputs.appealMultiplierBps,
        maxWeightCap: inputs.maxWeightCap,
        parameterVersion: "1",
      },
      ref("governanceController"),
      ref("deployer"),
    ],
  ];

  const artifactEntries = await Promise.all(
    contracts.map(async (name, index) => {
      const artifactName = artifactNames[name] ?? name;
      const artifact = await artifacts.readArtifact(artifactName);
      return {
        name,
        artifact: artifactName,
        salt: keccak256(toUtf8Bytes(`CanonicalV2Module:${inputs.protocolVersion}:${name}`)),
        nonce: inputs.startingNonce + index,
        address: getCreateAddress({ from: deployer, nonce: inputs.startingNonce + index }),
        constructorArgs: constructorArgs[index],
        libraries: Object.keys(artifact.linkReferences).sort().reduce<Record<string, string>>((result, library) => {
          const address = inputs.libraries[library];
          if (!address || getAddress(address) === ZeroAddress) {
            throw new Error(`Missing non-zero library address for ${library}`);
          }
          result[library] = getAddress(address);
          return result;
        }, {}),
        bytecodeHash: keccak256(artifact.bytecode),
        deployedBytecodeHash: keccak256(artifact.deployedBytecode),
      };
    }),
  );

  const transactions = contracts.map((contract, index) => ({
    index,
    nonce: inputs.startingNonce + index,
    action: "deploy",
    contract,
    dependsOn: constructorArgs[index]
      .filter((argument): argument is { "$ref": string } => typeof argument === "object" && argument !== null && "$ref" in argument)
      .filter((argument) => argument["$ref"] !== "deployer")
      .map((argument) => referenceToContract[argument["$ref"]]),
    inputHash: inputHash({
      args: constructorArgs[index],
      salt: keccak256(toUtf8Bytes(`CanonicalV2Module:${inputs.protocolVersion}:${contract}`)),
      nonce: inputs.startingNonce + index,
    }),
  }));

  transactions.push({
    index: transactions.length,
    nonce: inputs.startingNonce + transactions.length,
    action: "call:grantRole",
    contract: "ClaimRegistry",
    dependsOn: ["ProvisionalSettlementEngine"],
    inputHash: inputHash({ role: "REGISTRY_UPDATER_ROLE", account: ref("provisionalSettlementEngine") }),
  });

  const manifest: DeploymentManifest = {
    schemaVersion: "1",
    protocolVersion: inputs.protocolVersion,
    chainId: String(inputs.chainId),
    module: "CanonicalV2Module",
    deployer,
    startingNonce: inputs.startingNonce,
    compiler,
    contracts: artifactEntries,
    transactions,
  };

  validateManifest(manifest);
  return manifest;
}