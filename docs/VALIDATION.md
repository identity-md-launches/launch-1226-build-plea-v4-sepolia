# Validation record

Checked locally with Foundry 1.8.3 and pinned solc 0.8.26. All dependencies are vendored source files.

- `forge build --force`: passed with exit status 0. A clean 115-file build completed in 50.7 seconds with a measured peak resident set of 1,072,996 KiB. The existing default profile still sets one compiler worker. The reported exit-137 failure did not recur.
- `forge test`: 58 tests passed, including 128 runs each of the conservation and UTF-8/JSON fuzz tests.
- `forge test -j 4`: all 58 tests passed in parallel.
- `forge fmt --check`: passed.
- `python3 script/check_estimated_gas.py`: all transactions succeeded with their unmodified `eth_estimateGas` limits on an empty local chain.
- `python3 script/check_estimated_gas.py --fork-url https://ethereum-rpc.publicnode.com`: all transactions succeeded with unmodified estimates on a mainnet fork at block 26161937, using Osaka rules. No transaction was broadcast to mainnet or Sepolia.

## Revision regressions

All four supplied proof files were copied unchanged into `test/scratch/` and run on the starting code: all six proof cases failed as reported. Four additional advisory regressions also failed on the starting implementation: recursive appeals were accepted, third-party claims changed the holding clock, an unfilled wall reported one wei of conversion, and U+180F was accepted. After the targeted fixes, the combined suite passed all 64 cases (58 retained tests plus six supplied proof cases). The scratch proof copies were then removed, and the clean build and 58-test suite were run again.

The retained regressions cover delayed seeding and the exact 33-hour deadline; denial cooldown preservation through completed, timed-out and late-callback appeals; checkpoint refresh before submission; caller-authenticated buy and claim ledgers; one appeal per original plea; unfilled and genuinely converted buy walls, including the opposite currency order; and Mongolian selector rejection with adjacent visible characters accepted. Existing tests for legitimate trades, first appeals, callbacks within 200k gas, plain cashback fallback and conservation remain passing. Finding-by-finding responses are in [`.imd-responses.json`](../.imd-responses.json).

The previous arbitrary-payer finding remains addressed: the gate collects from `msg.sender` before unlocking, and PoolManager callbacks settle only the gate's own funds. No transferFrom of a callback-supplied payer was introduced. Source changes are confined to the reported gate, hook, distribution and text/rounding behavior; immutable dependencies and constructor interfaces are unchanged.

## Mainnet-fork transaction gas

The table includes transaction intrinsic/data gas. The action ceiling is 16,700,000 gas. Receipt gas can be much lower than its estimate because the cashback guard reserves enough gas to forward the full Stacker stipend. Mining a salt is an off-chain call and is excluded from deployment transactions.

| Action | Plain estimate | Receipt gas used |
| --- | ---: | ---: |
| atomic four-contract launch | 7,745,120 | 7,740,698 |
| deployHook | 4,734,694 | 4,732,585 |
| seed | 615,555 | 582,876 |
| allow | 45,487 | 45,487 |
| approve IMD | 46,269 | 46,269 |
| approve oracle asset | 46,269 | 46,269 |
| approve PLEA | 46,274 | 46,274 |
| buy first credit | 2,948,807 | 1,857,616 |
| buy subsequent credit | 2,738,884 | 451,668 |
| buy credit revert fallback | 2,738,922 | 405,708 |
| submitSell | 2,079,157 | 2,039,357 |
| clearNoVerdict | 33,843 | 29,043 |
| submitSell retry | 993,565 | 948,965 |
| oracle deny | 253,152 | 113,731 |
| appeal | 1,309,054 | 1,249,354 |
| oracle approve | 253,176 | 91,049 |
| executeSell | 2,737,277 | 494,527 |
| rebalance | 286,260 | 251,485 |
| setMerkleRoot | 45,004 | 45,004 |
| claim | 118,120 | 117,849 |
| killCabal | 46,172 | 46,172 |
| sellFreely | 3,310,161 | 987,594 |

Full records, fixture notes and creation-bytecode hashes: [empty chain](empty-chain-gas.json), [mainnet fork](mainnet-gas.json).

## Runtime sizes

| Contract | Bytes |
| --- | ---: |
| PLEA | 4,423 |
| CabalGate | 21,098 |
| PleaDistributor | 5,364 |
| PleaLaunch | 1,736 |
| PleaHook | 20,766 |

Every application also passed the deployment-floor-style scan for forbidden DELEGATECALL, CALLCODE and SELFDESTRUCT opcodes, skipping PUSH data. Bytecode has no external library link references.

## Meaning and limits

The 1,295,994-gas first-credit measurement uses the verified Stacker implementation and a test vault with 45 deliberate first-credit cold storage writes. This models the stated approximately 1.2M-gas Sepolia requirement and is below the fixed 2M credit budget. It is not a measurement of the live Sepolia vault. Only an actual reverted credit produces plain TestIMD. Both that fallback and successful stacking were exercised using exact estimates.

The fork test installs deterministic external-service fixtures, so it establishes gas and EVM compatibility, not live service readiness. Verify the immutable dependencies on Sepolia before seeding. The oracle conformance suite separately accepts the protocol-published digest and signature, while callback tests exercise the real gate under a 200k stipend. The RPC state/gas test uses a permissive test-only ERC1271 signer; no such signer is part of the application.

Test repairs included reproducing the atomic constructor transaction, relocating only PoolManager's NoDelegateCall immutable in the fixed-address harness, matching Intake's full-stipend gas guard, and removing a redundant cap pass from rebalance. The cap runs on swaps as in POOL4; rebalance only moves the backstop. This removed extra clock-sensitive work from keeper gas estimation.

No Slither/Mythril run or independent security audit is claimed. Manual review covered caller authorization, absence of arbitrary payer pulls inside callbacks, prepayment and delta conservation, callback replay/deadlines, cap decay rounding, buy-wall work measurement, immutable dependencies, and permanent liquidity custody. The owner allowlist, oracle pairing/signing, well-formed distribution tree, ordinary 18-decimal assets, and cross-block price observations remain explicit trust assumptions in the README.
