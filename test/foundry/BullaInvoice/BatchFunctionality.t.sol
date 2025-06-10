// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {WETH} from "contracts/mocks/weth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC20PermitMock} from "openzeppelin-contracts/contracts/mocks/ERC20PermitMock.sol";
import {
    Claim,
    Status,
    ClaimBinding,
    CreateClaimParams,
    LockState,
    ClaimMetadata,
    CreateClaimApprovalType,
    PayClaimApprovalType,
    ClaimPaymentApprovalParam
} from "contracts/types/Types.sol";
import {BullaClaim} from "contracts/BullaClaim.sol";
import {BullaInvoice, CreateInvoiceParams, Invoice} from "src/BullaInvoice.sol";
import {Deployer} from "script/Deployment.s.sol";
import {BullaInvoiceTestHelper} from "test/foundry/BullaInvoice/BullaInvoiceTestHelper.sol";
import {EIP712Helper} from "test/foundry/BullaClaim/BullaClaimTestHelper.sol";
import {CreateInvoiceParamsBuilder} from "test/foundry/BullaInvoice/CreateInvoiceParamsBuilder.sol";

contract TestBullaInvoiceBatchFunctionality is BullaInvoiceTestHelper {
    uint256 creditorPK = uint256(0x01);
    uint256 debtorPK = uint256(0x02);
    uint256 charliePK = uint256(0x03);
    uint256 alicePK = uint256(0x04);
    
    address creditor = vm.addr(creditorPK);
    address debtor = vm.addr(debtorPK);
    address charlie = vm.addr(charliePK);
    address alice = vm.addr(alicePK);
    
    ERC20PermitMock public permitToken;
    
    function setUp() public {
        weth = new WETH();
        permitToken = new ERC20PermitMock("PermitToken", "PT", address(this), 1000000 ether);

        vm.label(address(this), "TEST_CONTRACT");
        vm.label(creditor, "CREDITOR");
        vm.label(debtor, "DEBTOR");
        vm.label(charlie, "CHARLIE");
        vm.label(alice, "ALICE");

        bullaClaim = (new Deployer()).deploy_test({_deployer: address(this), _initialLockState: LockState.Unlocked});
        sigHelper = new EIP712Helper(address(bullaClaim));
        bullaInvoice = new BullaInvoice(address(bullaClaim), address(this), 0, 0, 0);

        // Setup token balances
        weth.transferFrom(address(this), creditor, 10000 ether);
        weth.transferFrom(address(this), debtor, 10000 ether);
        weth.transferFrom(address(this), charlie, 10000 ether);
        weth.transferFrom(address(this), alice, 10000 ether);
        
        permitToken.transfer(creditor, 10000 ether);
        permitToken.transfer(debtor, 10000 ether);
        permitToken.transfer(charlie, 10000 ether);
        permitToken.transfer(alice, 10000 ether);

        // Setup ETH balances
        vm.deal(creditor, 10000 ether);
        vm.deal(debtor, 10000 ether);
        vm.deal(charlie, 10000 ether);
        vm.deal(alice, 10000 ether);
    }

    /*///////////////////// HELPER FUNCTIONS FOR PERMISSIONS /////////////////////*/

    function _getUserPK(address user) internal view returns (uint256) {
        if (user == creditor) return creditorPK;
        if (user == debtor) return debtorPK;
        if (user == charlie) return charliePK;
        if (user == alice) return alicePK;
        return 12345; // default
    }

    /*///////////////////// CORE BATCH FUNCTIONALITY TESTS /////////////////////*/

    function testBatch_EmptyArray() public {
        bytes[] memory calls = new bytes[](0);
        
        // Should not revert with empty array
        bullaInvoice.batch(calls, true);
        bullaInvoice.batch(calls, false);
    }

    function testBatch_SingleOperation() public {
        // Setup permissions 
        _permitCreateInvoice(creditorPK);
        
        bytes[] memory calls = new bytes[](1);
        
        // Create a single invoice via batch
        calls[0] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).build())
        );
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify invoice was created
        Claim memory claim = bullaClaim.getClaim(1);
        assertEq(claim.originalCreditor, creditor);
        assertEq(claim.debtor, debtor);
    }

    function testBatch_MultipleHomogeneousOperations() public {
        // Setup permissions for multiple invoice creations 
        _permitCreateInvoice(creditorPK, 3);
        
        bytes[] memory calls = new bytes[](3);
        
        // Create multiple invoices in batch
        calls[0] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(1 ether).build())
        );
        calls[1] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(charlie).withClaimAmount(2 ether).build())
        );
        calls[2] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(alice).withClaimAmount(3 ether).build())
        );
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify all invoices were created
        Claim memory claim1 = bullaClaim.getClaim(1);
        Claim memory claim2 = bullaClaim.getClaim(2);
        Claim memory claim3 = bullaClaim.getClaim(3);
        
        assertEq(claim1.claimAmount, 1 ether);
        assertEq(claim2.claimAmount, 2 ether);
        assertEq(claim3.claimAmount, 3 ether);
        assertEq(claim1.debtor, debtor);
        assertEq(claim2.debtor, charlie);
        assertEq(claim3.debtor, alice);
    }

    function testBatch_RevertOnFail_True() public {
        // Setup permissions for multiple invoice creations
        _permitCreateInvoice(creditorPK, 3);
        
        bytes[] memory calls = new bytes[](3);
        
        // First call succeeds
        calls[0] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).build())
        );
        
        // Second call fails (invalid claim amount)
        calls[1] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(0).build())
        );
        
        // Third call would succeed but won't be reached
        calls[2] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(charlie).build())
        );
        
        vm.prank(creditor);
        vm.expectRevert("Transaction reverted silently");
        bullaInvoice.batch(calls, true);
        
        // Verify no invoices were created due to revert
        assertEq(bullaClaim.currentClaimId(), 0);
    }

    function testBatch_RevertOnFail_False() public {
        // Setup permissions for multiple invoice creations
        _permitCreateInvoice(creditorPK, 3);
        
        bytes[] memory calls = new bytes[](3);
        
        // First call succeeds
        calls[0] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).build())
        );
        
        // Second call fails (invalid claim amount)
        calls[1] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).withClaimAmount(0).build())
        );
        
        // Third call succeeds
        calls[2] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder().withDebtor(charlie).build())
        );
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, false);
        
        // Verify first and third invoices were created, second failed
        assertEq(bullaClaim.currentClaimId(), 2);
        
        Claim memory claim1 = bullaClaim.getClaim(1);
        Claim memory claim2 = bullaClaim.getClaim(2);
        
        assertEq(claim1.debtor, debtor);
        assertEq(claim2.debtor, charlie);
    }

    /*///////////////////// BATCH CREATE INVOICE TESTS /////////////////////*/

    function testBatch_CreateInvoicesWithMetadata() public {
        // Setup permissions for multiple invoice creations
        _permitCreateInvoice(creditorPK, 2);
        
        ClaimMetadata memory metadata1 = ClaimMetadata({
            tokenURI: "https://example.com/1",
            attachmentURI: "https://attachment.com/1"
        });
        
        ClaimMetadata memory metadata2 = ClaimMetadata({
            tokenURI: "https://example.com/2", 
            attachmentURI: "https://attachment.com/2"
        });
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(
            BullaInvoice.createInvoiceWithMetadata,
            (new CreateInvoiceParamsBuilder().withDebtor(debtor).build(), metadata1)
        );
        calls[1] = abi.encodeCall(
            BullaInvoice.createInvoiceWithMetadata,
            (new CreateInvoiceParamsBuilder().withDebtor(charlie).build(), metadata2)
        );
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify metadata was set
        (string memory tokenURI1, string memory attachmentURI1) = bullaClaim.claimMetadata(1);
        (string memory tokenURI2, string memory attachmentURI2) = bullaClaim.claimMetadata(2);
        
        assertEq(tokenURI1, "https://example.com/1");
        assertEq(attachmentURI1, "https://attachment.com/1");
        assertEq(tokenURI2, "https://example.com/2");
        assertEq(attachmentURI2, "https://attachment.com/2");
    }

    /*///////////////////// BATCH PAY INVOICE TESTS /////////////////////*/

    function testBatch_PayMultipleInvoices_ERC20() public {
        // Create WETH invoices
        _permitCreateInvoice(creditorPK, 3);
        
        vm.startPrank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 invoiceId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withToken(address(weth)).build()
        );
        uint256 invoiceId3 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).withToken(address(weth)).build()
        );
        vm.stopPrank();
        
        // Setup payment permissions 
        _permitPayInvoice(debtorPK);
        
        // Ensure debtor has WETH tokens
        vm.prank(debtor);
        weth.deposit{value: 5 ether}();
        
        bytes[] memory calls = new bytes[](3);
        
        calls[0] = abi.encodeCall(BullaInvoice.payInvoice, (invoiceId1, 1 ether));
        calls[1] = abi.encodeCall(BullaInvoice.payInvoice, (invoiceId2, 1 ether));
        calls[2] = abi.encodeCall(BullaInvoice.payInvoice, (invoiceId3, 1 ether));
        
        // Approve tokens for batch payment
        vm.prank(debtor);
        weth.approve(address(bullaInvoice), 3 ether);
        
        vm.prank(debtor);
        bullaInvoice.batch(calls, true);
        
        // Verify all invoices were paid
        Claim memory claim1 = bullaClaim.getClaim(invoiceId1);
        Claim memory claim2 = bullaClaim.getClaim(invoiceId2);
        Claim memory claim3 = bullaClaim.getClaim(invoiceId3);
        
        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
        assertEq(uint256(claim3.status), uint256(Status.Paid));
        
        // Verify NFT ownership transferred to payer
        assertEq(bullaClaim.ownerOf(invoiceId1), debtor);
        assertEq(bullaClaim.ownerOf(invoiceId2), debtor);
        assertEq(bullaClaim.ownerOf(invoiceId3), debtor);
    }

    /*///////////////////// BATCH MANAGEMENT TESTS /////////////////////*/

    function testBatch_UpdateMultipleBindings() public {
        // Setup permissions for creating 2 invoices
        _permitCreateInvoice(creditorPK, 2);
        
        // Create invoices
        vm.startPrank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).build()
        );
        uint256 invoiceId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(charlie).build()
        );
        vm.stopPrank();
        
        // Setup update binding permissions 
        _permitUpdateInvoiceBinding(creditorPK, 2);
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaInvoice.updateBinding, (invoiceId1, ClaimBinding.BindingPending));
        calls[1] = abi.encodeCall(BullaInvoice.updateBinding, (invoiceId2, ClaimBinding.BindingPending));
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        Claim memory claim1 = bullaClaim.getClaim(invoiceId1);
        Claim memory claim2 = bullaClaim.getClaim(invoiceId2);
        
        assertEq(uint256(claim1.binding), uint256(ClaimBinding.BindingPending));
        assertEq(uint256(claim2.binding), uint256(ClaimBinding.BindingPending));
    }

    function testBatch_CancelMultipleInvoices() public {
        // Setup permissions for creating 2 invoices
        _permitCreateInvoice(creditorPK, 2);
        
        // Create invoices
        vm.startPrank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).build()
        );
        uint256 invoiceId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(charlie).build()
        );
        vm.stopPrank();
        
        // Setup cancel permissions 
        _permitCancelInvoice(creditorPK, 2);
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaInvoice.cancelInvoice, (invoiceId1, "Rescinding invoice 1"));
        calls[1] = abi.encodeCall(BullaInvoice.cancelInvoice, (invoiceId2, "Rescinding invoice 2"));
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify invoices were rescinded
        Claim memory claim1 = bullaClaim.getClaim(invoiceId1);
        Claim memory claim2 = bullaClaim.getClaim(invoiceId2);
        
        assertEq(uint256(claim1.status), uint256(Status.Rescinded));
        assertEq(uint256(claim2.status), uint256(Status.Rescinded));
    }

    function testBatch_ImpairMultipleInvoices() public {
        // Create invoices with due dates in the past and move time forward
        uint256 pastDueBy = block.timestamp + 1 days;
        
        // Setup permissions first
        _permitCreateInvoice(creditorPK, 2);
        
        vm.startPrank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder()
                .withDebtor(debtor)
                .withDueBy(pastDueBy)
                .withImpairmentGracePeriod(1 hours)
                .build()
        );
        uint256 invoiceId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder()
                .withDebtor(charlie)
                .withDueBy(pastDueBy)
                .withImpairmentGracePeriod(1 hours)
                .build()
        );
        vm.stopPrank();
        
        // Move time forward past due date and grace period
        vm.warp(pastDueBy + 2 hours);
        
        // Setup impair permissions 
        _permitImpairInvoice(creditorPK, 2);
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaInvoice.impairInvoice, (invoiceId1));
        calls[1] = abi.encodeCall(BullaInvoice.impairInvoice, (invoiceId2));
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify invoices are now impaired
        Claim memory claim1 = bullaClaim.getClaim(invoiceId1);
        Claim memory claim2 = bullaClaim.getClaim(invoiceId2);
        
        assertEq(uint256(claim1.status), uint256(Status.Impaired));
        assertEq(uint256(claim2.status), uint256(Status.Impaired));
    }

    function testBatch_MarkMultipleAsPaid() public {
        // Setup permissions for creating 2 invoices
        _permitCreateInvoice(creditorPK, 2);
        
        // Create invoices
        vm.startPrank(creditor);
        uint256 invoiceId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(debtor).build()
        );
        uint256 invoiceId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(charlie).build()
        );
        vm.stopPrank();
        
        // Setup mark as paid permissions 
        _permitMarkInvoiceAsPaid(creditorPK, 2);
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaInvoice.markInvoiceAsPaid, (invoiceId1));
        calls[1] = abi.encodeCall(BullaInvoice.markInvoiceAsPaid, (invoiceId2));
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // Verify both invoices were paid
        Claim memory claim1 = bullaClaim.getClaim(invoiceId1);
        Claim memory claim2 = bullaClaim.getClaim(invoiceId2);
        
        assertEq(uint256(claim1.status), uint256(Status.Paid));
        assertEq(uint256(claim2.status), uint256(Status.Paid));
    }

    function testBatch_DeliverMultiplePurchaseOrders() public {
        // Setup permissions first
        _permitCreateInvoice(creditorPK, 2);
        
        // Create purchase orders with delivery dates
        vm.startPrank(creditor);
        uint256 poId1 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder()
                .withDebtor(debtor)
                .withDeliveryDate(block.timestamp + 1 days)
                .build()
        );
        uint256 poId2 = bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder()
                .withDebtor(charlie)
                .withDeliveryDate(block.timestamp + 1 days)
                .build()
        );
        vm.stopPrank();
        
        bytes[] memory calls = new bytes[](2);
        
        calls[0] = abi.encodeCall(BullaInvoice.deliverPurchaseOrder, (poId1));
        calls[1] = abi.encodeCall(BullaInvoice.deliverPurchaseOrder, (poId2));
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        // verify the calls succeeded
        assertEq(bullaClaim.currentClaimId(), 2);
    }

    /*///////////////////// PERMITTOKEN TESTS /////////////////////*/

    function testPermitToken_ValidSignature() public {
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x1234;
        address owner = vm.addr(privateKey);
        
        // Transfer tokens to owner
        permitToken.transfer(owner, amount);
        
        // Create permit signature
        (uint8 v, bytes32 r, bytes32 s) = _permitERC20Token(
            privateKey,
            address(permitToken),
            address(bullaClaim),
            amount,
            deadline
        );
        
        // Call permitToken directly (not through batch)
        (bool success,) = address(bullaClaim).call(
            abi.encodeWithSignature(
                "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
                address(permitToken), owner, address(bullaClaim), amount, deadline, v, r, s
            )
        );
        
        assertTrue(success, "permitToken call should succeed");
        
        // Verify allowance was set
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
    }

    function testPermitToken_InBatch() public {
        uint256 amount = 1000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 privateKey = 0x5678;
        address owner = vm.addr(privateKey);
        
        // Setup permissions for invoice creation 
        _permitCreateClaim(privateKey, address(bullaInvoice), 1);
        
        // Transfer tokens to owner
        permitToken.transfer(owner, amount);
        
        // Create permit signature 
        (uint8 v, bytes32 r, bytes32 s) = _permitERC20Token(
            privateKey,
            address(permitToken),
            address(bullaClaim),
            amount,
            deadline
        );
        
        bytes[] memory calls = new bytes[](2);
        
        // First call: permit
        calls[0] = abi.encodeWithSignature(
            "permitToken(address,address,address,uint256,uint256,uint8,bytes32,bytes32)",
            address(permitToken), owner, address(bullaClaim), amount, deadline, v, r, s
        );
        
        // Second call: create invoice that would use the permitted tokens
        calls[1] = abi.encodeCall(
            BullaInvoice.createInvoice,
            (new CreateInvoiceParamsBuilder()
                .withDebtor(debtor)
                .withToken(address(permitToken))
                .withClaimAmount(amount)
                .build())
        );
        
        vm.prank(owner);
        bullaInvoice.batch(calls, true);
        
        // Verify both permit and invoice creation worked
        assertEq(permitToken.allowance(owner, address(bullaClaim)), amount);
        
        Claim memory claim = bullaClaim.getClaim(1);
        assertEq(claim.originalCreditor, owner);
        assertEq(claim.token, address(permitToken));
        assertEq(claim.claimAmount, amount);
    }

    /*///////////////////// EDGE CASES AND ERROR HANDLING /////////////////////*/

    function testBatch_MaxGasLimit() public {
        // Test with a reasonable number of operations to avoid gas limit issues
        uint256 numInvoices = 10;
        
        // Setup permissions for multiple invoice creations
        _permitCreateInvoice(creditorPK, uint64(numInvoices));
        
        bytes[] memory calls = new bytes[](numInvoices);
        
        for (uint256 i = 0; i < numInvoices; i++) {
            calls[i] = abi.encodeCall(
                BullaInvoice.createInvoice,
                (new CreateInvoiceParamsBuilder()
                    .withDebtor(address(uint160(0x1000 + i)))
                    .build())
            );
        }
        
        vm.prank(creditor);
        bullaInvoice.batch(calls, true);
        
        assertEq(bullaClaim.currentClaimId(), numInvoices);
    }

    /*///////////////////// HELPER FUNCTIONS /////////////////////*/

    function _newInvoice(address _creditor, address _debtor) internal returns (uint256) {
        _permitCreateInvoice(_getUserPK(_creditor));
        
        vm.prank(_creditor);
        return bullaInvoice.createInvoice(
            new CreateInvoiceParamsBuilder().withDebtor(_debtor).build()
        );
    }
} 