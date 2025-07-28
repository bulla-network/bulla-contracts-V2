# Bulla Protocol V2 Audit Scope

## Project Overview

### Core Concept

Bulla Protocol V2 is a decentralized claims protocol that represents credit relationships as tradeable NFTs. In this system, a "claim" represents any credit relationship between two parties - whether it's an invoice, loan, IOU, or any other form of receivable. The NFT owner is the creditor (the party owed money), while the claim specifies the debtor (the party who owes money).

### Architecture

**BullaClaim as Foundation**
`BullaClaim.sol` serves as the core contract that implements the fundamental claim lifecycle and ERC721 functionality. This contract is designed as a foundation that other specialized contracts (called "controllers") can build upon to create domain-specific credit instruments.

**Controller Pattern**
Controllers are specialized contracts that fully control claims they create, enabling:

- **Extended functionality** beyond basic claim operations (interest calculations, complex payment flows, etc.)
- **Custom business logic** for specific use cases (lending, invoicing, etc)
- **Additional states and workflows** tailored to different financial instruments
- **Domain-specific features** while maintaining core claim properties

Controllers include:

- `BullaFrendLend.sol` - Peer-to-peer lending with compound/simple interest
- `BullaInvoice.sol` - Invoice and purchase order management

**Permission System**
The protocol uses an EIP712-based approval system that allows users to grant specific permissions to controllers without requiring multiple transactions. This enables gasless interactions and streamlined user experiences while maintaining security.

### Ecosystem Vision

This protocol serves as the foundational layer for a broader financial ecosystem that enables:

1. **Credit Marketplace** - Trading of receivables and credit instruments as liquid NFTs
2. **Factoring Services** - Immediate liquidity for businesses by selling receivables at a discount
3. **Receivables Financing** - Using existing receivables as collateral to access immediate funding

### Current Audit Scope

This audit encompasses the core protocol infrastructure and primary controllers. Additionally, `BullaFactoringV2.sol` (previously audited in V1 form) is receiving updates and is included in the scope to ensure the integration remains secure with the latest protocol changes.

## Audit Scope

### Core Contracts

- `src/BullaClaim.sol` - Main claim NFT contract implementing ERC721
- `src/BullaFrendLend.sol` - Peer-to-peer lending functionality
- `src/BullaInvoice.sol` - Invoice and purchase order management
- `src/BullaClaimControllerBase.sol` - Base contract for claim controllers
- `src/BullaApprovalRegistry.sol` - Manages user approvals for claim operations
- `src/BullaControllerRegistry.sol` - Registry for controller contract names

### Additional Audit Components

- `BullaFactoringV2.sol` - Factoring services contract (V1 previously audited, V2 updates under review)

### Libraries

- `src/libraries/CompoundInterestLib.sol` - Interest calculation library
- `src/libraries/BullaClaimValidationLib.sol` - Validation logic library
- `src/libraries/BullaClaimPermitLib.sol` - EIP712 permit functionality

### Interfaces

- `src/interfaces/IBullaClaim.sol` - Main claim contract interface
- `src/interfaces/IBullaFrendLend.sol` - Lending contract interface
- `src/interfaces/IBullaInvoice.sol` - Invoice contract interface
- `src/interfaces/IBullaClaimCore.sol` - Core claim functionality interface
- `src/interfaces/IBullaApprovalRegistry.sol` - Approval registry interface
- `src/interfaces/IBullaControllerRegistry.sol` - Controller registry interface
- `src/interfaces/IBullaClaimAdmin.sol` - Admin functions interface
- `src/interfaces/IClaimMetadataGenerator.sol` - Claim metadata generator interface
- `src/interfaces/IPermissions.sol` - Permissions interface

### Types

- `src/types/Types.sol` - Struct definitions and enums
- 
## Total Scope

- **Core contracts, libraries, interfaces, and type definitions**
- **Comprehensive test coverage with Foundry**
- **Protocol specification and invariants documentation**

## Out of Scope

- `src/mocks/` - All mock contracts used for testing
- `src/libraries/Base64.sol` - Standard Base64 encoding library
- `src/libraries/BoringBatchable.sol` - Standard batching library
- `src/Permissions.sol` - Basic permissions contract
- `src/WhitelistPermissions.sol` - Whitelist permissions contract
- `test/` - All test files
- `script/` - Deployment and verification scripts

## Key Features to Audit

1. **Claim Lifecycle Management** - Creation, payment, cancellation, impairment
2. **ERC721 Compliance** - Token transfers, approvals
3. **Access Controls** - Controller-based permissions, owner functions
4. **Interest Calculations** - Compound and simple interest implementations
5. **EIP712 Signatures** - Permit functionality for controlled claims
6. **Fee Mechanisms** - Protocol fees and withdrawal logic
7. **Batch Operations** - Multiple claim operations in single transaction
8. **Lending Features** - Loan offers, acceptance, repayment
9. **Invoice Features** - Purchase orders, delivery, deposit handling

## Technology Stack

- **Solidity Version**: 0.8.30
- **Token Standards**: ERC721, ERC20
- **Dependencies**: OpenZeppelin, Solmate
- **Signature Standard**: EIP712
- **Test Framework**: Foundry

## Deployment Information

- **Target Networks**: Ethereum, Arbitrum, Polygon, Base, Optimism, other EVMs
- **Upgradeability**: Non-upgradeable contracts
- **Admin Functions**: Owner-controlled parameters and emergency functions
