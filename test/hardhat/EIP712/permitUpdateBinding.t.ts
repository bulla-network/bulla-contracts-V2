import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import {
  BullaClaim,
  BullaClaimPermitLib,
  BullaExtensionRegistry,
  PenalizedClaim,
  WETH,
} from "../../../typechain-types";
import {
  declareSignerWithAddress,
  deployContractsFixture,
  generateUpdateClaimSignature,
  UNLIMITED_APPROVAL_COUNT,
} from "./common";

describe("permit update binding", async () => {
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

  it("permit unlimited updates", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    const permitUpdateBindingSig = await generateUpdateClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: UNLIMITED_APPROVAL_COUNT,
    });

    await 
    // expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitUpdateBinding(
          alice.address,
          penalizedClaim.address,
          UNLIMITED_APPROVAL_COUNT,
          permitUpdateBindingSig
        )
    // ).to.not.be.reverted;

    let [, , approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(UNLIMITED_APPROVAL_COUNT);
    expect(approval.nonce).to.equal(1);
  });

  it("permit limited updates", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    const permitUpdateBindingSig = await generateUpdateClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: 10,
    });

    await expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitUpdateBinding(
          alice.address,
          penalizedClaim.address,
          10,
          permitUpdateBindingSig
        )
    ).to.not.be.reverted;

    let [, , approval, ] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(10);
    expect(approval.nonce).to.equal(1);
  });

  it("permit revoke updates", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    let permitUpdateBindingSig = await generateUpdateClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: UNLIMITED_APPROVAL_COUNT,
    });

    await expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitUpdateBinding(
          alice.address,
          penalizedClaim.address,
          UNLIMITED_APPROVAL_COUNT,
          permitUpdateBindingSig
        )
    ).to.not.be.reverted;

    permitUpdateBindingSig = await generateUpdateClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: 0,
      nonce: 1,
    });

    await expect(
      bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitUpdateBinding(
          alice.address,
          penalizedClaim.address,
          0,
          permitUpdateBindingSig
        )
    ).to.not.be.reverted;

    let [, , approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(0);
    expect(approval.nonce).to.equal(2);
  });
});
