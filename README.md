# PLEA v4 — Sepolia

PLEA is a fixed-supply ERC-20 with token-level sell restrictions, an immutable Uniswap v4 market, and an Intake-only oracle consumer. Solidity 0.8.26, Cancun, via IR, optimizer 200 runs, no bytecode metadata hash. All Solidity dependencies are ordinary vendored files; the build and default tests need no network. No website, manifest, private key, or broadcasting script is included.

```sh
forge build
forge test
forge fmt --check
python3 script/check_estimated_gas.py
# Optional read-only mainnet fork; transactions stay on a disposable local Anvil:
python3 script/check_estimated_gas.py --fork-url https://mainnet.gateway.tenderly.co
```

`script/check_estimated_gas.py` sends each transaction with precisely the result of plain `eth_estimateGas`, without padding. It asserts successful receipts, the 16,700,000 gas ceiling, actual sIMD issuance, and the absence of PLEA claims. It requires only Python's standard library, Anvil, Cast, and built artifacts. Its test tokens, Intake, vault, and oracle signer are fixtures, not proposed deployments.

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Chain | Sepolia, 11155111 |
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Pool asset: TestIMD | `0x2B69099E59b05901faA1DD164fabf098bf831E82` |
| Stacker | `0x293C7134Ab8f6Bf1D8fF44Ed806575f8F1bAF477` |
| Intake | `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56` |
| Intake fee asset | `0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A` |
| Oracle signer | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |
| Latest permissionless opening, START | `1791775740` |
| Supply | 1,000,000,000 PLEA, 18 decimals |
| Oracle fee / appeal liquidity fee | 0.5 fee-asset / 0.35 TestIMD |

Addresses have no setters. The signer is immutable. The two assets are deliberately different. The supplied addresses and main task take precedence over the generic oracle reference's configurable-address guidance.

Deploy these four constructors **in this order, in one transaction**, substituting the requester's actual owner and earlier contract addresses:

1. `PLEA(owner)`
2. `CabalGate(PLEA)`
3. `PleaDistributor(PLEA, owner)`
4. `PleaLaunch(PLEA, CabalGate, PleaDistributor, 1791775740)`

The factory is never the owner. Constructors call only previously deployed applications, never fixed external services. PLEA's constructor sets an EIP-1153 flag; PleaLaunch consumes it through `setLauncher(address(this))`. Deploying these in separate transactions intentionally fails. The Foundry profile uses `isolate = false` to reproduce this transaction in the constructor rehearsal. The RPC test proves the same behavior with a real atomic factory transaction.

PleaLaunch commits to `keccak256(bytes.concat(type(PleaHook).creationCode, abi.encode(token, gate, owner)))` in its constructor. Its runtime does not embed the hook creation code. PleaHook is **not** a manifest contract. The separate manifest step should list only the four contracts above; this repository deliberately contains no `launch.json`.

## After launch

