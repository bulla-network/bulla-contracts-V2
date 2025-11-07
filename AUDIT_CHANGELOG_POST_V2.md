# Audit Changelog - Post v2.0.0

**Last Audit Commit:** `98f30de3e7053256d80b4e820059e9703081056b`  
**Last Audit Date:** September 17, 2025  
**Last Audit Version:** v2.0.0  
**Current Version:** v2.4.0  
**Review Period:** September 17, 2025 - October 31, 2025

---

## Summary

Two features have been added to the protocol since the last audit:

1. **Processing Fee in BullaFrendLendV2** (v2.2.0 - October 20, 2025)
2. **Paid Callback System** (v2.4.0 - October 31, 2025)

**Total Changes:** 346 lines added, 7 lines removed across 8 files

---

## Version History

| Version | Date         | Commit    | Description                                     |
| ------- | ------------ | --------- | ----------------------------------------------- |
| v2.0.0  | Sep 17, 2025 | `98f30de` | **Last Audited Version**                        |
| v2.2.0  | Oct 20, 2025 | `2099a38` | Add processing fee to BullaFrendLendV2          |
| v2.4.0  | Oct 31, 2025 | `9d3e21a` | Add paid callback to BullaClaim and controllers |

---

## Feature 1: Processing Fee (v2.2.0)

**Commit:** `2099a385a59d4551adc73fb45f0a32091d9f377a`  
**Date:** October 20, 2025  
**Files Changed:** BullaFrendLendV2.sol, IBullaFrendLendV2.sol

### What Was Added

Added an upfront processing fee that is deducted from the loan amount when a loan offer is accepted.

---

## Feature 2: Paid Callback System (v2.4.0)

**Commit:** `9d3e21af4e2ab32ca1c077af5126fe7b44ac8703`  
**Date:** October 31, 2025  
**Files Changed:** BullaClaimV2.sol, BullaFrendLendV2.sol, BullaInvoice.sol, Types.sol, and interfaces

### What Was Added

Added a callback system that allows creditors to register a contract function to be called automatically when their claim is fully paid.

---

## Files Changed Summary

```
src/BullaClaimV2.sol                 | +178, -1
src/BullaFrendLendV2.sol             | +80, -2
src/BullaInvoice.sol                 | +42, -1
src/interfaces/IBullaClaimCore.sol   | +21, -1
src/interfaces/IBullaClaimV2.sol     | +8, -0
src/interfaces/IBullaFrendLendV2.sol | +11, -1
src/interfaces/IBullaInvoice.sol     | +1, -0
src/types/Types.sol                  | +5, -0
───────────────────────────────────────────────
Total:                               | +346, -7
```
