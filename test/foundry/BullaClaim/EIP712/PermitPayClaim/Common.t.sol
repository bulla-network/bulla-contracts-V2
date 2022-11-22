// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "contracts/BullaClaim.sol";
import {Deployer} from "script/Deployment.s.sol";
import {ERC1271WalletMock} from "contracts/mocks/ERC1271Wallet.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {Test} from "forge-std/Test.sol";
import {EIP712Helper, privateKeyValidity, splitSig} from "test/foundry/BullaClaim/EIP712/Utils.sol";

/// @notice a base boilerplate class to inherit on PermitPayClaim tests
contract PermitPayClaimTest is Test {
    BullaClaim internal bullaClaim;
    WETH internal weth;
    EIP712Helper internal sigHelper;
    ERC1271WalletMock internal eip1271Wallet;

    uint256 alicePK = uint256(0xA11c3);
    address alice = vm.addr(alicePK);
    address bob = address(0xB0b);

    uint256 OCTOBER_28TH_2022 = 1666980688;
    uint256 OCTOBER_23RD_2022 = 1666560688;

    event PayClaimApproved(
        address indexed user,
        address indexed operator,
        PayClaimApprovalType indexed approvalType,
        uint256 approvalDeadline,
        ClaimPaymentApprovalParam[] paymentApprovals
    );

    function setUp() public {
        (bullaClaim,) = (new Deployer()).deploy_test({
            _deployer: address(this),
            _feeReceiver: address(0xfee),
            _initialLockState: LockState.Unlocked,
            _feeBPS: 0
        });
        sigHelper = new EIP712Helper(address(bullaClaim));
        eip1271Wallet = new ERC1271WalletMock();
    }

    function _newClaim(address _creditor, address _debtor) internal returns (uint256 claimId) {
        claimId = bullaClaim.createClaim(
            CreateClaimParams({
                creditor: _creditor,
                debtor: _debtor,
                description: "",
                claimAmount: 1 ether,
                dueBy: block.timestamp + 1 days,
                token: address(weth),
                controller: address(0),
                feePayer: FeePayer.Debtor,
                binding: ClaimBinding.Unbound,
                payerReceivesClaimOnPayment: true
            })
        );
    }

    function _generateClaimPaymentApprovals(uint8 count) internal pure returns (ClaimPaymentApprovalParam[] memory) {
        ClaimPaymentApprovalParam[] memory paymentApprovals = new ClaimPaymentApprovalParam[](count);
        for (uint256 i = 0; i < count; i++) {
            paymentApprovals[i] =
                ClaimPaymentApprovalParam({claimId: i, approvedAmount: 143 * i + 1, approvalDeadline: 0});
        }
        return paymentApprovals;
    }
}
