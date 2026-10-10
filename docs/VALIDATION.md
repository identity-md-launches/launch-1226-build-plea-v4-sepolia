# Validation record

Checked locally with Foundry 1.8.5 and pinned solc 0.8.26. All dependencies are vendored source files.

- `forge build --force -j 1`: passed. A clean 115-file build completed in 43.9 seconds with a measured peak resident set of 1,143,116 KiB. The default profile sets one compiler worker to avoid concurrent memory peaks.
- `forge test`: 47 tests passed, including 128 runs each of the conservation and UTF-8/JSON fuzz tests.
- `forge test -j 4`: all 47 tests passed in parallel.
- `forge fmt --check`: passed.
- `python3 script/check_estimated_gas.py`: all transactions succeeded with their unmodified `eth_estimateGas` limits on an empty local chain.
- `python3 script/check_estimated_gas.py --fork-url https://mainnet.gateway.tenderly.co`: all transactions succeeded with unmodified estimates on a mainnet fork at block 26161618, using Osaka rules. No transaction was broadcast to mainnet or Sepolia.

## Mainnet-fork transaction gas

The table includes transaction intrinsic/data gas. The action ceiling is 16,700,000 gas. Receipt gas can be much lower than its estimate because the cashback guard reserves enough gas to forward the full Stacker stipend. Mining a salt is an off-chain call and is excluded from deployment transactions.

| Action | Plain estimate | Receipt gas used |
| --- | ---: | ---: |
| atomic four-contract launch | 7,649,567 | 7,645,146 |
| deployHook | 4,688,911 | 4,686,802 |
| seed | 615,555 | 582,876 |
| allow | 45,487 | 45,487 |
| approve IMD | 46,269 | 46,269 |
| approve oracle asset | 46,269 | 46,269 |
| approve PLEA | 46,274 | 46,274 |
| buy first credit | 2,948,734 | 1,857,597 |
| buy subsequent credit | 2,738,811 | 451,652 |
| buy credit revert fallback | 2,738,849 | 405,693 |
| submitSell | 2,066,977 | 2,027,177 |
| clearNoVerdict | 36,248 | 31,448 |
| submitSell retry | 984,185 | 939,585 |
| oracle deny | 253,152 | 113,731 |
| appeal | 1,297,524 | 1,237,824 |
| oracle approve | 253,176 | 88,249 |
| executeSell | 2,737,398 | 494,556 |
| rebalance | 286,260 | 251,485 |
| setMerkleRoot | 45,004 | 45,004 |
| claim | 118,096 | 117,825 |
| killCabal | 37,613 | 37,613 |
| sellFreely | 3,310,156 | 987,640 |

Full records, fixture notes and creation-bytecode hashes: [empty chain](empty-chain-gas.json), [mainnet fork](mainnet-gas.json).

## Runtime sizes

| Contract | Bytes |
| --- | ---: |
| PLEA | 4,423 |
| CabalGate | 20,696 |
| PleaDistributor | 5,342 |
| PleaLaunch | 1,736 |
| PleaHook | 20,555 |

Every application also passed the deployment-floor-style scan for forbidden DELEGATECALL, CALLCODE and SELFDESTRUCT opcodes, skipping PUSH data. Bytecode has no external library link references.

## Meaning and limits

The 1,295,994-gas first-credit measurement uses the verified Stacker implementation and a test vault with 45 deliberate first-credit cold storage writes. This models the stated approximately 1.2M-gas Sepolia requirement and is below the fixed 2M credit budget. It is not a measurement of the live Sepolia vault. Only an actual reverted credit produces plain TestIMD. Both that fallback and successful stacking were exercised using exact estimates.

The fork test installs deterministic external-service fixtures, so it establishes gas and EVM compatibility, not live service readiness. Verify the immutable dependencies on Sepolia before seeding. The oracle conformance suite separately accepts the protocol-published digest and signature, while callback tests exercise the real gate under a 200k stipend. The RPC state/gas test uses a permissive test-only ERC1271 signer; no such signer is part of the application.

Test repairs included reproducing the atomic constructor transaction, relocating only PoolManager's NoDelegateCall immutable in the fixed-address harness, matching Intake's full-stipend gas guard, and removing a redundant cap pass from rebalance. The cap runs on swaps as in POOL4; rebalance only moves the backstop. This removed extra clock-sensitive work from keeper gas estimation.

No Slither/Mythril run or independent security audit is claimed. Manual review covered caller authorization, absence of arbitrary payer pulls inside callbacks, prepayment and delta conservation, callback replay/deadlines, cap decay rounding, buy-wall work measurement, immutable dependencies, and permanent liquidity custody. The owner allowlist, oracle pairing/signing, well-formed distribution tree, ordinary 18-decimal assets, and cross-block price observations remain explicit trust assumptions in the README.
