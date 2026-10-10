# Independent test additions

The existing tests and the implementation contributor's revision regressions remain.
Their deployment and signing helpers live in `fixtures/PleaFixture.sol`. This revision
changes only tests and this review note; application contracts, configuration, scripts
and dependencies are unchanged.

| Suite | Additional checks |
| --- | --- |
| `CabalAdversarial.t.sol` | Signed panel inconsistencies, wrong chain, malformed bools, signature failure recovery, cold 200k callbacks, exact timeout/cooldown boundaries, retired callback isolation, payment rollback, intake ID collisions, absolute sell maximum, proportional basis, access control, U+180F submission/appeal rollback |
| `MarketAdversarial.t.sol` | Exact wrapped hook errors, insufficient gas even with paused credit, launch limit, malformed traders, callback/pool/liquidity authorization, partial-fill conservation, recipient-only claims and invalid proofs, checkpoint wraparound, invalid amounts, repeated complete buy/sell round trips, third-party buy rejection before and after Cabal death |
| `TextProperties.t.sol` | Complete control/Bidi_Control/tag ranges, BMP and supplementary selector ranges, malformed UTF-8, byte limits, exact JSON text round trips, decimal display preserving every wei |
| `DeploymentAndGas.t.sol` | Factory ownership and constructor order on an empty chain, mint timing and allocation, initcode binding, hook flags, single-sided seed, per-action gas limits including calldata, optional mainnet fork |
| `PleaInvariant.t.sol` | Four actors and 14 randomly selected actions, with 256 runs of 96 calls and failure on unexpected handler reverts |

The invariant handler mixes buys, oracle submissions and verdicts, appeals, executed
sells, expiry/completion, claims, time advancement, rebalancing, donations, forbidden
transfers, Cabal death and free sells. Inputs are bounded using existing balances and
economic/state preconditions; signature checks, token transfers and v4 settlement are
real. The handler never mints tokens or modifies application storage during a campaign.
Ghost ledgers track user PLEA, claims, paid oracle requests, denial/execution cooldowns,
donations, plain cashback, keeper tips and observed burns. Assertions cover conservation of all three assets,
backing of retained cash, immediate fee payment, zero residual gate/Stacker balances,
zero v4 deltas/PLEA claims, monotonic supply/cap, and request lifecycle consistency.
Deterministic handler scenarios verify that each value-moving branch can execute and
that unanswered appeals preserve denial cooldowns. The handler authenticates successful
claims as their recipients and separately rejects sponsored claims without changing the
holding ledger. It rejects appeal chains, refreshes checkpoints before score-based input
selection, checks that newly placed buy walls have no conversions, and measures the
dead-man delay from the later of seeding and the most recent verdict. The existing unit
regressions independently exercise stale checkpoints and delayed seeding.

All tests use constructor-built v4 PoolManager code. The fixture relocates its immutable
NoDelegateCall self address when installing it at the specified Sepolia address. No
`vm.getCode`, FFI, environment mutation, downloaded dependency or live oracle is needed
by the default suite. The fixed oracle signer uses the existing ERC-1271 test shim with
real ECDSA signatures; the separately retained protocol vector checks EIP-712 conformance.

## Gas and fork checks

Revision verification: `forge build` passed; `forge test` passed 98 tests with zero
failures and one optional fork skip. The invariant campaign completed 256 sequences
of 96 calls (24,576 calls) with zero unexpected reverts. Both deterministic handler
scenarios and the new gate-level Unicode rollback regression passed.

`forge test` runs offline. The optional fork test skips unless `PLEA_MAINNET_RPC_URL` is
provided; its default fork block is 26,161,700 and can be overridden using
`PLEA_MAINNET_FORK_BLOCK`. It was also run separately and passed at mainnet block
26,161,989 using the publicnode endpoint.

For this revision, the existing `script/check_estimated_gas.py` was rerun against a
disposable local Anvil and a mainnet fork at block 26,161,989 using Osaka rules. It sends every action
using the unmodified `eth_estimateGas` result. Launch, hook deployment, seed, purchases,
paused-credit fallback, oracle submission/denial/approval, appeal, execution, expiry,
rebalance, claims and Cabal death all succeeded. Mainnet-fork receipts included:

| Action | Plain estimate | Receipt gas |
| --- | ---: | ---: |
| Atomic four-contract launch | 7,745,120 | 7,740,698 |
| deployHook | 4,734,694 | 4,732,585 |
| seed | 615,555 | 582,876 |
| First-credit buy | 2,948,807 | 1,857,616 |

All 22 application actions passed on both chains with their exact estimates. Artifacts
and logs were placed under `test/scratch/`; the Python check was imported with only its
artifact lookup redirected there. Its transaction sequence and assertions were unchanged.

Salt mining is performed separately from the measured application actions. A complete
Foundry test contains several actions and salt searches, so its aggregate gas is not
a transaction estimate. The dedicated action checks each enforce the 16.7M ceiling.

These fork checks install local fixtures at the immutable Sepolia dependency addresses.
They establish EVM/gas compatibility, not live Sepolia service readiness. The expensive
test vault models first-credit work rather than measuring the live vault.

## Resolved Unicode defect

The preceding review reported that `PleaText.validate` accepted UTF-8 `e1a08f` (U+180F).
The implementation now rejects it. `TextProperties.t.sol` covers the full Mongolian
selector range alongside the BMP and supplementary ranges. `CabalAdversarial.t.sol`
also submits U+180F through both gate entry points: neither an invalid submission nor
an invalid appeal may charge tokens, consume an appeal, or create an oracle request.
A subsequent valid appeal still succeeds. The old unresolved-finding note is retired.
