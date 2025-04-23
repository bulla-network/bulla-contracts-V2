# BullaClaim Invariants

**A1**. A user should always be able to mint a claim NFT specifying a `creditor`, a `debtor`, a `token`, an `amount`, a `due date`, a `binding`, and a `controller`.

- **Assume**
  1. The contract is unlocked
  2. The creditor is not address(0). NOTE: includes _any_ smart contract, even ones that can't handle ERC721
  3. `0` < `amount` < `type(uint128).max`
  4. `block.timestmap` < due date < `type(uint40).max` - unless the due date is 0, which is treated
  5. The binding is not `ClaimBinding.Bound` - unless the debtor is the sending address
  6. If a controller is listed, controller is the sending address

**A2 WIP**. Any user should always be able to mark a claim NFT as paid

- **Assume**:
  1. The contract is unlocked or partially unlocked
  2. The claim exists (minted and not burned)
  3. The claim is not rejected, rescinded, or paid
  4. The user holds and has approved `claimAmount` amount of ERC20 / ETH
  5. If the claim is denominated in ETH, the recipient can receive ETH
  6. The token does not revert on calls to `transferFrom`
  7. If there is a controller, `controller` == calling address

## TODO

3. A claim should always follow the ERC721 spec, meaning it can be transferred, it can be approved. Additionally, it can be burned
4. A claim NFT holder should always receive tokens on payment
5. A payer should always receive the claim NFT as a receipt - assume: full payment
