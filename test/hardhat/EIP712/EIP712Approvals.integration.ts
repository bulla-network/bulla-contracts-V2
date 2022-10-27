import { ethers } from "hardhat";
import { expect } from "chai";
import {
  BullaClaim,
  PenalizedClaim,
  BullaExtensionRegistry,
  BullaClaimEIP712,
} from "../../../typechain-types";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { CreateClaimApprovalStruct } from "../../../typechain-types/src/BullaClaim";
import {
  ClaimBinding,
  CreateClaimApprovalType,
  declareSignerWithAddress,
  deployContractsFixture,
  FeePayer,
  generateSignature,
  UNLIMITED_APPROVAL_COUNT,
} from "./common";

describe("PayClaimEIP712Test", async () => {
  let [deployer, alice, bob] = declareSignerWithAddress();

  let bullaClaim: BullaClaim,
    bullaClaimEIP712: BullaClaimEIP712,
    penalizedClaim: PenalizedClaim,
    registry: BullaExtensionRegistry;

  before(async () => {
    [deployer, alice, bob] = await ethers.getSigners();
    [bullaClaim, bullaClaimEIP712, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));
  });

  it("it accepts a valid signature", async () => {
    [bullaClaim, bullaClaimEIP712, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    const claim = {
      creditor: alice.address,
      debtor: bob.address,
      claimAmount: ethers.utils.parseEther("1"),
      dueBy: Math.floor(Date.now() / 1000) + 100,
      description: `claim description ${Math.random()}`,
      token: ethers.constants.AddressZero, // native token
      delegator: penalizedClaim.address,
      feePayer: FeePayer.Debtor,
      binding: ClaimBinding.Unbound,
    };

    // approve penalized claim to create bound claims for alice
    const userSignature = await generateSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: UNLIMITED_APPROVAL_COUNT,
      isBindingAllowed: true,
    });

    await expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitCreateClaim(
          alice.address,
          penalizedClaim.address,
          CreateClaimApprovalType.Approved,
          UNLIMITED_APPROVAL_COUNT,
          true,
          userSignature
        )
    ).to.not.be.reverted;

    const approval = (await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    )) as CreateClaimApprovalStruct;

    expect(approval.approvalCount).to.equal(UNLIMITED_APPROVAL_COUNT);
    expect(approval.nonce).to.equal(1);

    // create the claim with the approval
    await (await penalizedClaim.connect(alice).createClaim(claim)).wait();

    // expect approval count to decrement
    expect(
      (
        (await bullaClaim.approvals(
          bob.address,
          penalizedClaim.address
        )) as CreateClaimApprovalStruct
      ).approvalCount
    ).to.equal(0);
  });
});
