# Bulla Protocol V2

`under construction 🏗`

## Clone Repo

```bash
    git clone https://github.com/bulla-network/bulla-protocol-contracts.git
    cd bulla-protocol-contracts
    yarn
```

## Foundry Install

```bash
    curl -L https://foundry.paradigm.xyz | bash
```

- Reload your terminal window then run

```bash
    foundryup
```

## Developing

Run tests in verbose watch mode by running

```bash
    yarn dev
```

## Deploying

Bash arguments - these can either go in a .env or placed in the cli:

1. `LOCK_STATE` - the contract is deployable in a lock state: (0 = unlocked, 1 = no new claims, 2 = completely locked to EOA transactions)
2. `RPC_URL` - the contract is deployable in a lock state: (0 = unlocked, 1 = no new claims, 2 = completely locked to EOA transactions)
3. `PRIVATE_KEY` - the private key of the deployer address (see forge's --ledger or --trezor wallet options for hardware wallet deployment details)

Notice: The deployer address will be the owner of the contract.

Example:

```bash
anvil
source .env.development # for a local anvil server # $ source .env for prod
LOCK_STATE=$LOCK_STATE forge script script/Deployment.s.sol:Deployment --fork-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvvv
```
