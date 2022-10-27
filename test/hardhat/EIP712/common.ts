import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  BullaClaim,
  PenalizedClaim,
  BullaExtensionRegistry,
  BullaClaimEIP712,
} from "../../../typechain-types";
import { ethers } from "hardhat";
import { BigNumber, BigNumberish, Signature } from "ethers";

export enum CreateClaimApprovalType {
  Approved,
  CreditorOnly,
  DebtorOnly,
}

export enum FeePayer {
  Creditor,
  Debtor,
}

export enum ClaimBinding {
  Unbound,
  BindingPending,
  Bound,
}

export enum LockState {
  Unlocked,
  NoNewClaims,
  Locked,
}

export const declareSignerWithAddress = (): SignerWithAddress[] => [];

export const UNLIMITED_APPROVAL_COUNT = 2n ** 64n - 1n;

export const approveCreateClaimTypes = {
  ApproveCreateClaimExtension: [
    { name: "owner", type: "address" },
    { name: "operator", type: "address" },
    { name: "message", type: "string" },
    { name: "approvalType", type: "uint8" },
    { name: "approvalCount", type: "uint256" },
    { name: "isBindingAllowed", type: "bool" },
    { name: "nonce", type: "uint256" },
  ],
};

export const getPermitCreateClaimMessage = (
  operatorAddress: string,
  operatorName: string,
  approvalType: CreateClaimApprovalType,
  approvalCount: bigint,
  isBindingAllowed: boolean
): string =>
  approvalCount > 0n // approve case:
    ? "I approve the following contract: " +
      operatorName +
      " (" +
      operatorAddress.toLowerCase() +
      ") " +
      "to create " +
      (approvalCount != UNLIMITED_APPROVAL_COUNT
        ? approvalCount.toString() + " "
        : "") +
      "claims on my behalf." +
      (approvalType != CreateClaimApprovalType.CreditorOnly
        ? " I acknowledge that this contract may indebt me on claims" +
          (isBindingAllowed ? " that I cannot reject." : ".")
        : "")
    : // revoke case:
      "I revoke approval for the following contract: " +
      operatorName +
      " (" +
      operatorAddress.toLowerCase() +
      ") " +
      "to create claims on my behalf.";

export function deployContractsFixture(deployer: SignerWithAddress) {
  return async function fixture(): Promise<
    [BullaClaim, BullaClaimEIP712, PenalizedClaim, BullaExtensionRegistry]
  > {
    // deploy metadata library
    const claimMetadataGeneratorFactory = await ethers.getContractFactory(
      "ClaimMetadataGenerator"
    );
    const ClaimMetadataGenerator = await (
      await claimMetadataGeneratorFactory.connect(deployer).deploy()
    ).deployed();

    const BullaClaimEIP712Factory = await ethers.getContractFactory(
      "BullaClaimEIP712"
    );
    const BullaClaimEIP712 = await (
      await BullaClaimEIP712Factory.connect(deployer).deploy()
    ).deployed();

    // deploy the registry
    const extensionRegistryFactory = await ethers.getContractFactory(
      "BullaExtensionRegistry"
    );
    const BullaExtensionRegistry = await (
      await extensionRegistryFactory.connect(deployer).deploy()
    ).deployed();

    // deploy Bulla Claim
    const bullaClaimFactory = await ethers.getContractFactory("BullaClaim", {
      libraries: {
        ClaimMetadataGenerator: ClaimMetadataGenerator.address,
        BullaClaimEIP712: BullaClaimEIP712.address,
      },
    });
    const BullaClaim = await (
      await bullaClaimFactory
        .connect(deployer)
        .deploy(
          deployer.address,
          BullaExtensionRegistry.address,
          LockState.Unlocked
        )
    ).deployed();

    // deploy penalized claim mock
    const penalizedClaimFactory = await ethers.getContractFactory(
      "PenalizedClaim"
    );
    const PenalizedClaim = await (
      await penalizedClaimFactory.connect(deployer).deploy(BullaClaim.address)
    ).deployed();

    // enable the registry
    await BullaExtensionRegistry.connect(deployer).setExtensionName(
      PenalizedClaim.address,
      "PenalizedClaim"
    );

    return [
      BullaClaim,
      BullaClaimEIP712,
      PenalizedClaim,
      BullaExtensionRegistry,
    ];
  };
}

export const generateSignature = async ({
  bullaClaimAddress,
  signer,
  operatorName,
  operator,
  approvalType = CreateClaimApprovalType.Approved,
  approvalCount = UNLIMITED_APPROVAL_COUNT,
  isBindingAllowed = true,
  nonce = 0,
}: {
  bullaClaimAddress: string;
  signer: SignerWithAddress;
  operatorName: string;
  operator: string; // address
  approvalType?: CreateClaimApprovalType;
  approvalCount?: BigNumberish;
  isBindingAllowed?: boolean;
  nonce?: number;
}): Promise<Signature> => {
  const domain = {
    name: "BullaClaim",
    version: "1",
    verifyingContract: bullaClaimAddress,
    chainId: 31337,
  };

  const message = getPermitCreateClaimMessage(
    operator,
    operatorName,
    approvalType,
    BigNumber.from(approvalCount).toBigInt(),
    isBindingAllowed
  );

  const payClaimPermission = {
    owner: signer.address,
    operator: operator,
    message: message,
    approvalType: approvalType,
    approvalCount: approvalCount,
    isBindingAllowed: isBindingAllowed,
    nonce,
  };

  return ethers.utils.splitSignature(
    await signer._signTypedData(
      domain,
      approveCreateClaimTypes,
      payClaimPermission
    )
  );
};
