import { ethers } from "hardhat";
import { expect } from "chai";
import {
  BullaClaim,
  PenalizedClaim,
  BullaExtensionRegistry,
  BullaClaimEIP712,
  WETH,
} from "../../../typechain-types";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import {
  ClaimPaymentApprovalStruct,
  CreateClaimApprovalStruct,
  PayClaimApprovalStruct,
} from "../../../typechain-types/src/BullaClaim";
import {
  ClaimBinding,
  CreateClaimApprovalType,
  declareSignerWithAddress,
  deployContractsFixture,
  FeePayer,
  generateCreateClaimSignature,
  generatePayClaimSignature,
  PayClaimApprovalType,
  UNLIMITED_APPROVAL_COUNT,
} from "./common";
import { BigNumber } from "ethers";

describe("BullaClaim EIP712 approval signatures", async () => {
  let [deployer, alice, bob, wallet4] = declareSignerWithAddress();

  let bullaClaim: BullaClaim,
    bullaClaimEIP712: BullaClaimEIP712,
    penalizedClaim: PenalizedClaim,
    registry: BullaExtensionRegistry,
    weth: WETH;

  before(async () => {
    [deployer, alice, bob, wallet4] = await ethers.getSigners();
    [bullaClaim, bullaClaimEIP712, penalizedClaim, registry, weth] =
      await loadFixture(deployContractsFixture(deployer));
    await weth
      .connect(deployer)
      .transfer(alice.address, ethers.utils.parseEther("10000"));
  });

  it("permitCreateClaim", async () => {
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

    let [approval] = (await bullaClaim.approvals(
      alice.address,
      penalizedClaim.address
    )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];

    expect(approval.approvalCount).to.equal(UNLIMITED_APPROVAL_COUNT);
    expect(approval.nonce).to.equal(1);

    // create the claim with the approval
    await (await penalizedClaim.connect(alice).createClaim(claim)).wait();

    // expect approval count to decrement
    [approval] = (await bullaClaim.approvals(
      bob.address,
      penalizedClaim.address
    )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];
    expect(approval.approvalCount).to.equal(0);
  });

  describe("permitPayClaim", async () => {
    it("IsApprovedForAll", async () => {
      [bullaClaim, bullaClaimEIP712, penalizedClaim, registry] =
        await loadFixture(deployContractsFixture(deployer));

      const APPROVAL_TYPE = PayClaimApprovalType.IsApprovedForAll;
      const EXPIRARY_TIMESTAMP = Math.floor(Date.now() / 1000) + 100;
      const PAY_CLAIM_APPROVALS: ClaimPaymentApprovalStruct[] = [];

      // approve penalized claim to create bound claims for alice
      const permitPayClaimSig = await generatePayClaimSignature({
        bullaClaimAddress: bullaClaim.address,
        signer: alice,
        operatorName: await registry.getExtensionForSignature(
          penalizedClaim.address
        ),
        operator: penalizedClaim.address,
        approvalType: APPROVAL_TYPE,
        paymentApprovals: PAY_CLAIM_APPROVALS,
        approvalDeadline: EXPIRARY_TIMESTAMP,
      });

      await expect(
        bullaClaim
          .connect(bob) // notice anyone can submit the permit
          .permitPayClaim(
            alice.address,
            penalizedClaim.address,
            APPROVAL_TYPE,
            EXPIRARY_TIMESTAMP,
            PAY_CLAIM_APPROVALS,
            permitPayClaimSig
          )
      ).to.not.be.reverted;

      let [, approval] = (await bullaClaim.approvals(
        alice.address,
        penalizedClaim.address
      )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];

      expect(approval.approvalType).to.equal(APPROVAL_TYPE);
      expect(approval.nonce).to.equal(1);
      expect(approval.approvalDeadline).to.equal(EXPIRARY_TIMESTAMP);
      expect(approval.claimApprovals).to.deep.equal([]);
    });

    it("IsApprovedForSpecific", async () => {
      [bullaClaim, bullaClaimEIP712, penalizedClaim, registry] =
        await loadFixture(deployContractsFixture(deployer));

      const accountant = wallet4;

      const claim = {
        creditor: alice.address,
        debtor: bob.address,
        claimAmount: ethers.utils.parseEther("1"),
        dueBy: Math.floor(Date.now() / 1000) + 100,
        description: `claim description ${Math.random()}`,
        token: weth.address,
        delegator: ethers.constants.AddressZero,
        feePayer: FeePayer.Debtor,
        binding: ClaimBinding.Unbound,
      };

      await (await bullaClaim.connect(alice).createClaim(claim)).wait();

      const APPROVAL_TYPE = PayClaimApprovalType.IsApprovedForSpecific;
      const EXPIRARY_TIMESTAMP = Math.floor(Date.now() / 1000) + 100;
      const PAY_CLAIM_APPROVALS: ClaimPaymentApprovalStruct[] = [
        {
          approvalDeadline: EXPIRARY_TIMESTAMP,
          approvedAmount: ethers.utils.parseEther("1"),
          claimId: 1,
        },
      ];

      // approve penalized claim to create bound claims for alice
      const permitPayClaimSig = await generatePayClaimSignature({
        bullaClaimAddress: bullaClaim.address,
        signer: alice,
        operatorName: await registry.getExtensionForSignature(
          accountant.address
        ),
        operator: accountant.address,
        approvalType: APPROVAL_TYPE,
        paymentApprovals: PAY_CLAIM_APPROVALS,
        approvalDeadline: EXPIRARY_TIMESTAMP,
      });

      await expect(
        bullaClaim
          .connect(bob) // notice anyone can submit the permit
          .permitPayClaim(
            alice.address,
            accountant.address,
            APPROVAL_TYPE,
            EXPIRARY_TIMESTAMP,
            PAY_CLAIM_APPROVALS,
            permitPayClaimSig
          )
      ).to.not.be.reverted;

      let [, approval] = (await bullaClaim.approvals(
        alice.address,
        accountant.address
      )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];

      expect(approval.approvalType).to.equal(APPROVAL_TYPE);
      expect(approval.nonce).to.equal(1);
      expect(approval.approvalDeadline).to.equal(EXPIRARY_TIMESTAMP);
      expect([
        {
          approvedAmount: approval.claimApprovals[0].approvedAmount,
          approvalDeadline:
            approval.claimApprovals[0].approvalDeadline,
          claimId: BigNumber.from(approval.claimApprovals[0].claimId),
        },
      ]).to.deep.equal(PAY_CLAIM_APPROVALS);

      await weth.connect(alice).approve(bullaClaim.address, claim.claimAmount);
      await bullaClaim
        .connect(accountant)
        .payClaimFrom(alice.address, 1, claim.claimAmount);

      [, approval] = (await bullaClaim.approvals(
        alice.address,
        accountant.address
      )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];

      expect(approval.approvalType).to.equal(APPROVAL_TYPE);
      expect(approval.claimApprovals).to.deep.equal([]);
    });

    it("Unapproved (revoke)", async () => {
      [bullaClaim, bullaClaimEIP712, penalizedClaim, registry] =
        await loadFixture(deployContractsFixture(deployer));

      const APPROVAL_TYPE = PayClaimApprovalType.Unapproved;
      const EXPIRARY_TIMESTAMP = 0;
      const PAY_CLAIM_APPROVALS: ClaimPaymentApprovalStruct[] = [];

      // approve penalized claim to create bound claims for alice
      const permitPayClaimSig = await generatePayClaimSignature({
        bullaClaimAddress: bullaClaim.address,
        signer: alice,
        operatorName: await registry.getExtensionForSignature(
          penalizedClaim.address
        ),
        operator: penalizedClaim.address,
        approvalType: APPROVAL_TYPE,
        paymentApprovals: PAY_CLAIM_APPROVALS,
        approvalDeadline: EXPIRARY_TIMESTAMP,
      });

      await expect(
        bullaClaim
          .connect(bob) // notice anyone can submit the permit
          .permitPayClaim(
            alice.address,
            penalizedClaim.address,
            APPROVAL_TYPE,
            EXPIRARY_TIMESTAMP,
            PAY_CLAIM_APPROVALS,
            permitPayClaimSig
          )
      ).to.not.be.reverted;

      let [, approval] = (await bullaClaim.approvals(
        alice.address,
        penalizedClaim.address
      )) as [CreateClaimApprovalStruct, PayClaimApprovalStruct];

      expect(approval.approvalType).to.equal(APPROVAL_TYPE);
      expect(approval.nonce).to.equal(1);
      expect(approval.approvalDeadline).to.equal(0);
      expect(approval.claimApprovals).to.deep.equal([]);
    });
  });
});