- Anyone obtains the exact hook initcode using `MineSalt.initcode(token, gate, owner)`, checks it against `PleaLaunch.hookInitcodeHash()`, and mines a salt off chain. `script/MineSalt.s.sol` exposes `run(launcher, hash, start, attempts)`, returning `(found, salt, hook, nextNonce)`. Resume a bounded search at `nextNonce` when `found` is false. All 14 low address bits must equal `0x2acc`; partial matches are rejected.
- Anyone calls `PleaLaunch.deployHook(salt, initcode)` once. It deploys with CREATE2, records the hook, and calls `PLEA.init(hook)`. Only then are 900,000,000 PLEA minted to the hook and 100,000,000 to the distributor.
- The owner may call `PleaLaunch.seed()` at any time after hook deployment. Everyone else must wait until START. Initialization and liquidity changes originate only from the hook. Seeding uses only PLEA, LP fee zero, tick spacing 60, and exactly the square-root price corresponding to a 5,700 TestIMD fully diluted market cap, subject only to integer square-root precision. The PLEA-only range begins at the next outward tick boundary; the first buy crosses the small empty gap to that range. Any inversion dust is burned. The launch window begins at **seed time**, even if seed occurs before START.
- The owner chooses the distribution, computes a sorted-pair Merkle tree whose leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`, and calls `PleaDistributor.setMerkleRoot(root)` once. Use at most the allocated 100,000,000 PLEA in total. One claim per account, at most 64 proof nodes; no root replacement, rescue, or withdrawal. Anyone can submit a proof, but funds always go to the leaf's account. Receipts start a zero-cost holding clock.
- The owner may call `PLEA.allow(account)` to add trusted senders. This is permanent and cannot be revoked. Allowlisting is a substantial trust power: those senders may transfer freely to other wallets/venues, but still cannot send to PoolManager directly. Avoid allowlisting exchange infrastructure if unrestricted secondary markets are unwanted.
- The oracle operator must maintain the fixed Intake/action/asset price and signer and deliver the canonical callback. The liquidity keeper may call `rebalance()` and `checkpoint()` without privileges. No party can withdraw protocol liquidity, alter fees, replace dependencies, upgrade contracts, pause the token, or change the oracle signer.

## Trading and accounting

While the Cabal lives, every transfer and `transferFrom` must originate from PoolManager, Hook, Gate, Distributor, or an allowlisted sender; alternatively, Gate itself may pull tokens to Gate. Transfers to PoolManager additionally require Hook or Gate as the source. ERC-20 approval does not relax these restrictions. After `killCabal`, transfers become ordinary ERC-20 transfers, including to other venues.

`CabalGate.buy(amountIn, minPleaOut, sqrtPriceLimitX96)` pulls TestIMD **from its caller** before unlocking. The gate settles its own balance before swapping. Compatible external routers must likewise prepay their input and supply exactly `abi.encode(trader)` as 32-byte hook data. Zero, Gate, Hook, and PoolManager cannot be the trader. Exact-output swaps are rejected. In particular, conventional routers that settle only after swapping need adaptation for this market.

For a buy, `beforeSwap` performs one priced, exact-input self-swap with the fee-adjusted budget. v4 skips recursive hook calls for a self-swap. The returned specified delta cancels the outer core swap. `afterSwap` uses the actual priced fill, refunds any unused input directly to the trader, and takes the PLEA directly to the trader, less burn. The router has **zero PLEA output delta**, preventing conversion of the output to transferable ERC-6909 claims. There are no claim balances, fee IOUs, settlement helpers, cashback claims, or prefunded cashback floats.

Normal fees on a buy's actual gross TestIMD expenditure are 0.5% cashback, 0.5% owner, 0.25% liquidity, with 0.25% of gross PLEA output burned. During the first 90 minutes, an additional 70%→0% linear TestIMD fee goes to liquidity, and gross PLEA output cannot exceed 5,000,000 per buy. For buys the net core budget is `floor(input * (10000 - 125 - launchBps) / 10000)`; gross charged input is rounded up from actual core input. The tiny fee-rounding remainder belongs to liquidity. User slippage is checked on delivered PLEA.

For a sell, 0.25% of PLEA input is burned, one ordinary core swap executes, and 0.5%/0.5%/0.25% of gross TestIMD output goes to cashback/owner/liquidity. All fee transfers use `take()` during that swap. Partial sells revert atomically. `executeSell(minOut)` derives a conservative marginal price limit from the approved amount, burn, IMD fees, and `minOut`; it also requires full fill and net aggregate output at least `minOut`. `minOut = 0` disables price protection by choosing the v4 extreme. No arbitrary caller-controlled `transferFrom` occurs in any PoolManager callback.

Cashback is taken to the hook and approved to Stacker for exactly that credit. Immediately before the try-call, the hook requires at least `CREDIT_GAS + RESERVE = 2,200,000` gas remaining, then forwards a fixed 2,000,000 gas. Only a reverted credit causes plain TestIMD payment. The approval is cleared on either path. No gas-dependent success path skips staking, and no per-block flag skips fees. The vault fixture deliberately performs 45 cold storage writes on a first credit, making the full Stacker path cost approximately 1.2M gas. The verified Stacker implementation emits `Stacked(project = hook, trader, ...)`.

Every fee is transferred in the swap. The liquidity portion becomes actual TestIMD in the permanently locked hook treasury, awaiting permissionless placement in a single-sided buy wall. This retained liquidity capital is distinct from user debts; nobody has a withdrawal claim on it. Extra launch and appeal fees are never keeper-tip eligible.

## Cap and buy wall

The cap/trim, rate-limited ratchet, previous-block reference, and slowly recovering placement bound derive from the verified POOL4 `CappedBurnHook` at `0xc6c965bd164c483e87d0b550671798e9a3602840`. The original source and provenance are preserved in `docs/`. This adaptation sorts PLEA/TestIMD in either order, removes owner escape hatches, replaces deferred claims with immediate token settlement, and burns trims fully.

The initial cap is actual PLEA principal deposited. Buys may ratchet it down at no more than 300,000 PLEA/day, carrying fractional clock debt, with a 900,000 PLEA floor. Sells that exceed the cap cause a proportional, price-neutral removal: PLEA burns and recovered TestIMD joins the locked treasury. No reward allocation is carved from trimmed PLEA.

`rebalance()` removes an existing wall, burns PLEA that it bought, and redeploys recovered and retained TestIMD. A signed/oriented tick handles both currency orders. The bid moves to cheaper PLEA immediately after an adverse observation; recovery toward more expensive PLEA is limited to 400 ticks/day, using a previous-block reference limited to 200 ticks/block. Idle recovery time is capped at one day. A spot manipulation cannot instantly move the wall to a more expensive level.

Keeper rewards require at least 100 TestIMD of **newly deployed idle capital plus converted wall principal**, with at most one payout per hour. The reward is the minimum of 1 TestIMD, 0.25% of measured work, unspent normal liquidity-fee provenance, and available retained capital. Repeatedly recycling an unfilled wall is not new work. Sub-threshold work can execute without a tip; at an extreme tick, undeployable funds stay locked. The position and treasury remain permanently protocol-owned, even after the Cabal dies.

## Pleas and verdicts

`submitSell(amount, text)` requires a 1–280-byte valid UTF-8 plea, no controls, zero-width or directional formatting, tags, variation selectors, or `[PLEA` / `[/PLEA` prefixes. JSON quotes and backslashes are escaped. One open plea per wallet; amount is nonzero and at most both 2,500,000 PLEA and 35% of its current balance. Executed sells impose four hours of cooldown.

Facts are calculated at submission and fixed for that plea:

| Fact | Points |
| --- | --- |
| Share sold ≤15% / ≤25% / ≤35% | 18 / 11 / 5 |
| Weighted average hold ≥7 / ≥3 / ≥1 days | 14 / 9 / 5 |
| Loss / gain ≤50% / gain ≤200% / larger | 14 / 9 / 5 / 0 |
| Latest checkpoint versus 24h ago: >+2% / within ±2% / below −2% | 9 / 5 / 0 |

Cost basis includes actual gross buy expenditure including fees; sales remove basis proportionally. Buy time is weighted by delivered PLEA and existing holdings, not expenditure. Airdrops have zero basis and start their hold on receipt; zero basis earns no P/L points. Owner-authorized transfers are trusted administrative exceptions, not an alternate trade ledger.

The 25-slot hourly checkpoint ring records only a completed prior block's closing observation; snapshots within an hour cannot be overwritten. Missing idle hours are filled with the last eligible observation, bounded to 25 writes. Before 24 hours of history exist, the trend is neutral. Facts read the latest stored checkpoints and **never** pool spot. This is a lagged snapshot policy, not a TWAP; sustained cross-block manipulation remains a market risk. A keeper should maintain hourly checkpoints during quiet periods.

The oracle must supply at least `70 - factScore` of 45 plea points. If that requirement exceeds 45, `CannotPass` reverts before collecting a fee. The body uses the exact supplied Cabal question and definitions, `chainId: 1`, `window: {hours: 1}`, bool/panel/30/17/3600, `allowAmbiguous: true`, and the Sepolia gate as consumer. The distributor also hosts the pure JSON renderer to keep each deployment comfortably below EIP-170.

The callback selector is `0x510379c7`. Only Intake may call it for a known pending intake ID. EIP-712 uses “IdentityMD Oracle”, version “2”, Sepolia, and the gate itself. The canonical 15-field attestation includes `figure` and `agreed`. The question's chain is 1; bool answers, panel ≥30, quorum ≥17, agreed ≥17 and ≥quorum, valid time, correct signature, and a previously unconsumed oracle UUID are required. The intake ID and oracle UUID are different identifiers. `questionHash` is not recomputed because the oracle resolves the relative window. The fixed Intake is trusted to pair a signed result with the correct request.

Approval opens seven minutes for execution. Denial imposes four hours of waiting; an appeal is available during those four hours, once per denied plea and for no more than its original amount. The appeal pays another oracle fee plus 0.35 TestIMD to liquidity; its question includes the original text and DENIED. An appeal itself is a new plea and may receive its own single appeal if denied. Both approval and denial reset `lastVerdictAt`.

An Intake request marked completed without an accepted callback, or a request aged 20 minutes, can be cleared with `clearNoVerdict()` or automatically on another submission. Fees are spent, not refunded. Late callbacks for retired requests are ignored; a timeout observed during callback also retires the request. A no-verdict appeal clears the inherited denial wait. Approved but unexecuted requests expire after seven minutes and can be replaced. Invalid callbacks revert and do not reset the dead-man clock.

After 33 hours without a verdict, anyone can call `killCabal()`. The initial clock starts at gate deployment. Token restrictions then end permanently; the hook remains locked and continues its market/fees. `sellFreely(amount, minOut)` provides the prepaid route without a plea. There is no relayer/public signature submission path and no oracle administration function.

## Verification and operational limits

The default suite exercises constructor-transaction scope, launch authorization, initcode and salt mismatches, allocation, distribution, two token orders, real v4 swaps, slippage and actual-fill fees, cap and wall accounting, claims/routers/Permit2-style pull attacks, every oracle transition, invalid Unicode, published protocol signature vectors, gas and runtime limits, and fuzzed round-trip conservation. `test/fixtures/Stacker.sol` is the verified source. PoolManager is constructed with `new PoolManager`; its immutable self-address is relocated only in the harness when its runtime is installed at the fixed address. Tests never use `vm.getCode`, environment variables, FFI, external RPC, or filesystem cheatcodes.

The fork gas test still installs external-service fixtures: it verifies mainnet EVM transaction accounting, not production oracle availability. Before submitting the real launch, the deployment operator must verify the supplied Sepolia services have code, the two tokens have 18 decimals and ordinary ERC-20 accounting, the Stacker uses the intended vault, the Intake charges the fixed fee and forwards the callback, and first-credit gas remains below the fixed budget. Addresses cannot be repaired after deployment. The owner must publish the distribution tree and retain its proofs. The oracle operator, not this project, funds and schedules verdict deliveries.

Testing is not an independent security audit. An independent adversarial review and deployment simulation are operational responsibilities before funded use. This repository performs no live transactions.
