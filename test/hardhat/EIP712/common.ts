import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  BullaClaim,
  PenalizedClaim,
  BullaExtensionRegistry,
  BullaClaimEIP712,
  WETH,
} from "../../../typechain-types";
import { ethers } from "hardhat";
import { BigNumber, BigNumberish, Signature } from "ethers";
import { ClaimPaymentApprovalStruct } from "../../../typechain-types/src/BullaClaim";

export enum CreateClaimApprovalType {
  Approved,
  CreditorOnly,
  DebtorOnly,
}

export enum PayClaimApprovalType {
  Unapproved,
  IsApprovedForSpecific,
  IsApprovedForAll,
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

const getDomain = (bullaClaimAddress: string) => ({
  name: "BullaClaim",
  version: "1",
  verifyingContract: bullaClaimAddress,
  chainId: 31337,
});

export const permitCreateClaimTypes = {
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

export const permitPayClaimTypes = {
  ApprovePayClaimExtension: [
    { name: "owner", type: "address" },
    { name: "operator", type: "address" },
    { name: "message", type: "string" },
    { name: "approvalType", type: "uint8" },
    { name: "approvalDeadline", type: "uint256" },
    { name: "paymentApprovals", type: "ClaimPaymentApproval[]" },
    { name: "nonce", type: "uint256" },
  ],
  ClaimPaymentApproval: [
    { name: "claimId", type: "uint256" },
    { name: "approvalDeadline", type: "uint256" },
    { name: "approvedAmount", type: "uint256" },
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

export const getPermitPayClaimMessage = (
  operatorAddress: string,
  operatorName: string,
  approvalType: PayClaimApprovalType,
  approvalDeadline: number
): string =>
  approvalType != PayClaimApprovalType.Unapproved // approve case:
    ? (approvalType == PayClaimApprovalType.IsApprovedForAll
        ? "ATTENTION!: "
        : "") +
      "I approve the following contract: " +
      operatorName +
      " (" +
      operatorAddress.toLowerCase() + // note: will _not_ be checksummed
      ") " +
      "to pay " +
      (approvalType == PayClaimApprovalType.IsApprovedForAll
        ? "any claim"
        : "the below claims") +
      " on my behalf. I understand that once I sign this message this contract can spend tokens I've approved" +
      (approvalDeadline != 0
        ? " until the timestamp: " + approvalDeadline.toString()
        : ".")
    : // revoke case
      "I revoke approval for the following contract: " +
      operatorName +
      " (" +
      operatorAddress.toLowerCase() +
      ") " +
      "pay claims on my behalf.";

export function deployContractsFixture(deployer: SignerWithAddress) {
  return async function fixture(): Promise<
    [BullaClaim, BullaClaimEIP712, PenalizedClaim, BullaExtensionRegistry, WETH]
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

    const WETHFactory = await ethers.getContractFactory("WETH");
    const Weth = await (
      await WETHFactory.connect(deployer).deploy()
    ).deployed();

    return [
      BullaClaim,
      BullaClaimEIP712,
      PenalizedClaim,
      BullaExtensionRegistry,
      Weth,
    ];
  };
}

export const generateCreateClaimSignature = async ({
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
  const domain = getDomain(bullaClaimAddress);

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
      permitCreateClaimTypes,
      payClaimPermission
    )
  );
};

export const generatePayClaimSignature = async ({
  bullaClaimAddress,
  signer,
  operatorName,
  operator,
  approvalType = PayClaimApprovalType.IsApprovedForAll,
  approvalDeadline = 0,
  paymentApprovals = [],
  nonce = 0,
}: {
  bullaClaimAddress: string;
  signer: SignerWithAddress;
  operatorName: string;
  operator: string; // address
  approvalType?: PayClaimApprovalType;
  approvalDeadline?: number;
  paymentApprovals?: ClaimPaymentApprovalStruct[];
  nonce?: number;
}): Promise<Signature> => {
  const domain = getDomain(bullaClaimAddress);

  const message = getPermitPayClaimMessage(
    operator,
    operatorName,
    approvalType,
    approvalDeadline
  );

  const payClaimPermission = {
    owner: signer.address,
    operator: operator,
    message: message,
    approvalType: approvalType,
    approvalDeadline: approvalDeadline,
    paymentApprovals: paymentApprovals,
    nonce,
  };

  return ethers.utils.splitSignature(
    await signer._signTypedData(domain, permitPayClaimTypes, payClaimPermission)
  );
};
