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
  generateCancelClaimSignature,
  UNLIMITED_APPROVAL_COUNT,
} from "./common";

describe("permit cancel claim", async () => {
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

  it("permit approve cancel", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    const permitCancelClaimSig = await generateCancelClaimSignature({
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
        .permitCancelClaim(
          alice.address,
          penalizedClaim.address,
          UNLIMITED_APPROVAL_COUNT,
          permitCancelClaimSig
        )
    ).to.not.be.reverted;

    let [, , , approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(UNLIMITED_APPROVAL_COUNT);
    expect(approval.nonce).to.equal(1);
  });

  it("limited cancellation approval", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    const permitCancelClaimSig = await generateCancelClaimSignature({
      bullaClaimAddress: bullaClaim.address,
      signer: alice,
      operatorName: await registry.getExtensionForSignature(
        penalizedClaim.address
      ),
      operator: penalizedClaim.address,
      approvalCount: 10,
    });

    await expect(
      await bullaClaim
        .connect(bob) // notice anyone can submit the permit
        .permitCancelClaim(
          alice.address,
          penalizedClaim.address,
          10,
          permitCancelClaimSig
        )
    ).to.not.be.reverted;

    let [, , , approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(10);
    expect(approval.nonce).to.equal(1);
  });

  it("revoke cancellations", async () => {
    [bullaClaim, BullaClaimPermitLib, penalizedClaim, registry] =
      await loadFixture(deployContractsFixture(deployer));

    let permitCancelClaimSig = await generateCancelClaimSignature({
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
        .permitCancelClaim(
          alice.address,
          penalizedClaim.address,
          UNLIMITED_APPROVAL_COUNT,
          permitCancelClaimSig
        )
    ).to.not.be.reverted;

    permitCancelClaimSig = await generateCancelClaimSignature({
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
        .permitCancelClaim(
          alice.address,
          penalizedClaim.address,
          0,
          permitCancelClaimSig
        )
    ).to.not.be.reverted;

    let [, , , approval] = await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    );

    expect(approval.approvalCount).to.equal(0);
    expect(approval.nonce).to.equal(2);
  });
});
