# [1.4.0](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.3.0...v1.4.0) (2025-06-19)


### Features

* add protocol fee exemption whitelist in BullaClaim ([#63](https://github.com/bulla-network/bulla-contracts-V2/issues/63)) ([5f5f890](https://github.com/bulla-network/bulla-contracts-V2/commit/5f5f89031cb1b3388b792aa25f66f3f183d179e6))

# [1.3.0](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.2.1...v1.3.0) (2025-06-18)


### Features

* move protocol fee to BullaClaim, remove from invoice and frendlend ([#61](https://github.com/bulla-network/bulla-contracts-V2/issues/61)) ([80df68f](https://github.com/bulla-network/bulla-contracts-V2/commit/80df68f8d23f9e865047963d0c4e285127bda8f6))

## [1.2.1](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.2.0...v1.2.1) (2025-06-17)


### Bug Fixes

* upgrade foundry and solc to 0.8.30 ([#60](https://github.com/bulla-network/bulla-contracts-V2/issues/60)) ([45152f6](https://github.com/bulla-network/bulla-contracts-V2/commit/45152f6550e707822d8c3d1150ac24bdc7c01f52))

# [1.2.0](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.1.0...v1.2.0) (2025-06-17)


### Features

* implement callback functionality ([#59](https://github.com/bulla-network/bulla-contracts-V2/issues/59)) ([ca6f995](https://github.com/bulla-network/bulla-contracts-V2/commit/ca6f995a4f198f74129f823f837684954c084709))

# [1.1.0](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.6...v1.1.0) (2025-06-16)


### Features

* frendlend - add offer expiry ([#58](https://github.com/bulla-network/bulla-contracts-V2/issues/58)) ([4c27e6a](https://github.com/bulla-network/bulla-contracts-V2/commit/4c27e6aa6adc5a5f444e067b2be919da204f8b91))

## [1.0.6](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.5...v1.0.6) (2025-06-13)


### Bug Fixes

* make package public for as understood by semantic-release ([f1bd9a3](https://github.com/bulla-network/bulla-contracts-V2/commit/f1bd9a30cf9c067e75717c9aa503fc673600e7fb))

## [1.0.5](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.4...v1.0.5) (2025-06-13)


### Bug Fixes

* make package public ([3f5979a](https://github.com/bulla-network/bulla-contracts-V2/commit/3f5979a890b2bf7fc01b8fc7466141bcf6b55bd5))

## [1.0.4](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.3...v1.0.4) (2025-06-13)


### Bug Fixes

* try new package name ([ffbbca5](https://github.com/bulla-network/bulla-contracts-V2/commit/ffbbca57e3a220e8e01d2ba371e5fede609dc8df))

## [1.0.3](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.2...v1.0.3) (2025-06-13)


### Bug Fixes

* add contributors to package ([a12b670](https://github.com/bulla-network/bulla-contracts-V2/commit/a12b670edb317bad0312e4ccf7b56c3f704327f2))
* package name ([ef14e7c](https://github.com/bulla-network/bulla-contracts-V2/commit/ef14e7cdaf47a97abdda9efd805f8a407e0fb3f2))

## [1.0.2](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.1...v1.0.2) (2025-06-13)


### Bug Fixes

* deploy new package ([1a721e6](https://github.com/bulla-network/bulla-contracts-V2/commit/1a721e64c18e9d5ad0474faefaa3c1b782917dc6))

## [1.0.1](https://github.com/bulla-network/bulla-contracts-V2/compare/v1.0.0...v1.0.1) (2025-06-13)


### Bug Fixes

* **CI:** use bot for CI ([b4fc819](https://github.com/bulla-network/bulla-contracts-V2/commit/b4fc819396c5d3bc26294806c9ad63aace52efdf))

# 1.0.0 (2025-06-13)


### Bug Fixes

* 0 amount claims ([3482aa8](https://github.com/bulla-network/bulla-contracts-V2/commit/3482aa8621bf1b59b74e13b4a8340c098786ce26))
* **CI:** remove redundant steps for testing + try using PT token for checkout ([94fab78](https://github.com/bulla-network/bulla-contracts-V2/commit/94fab78f71c6d83a60ee4b97106df6592c035cc6))
* **CI:** use 0.3.0 foundry ([a204c1a](https://github.com/bulla-network/bulla-contracts-V2/commit/a204c1a83e8e2740ca431e7f24b8883498e6fc94))
* **CI:** use PT token for semantic-release ([50bafd8](https://github.com/bulla-network/bulla-contracts-V2/commit/50bafd850250b54ea32403c4df6d5598236ea24c))
* hardhat tests ([bd9fd28](https://github.com/bulla-network/bulla-contracts-V2/commit/bd9fd283f3cd89a47d6be7829a582076cd39a3c3))
* remedy breaking change forge remapping update ([edfeb6a](https://github.com/bulla-network/bulla-contracts-V2/commit/edfeb6a356fe48b3806da5d8fb1a7ab4d9a9258b))
* update hardhat tests ([fe83092](https://github.com/bulla-network/bulla-contracts-V2/commit/fe830929b8d449f7643bcd6bde38e5cad5d802fe))


### Features

* :recycle: only creditor or debtor can create claim ([49cb2ab](https://github.com/bulla-network/bulla-contracts-V2/commit/49cb2abced062b0053c87d0645a7042df5f3c1dd))
* :sparkles: EIP1271 signatures ([2a7ef63](https://github.com/bulla-network/bulla-contracts-V2/commit/2a7ef637ad5f7ae3cae623da33120688a2b39ac3))
* :sparkles: init repo ([33203b2](https://github.com/bulla-network/bulla-contracts-V2/commit/33203b2a47221704e927749b85c5fb1d7cb1028a))
* ✍️ permitPayClaim EIP712 signatures ([404b1d4](https://github.com/bulla-network/bulla-contracts-V2/commit/404b1d401deacb3f36bf8105b32ec4389f90e6c7))
* 🖋️ implement *From and permit functions ([e7f46a2](https://github.com/bulla-network/bulla-contracts-V2/commit/e7f46a2ff3e4d5e9d4940ce14106f31eb3e750c2))
* add transferOnPayment flag ([e37ca3d](https://github.com/bulla-network/bulla-contracts-V2/commit/e37ca3d04af42d02cb9b2df5a92706e7425788de))
* add transferOnPayment flag ([05cd9fc](https://github.com/bulla-network/bulla-contracts-V2/commit/05cd9fc2d4af51626a1c39ddc09a932e980943a0))
* **approvals:** :sparkles: Implement createClaimApproval and permitCreateClaim ([b29732a](https://github.com/bulla-network/bulla-contracts-V2/commit/b29732a0fe88d2bdb7f29453608bcda7c4c9744e))
* **ci:** add Ci npm package deployment to repo ([57d7293](https://github.com/bulla-network/bulla-contracts-V2/commit/57d72931b9c0e764fdf31730a0c6bc853d57e6c1))
* IBullaClaim interface ([3304c8d](https://github.com/bulla-network/bulla-contracts-V2/commit/3304c8d331f3fb64c53ee4c933d4515cc8ba11eb))
* only paid claims can be burned ([104ec50](https://github.com/bulla-network/bulla-contracts-V2/commit/104ec501237162978d54e70f9873ce36533eda0b))
