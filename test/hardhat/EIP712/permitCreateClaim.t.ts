import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import {
  BullaClaim, BullaClaimPermitLib, BullaExtensionRegistry, PenalizedClaim, WETH
} from "../../../typechain-types";
import {
  ClaimBinding,
  CreateClaimApprovalType,
  declareSignerWithAddress,
  deployContractsFixture,
  FeePayer,
  generateCreateClaimSignature, UNLIMITED_APPROVAL_COUNT
} from "./common";

describe("permitCreateClaim", async () => {
  let [deployer, alice, bob, wallet4] = declareSignerWithAddress();

  let bullaClaim: BullaClaim,
    BullaClaimPermitLib: BullaClaimPermitLib,
    penalizedClaim: PenalizedClaim,
    registry: BullaExtensionRegistry,
    weth: WETH;

  before(async () => {
    [deployer, alice, bob, wallet4] = await ethers.getSigners();
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry, weth] =
      await loadFixture(deployContractsFixture(deployer));
    await weth
      .connect(deployer)
      .transfer(alice.address, ethers.utils.parseEther("10000"));
  });

  it("approves permit", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
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
    const permitCreateClaimSig = await generateCreateClaimSignature({
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
          permitCreateClaimSig
        )
    ).to.not.be.reverted;

    let [approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(UNLIMITED_APPROVAL_COUNT);
    expect(approval.nonce).to.equal(1);

    // create the claim with the approval
    await (await penalizedClaim.connect(alice).createClaim(claim)).wait();

    // expect approval count to decrement
    [approval] = await bullaClaim.approvals(
      bob.address,
      penalizedClaim.address
    );
    expect(approval.approvalCount).to.equal(0);
  });

  it("revoke approval", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    let permitCreateClaimSig = await generateCreateClaimSignature({
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
          permitCreateClaimSig
        )
    ).to.not.be.reverted;

    permitCreateClaimSig = await generateCreateClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: 0,
      isBindingAllowed: false,
      nonce: 1,
    });

    await expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitCreateClaim(
          alice.address,
          penalizedClaim.address,
          CreateClaimApprovalType.Approved,
          0,
          false,
          permitCreateClaimSig
        )
    ).to.not.be.reverted;

    let [approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(0);
    expect(approval.nonce).to.equal(2);
  });
});
