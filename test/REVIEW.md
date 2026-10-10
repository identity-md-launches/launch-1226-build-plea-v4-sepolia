# Independent test additions

The original 47 tests remain. Their deployment and signing helpers now live in
`fixtures/PleaFixture.sol`; their assertions are unchanged. Application contracts,
configuration, scripts and dependencies are unchanged.

| Suite | Additional checks |
| --- | --- |
| `CabalAdversarial.t.sol` | Signed panel inconsistencies, wrong chain, malformed bools, signature failure recovery, cold 200k callbacks, exact timeout/cooldown boundaries, retired callback isolation, payment rollback, intake ID collisions, absolute sell maximum, proportional basis, access control |
| `MarketAdversarial.t.sol` | Exact wrapped hook errors, insufficient gas even with paused credit, launch limit, malformed traders, callback/pool/liquidity authorization, partial-fill conservation, sponsored claims and invalid proofs, checkpoint wraparound, invalid amounts, repeated complete buy/sell round trips |
| `TextProperties.t.sol` | Complete control/Bidi_Control/tag ranges, BMP and supplementary selector ranges, malformed UTF-8, byte limits, exact JSON text round trips, decimal display preserving every wei |
| `DeploymentAndGas.t.sol` | Factory ownership and constructor order on an empty chain, mint timing and allocation, initcode binding, hook flags, single-sided seed, per-action gas limits including calldata, optional mainnet fork |
| `PleaInvariant.t.sol` | Four actors and 14 randomly selected actions, with 256 runs of 96 calls and failure on unexpected handler reverts |

The invariant handler mixes buys, oracle submissions and verdicts, appeals, executed
sells, expiry/completion, claims, time advancement, rebalancing, donations, forbidden
transfers, Cabal death and free sells. Inputs are bounded using existing balances and
economic/state preconditions; signature checks, token transfers and v4 settlement are
real. The handler never mints tokens or modifies application storage during a campaign.
Ghost ledgers track user PLEA, claims, paid oracle requests, donations, plain cashback,
keeper tips and observed burns. Assertions cover conservation of all three assets,
backing of retained cash, immediate fee payment, zero residual gate/Stacker balances,
zero v4 deltas/PLEA claims, monotonic supply/cap, and request lifecycle consistency.
A deterministic handler scenario verifies that each value-moving branch can execute.

All tests use constructor-built v4 PoolManager code. The fixture relocates its immutable
NoDelegateCall self address when installing it at the specified Sepolia address. No
`vm.getCode`, FFI, environment mutation, downloaded dependency or live oracle is needed
by the default suite. The fixed oracle signer uses the existing ERC-1271 test shim with
real ECDSA signatures; the separately retained protocol vector checks EIP-712 conformance.

## Gas and fork checks

`forge test` runs offline. The optional fork test skips unless `PLEA_MAINNET_RPC_URL` is
provided; its default fork block is 26,161,700 and can be overridden using
`PLEA_MAINNET_FORK_BLOCK`. It was run successfully against the contributor endpoint
`http://127.0.0.1:37745/rpc/1`.

The existing `script/check_estimated_gas.py` was also rerun against a disposable local
Anvil and a mainnet fork at block 26,161,700 using Osaka rules. It sends every action
using the unmodified `eth_estimateGas` result. Launch, hook deployment, seed, purchases,
paused-credit fallback, oracle submission/denial/approval, appeal, execution, expiry,
rebalance, claims and Cabal death all succeeded. Mainnet-fork receipts included:

| Action | Plain estimate | Receipt gas |
| --- | ---: | ---: |
| Atomic four-contract launch | 7,649,567 | 7,645,146 |
| deployHook | 4,688,911 | 4,686,802 |
| seed | 615,555 | 582,876 |
| First-credit buy | 2,948,734 | 1,857,597 |

Salt mining is performed separately from the measured application actions. A complete
Foundry test contains several actions and salt searches, so its aggregate gas is not
a transaction estimate. The dedicated action checks each enforce the 16.7M ceiling.

These fork checks install local fixtures at the immutable Sepolia dependency addresses.
They establish EVM/gas compatibility, not live Sepolia service readiness. The expensive
test vault models first-credit work rather than measuring the live vault.

## Reported defect

`PleaText.validate` accepts UTF-8 `e1a08f` (U+180F, Mongolian Free Variation Selector Four),
contrary to the required rejection of variation selectors. Its Unicode classification
is listed in the [Unicode 16.0 property table](https://www.unicode.org/Public/16.0.0/ucd/PropList.txt).
The root `.imd-findings.json` contains the concrete expected-versus-actual result and
the complete standalone Foundry proof. The proof was run under `test/scratch/` and failed
because the call did not revert. It is kept in the finding instead of being asserted as
acceptable behavior in the passing suite. No oracle verdict manipulation is claimed.
