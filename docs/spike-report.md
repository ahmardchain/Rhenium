# Step 1 spike report (2026-11-22)

All transactions below are live: Reactive Lasna (chain 5318007) and Base Sepolia (chain 84532).
Contracts: `src/spike/`. Watcher: `research/watch.py`. Deploy/ping helper: `script/spike.sh`.

| Contract | Chain | Address |
|---|---|---|
| SpikeOrigin | Base Sepolia | `0x59Df6195853ee36514baDf5C43F599e4Ba4DC3CE` |
| SpikeReactive | Lasna | `0xEd1BA791f8842e3f88913cf1f52855927F04C42a` |
| SpikeCallback | Base Sepolia | `0x6Df4d0d5983d79e4f5489f6f1406CEE8Cfa7EeFb` |

`setCallback` (deployment-order link, subscribes Delivered + CallbackFailure): Lasna `0x27acb2305237fe565812db590c4a976bb0a2921cf9daf606caead36ebf81e6df`.

`rnk_getFilters` after linking shows three active filters for the reactive contract: `Ping` on SpikeOrigin,
`Delivered` on SpikeCallback, and `CallbackFailure` on the Base proxy with `topic1 = SpikeCallback`.
(Live response keys are `Version` / `TopicFilters`, capitalised, unlike the docs page.)

## S1: loop (PASS)

`ping(gasLimit=1,000,000, work=5)`

| Step | Chain | Tx |
|---|---|---|
| Origin `Ping(1)` | Base | `0x83374e687b4966bec37393f20b079cdb7007a6f82e0273d8c3a423ff9b267009` |
| Reactive tx: `Requested(1, attempt 0, 1,000,000)` + cron on | Lasna | `0x0dd228328d55997290eeea113f84eb718cb31b1fa7e7b77bc4251497ea865685` |
| Callback: `Delivered(1)` | Base | `0x3e05cd78cb091459ab38198ab58afe02d805eaacfa9b56b6ab1c64e0a87fbebb` |
| Reactive tx: `Confirmed(1)` (react() saw Delivered) | Lasna | `0x366afed709606d1ebeb9ce9485fb9e0754c687709f49d48584f03673fdfddddd` |
| Next Cron10 tick: pending = 0 -> unsubscribe | Lasna | `0xd35f19b5894b21590c0d2d41ca3307d436e7babc8ac067970be7b8bc884e2c3f` |

Ping block -> Delivered block on Base: 5 blocks (~1 s).

## S2 + S3: failure detection and retry (PASS, with an important finding)

`ping(gasLimit=100,000, work=20)`: the callback needs ~540k gas, so the first attempts must fail.

| Attempt | Gas limit | Destination tx (Base) | Outcome on destination | How Rhenium saw it | Reactive tx (Lasna) |
|---|---|---|---|---|---|
| 0 | 100,000 | `0x8ab982bab1e858ec9d5c819ea871c105ad5c213ce6b51cc1f9138a412b9ed420` | **tx reverted (status 0), no event at all** | **cron timeout** (120 blocks) | `0x585c7fb8c773eea47c4d89cd2a4f95d958c17cf9fe97fbfd09d169bc4337a95c` (`TimedOut` + retry) |
| 1 | 300,000 | `0x4ded2a012d3745e836e98542a923da2959fba7de8ddd6bf5f397da14013f7919` | `CallbackFailure`, billed | subscription | `0xfbc8fdd9a4a5ddf4a158003fda2d6c2ad4d2c69ad9538ef4016de5c3e7e04224` (`FailureSeen` + retry) |
| 2 | 500,000 | `0x539b7237ee3d9c386114c3d4f39ee9f61af384d3ab4cde244d8a08db7590df83` | `CallbackFailure`, billed | subscription | `0xbed56d44c0b29cd3109ca8f8f963bf60560bbea36030eb8884267b50bd4b0452` (`FailureSeen` + retry) |
| 3 | 700,000 | `0x3e81436298e35695ad19bdce6983a2a62bfff36e75a84ba33c17ef9fa8bf1499` | `Delivered(2)` | subscription | `0xb86422f22296243c9dce4e836f55abe8532e5cbfab65207134582d63555d37d6` (`Confirmed`) |

Origin `Ping(2)`: Base `0x5fa399a571ca4fa90a2a48f802512fc8ce367190ff3981a4a13b5cbc8ab7b855`.
Cron off after confirmation: Lasna `0x7f691cebaec1859f6e9e9316f822b24b59b48abed2433756adbb4fccddbbffd6`.

**Finding.** A gas limit too low for the proxy's own overhead does not produce `CallbackFailure`: the delivery
transaction itself reverts and leaves no log anywhere. A reactive contract subscribed only to `CallbackFailure`
would wait forever. Rhenium therefore needs both detectors: the `CallbackFailure` subscription (fast, ~2 s) for
callbacks that reach the method and revert, and a cron timeout for deliveries that revert inside the proxy.

Latency, first CallbackFailure (Base block 62033706) -> Delivered (Base block 62033727): 21 blocks = 4.2 s, across two retries.

## Gas accounting (S3)

Callback contract balance on Base (ETH, wei), read at historical blocks:

| After | Balance | Charge |
|---|---|---|
| attempt 0 (reverted in proxy) | 4,998,554,256,800,000 | 0 (not billed) |
| attempt 1 (CallbackFailure) | 4,997,174,889,800,000 | 1,379,367,000,000 |
| attempt 2 (CallbackFailure) | 4,994,496,147,800,000 | 2,678,742,000,000 |
| attempt 3 (Delivered) | 4,990,847,456,600,000 | 3,648,691,200,000 |

Failed callbacks that reach the method are billed; deliveries that revert inside the proxy are not. Debt stayed 0.

## S4: cron (PASS)

* Cron10 subscribed from `react()` when the first receipt became pending (`Cron(true)` in the Requested tx).
* Ticks reached `react()` every 10 blocks and drove the timeout that rescued attempt 0.
* Unsubscribed from `react()` on the first tick with nothing pending (`Cron(false)`), and resubscribed on the next Ping.
* **Cost:** reactive balance fell ~0.021-0.026 REACT per Cron10 tick (balance read at blocks 8953311 / 8953320 / 8953331),
  i.e. ~7-9 REACT per hour while anything is pending. Gas-only estimate is ~0.009 REACT per tick; the rest is the network fee.
  Conclusion: the library defaults to Cron100 and only keeps cron on while receipts are pending.

## Not done / caveats

* Base Sepolia only for the spike; Unichain Sepolia funded for the demo.
* The revert reason of attempt 0 was not decoded (most likely `InsufficientGas`).
* An unused second `SpikeOrigin` was deployed by a re-run of the deploy script: `0xfa23E6063cA72f60ee55234eC8A068Ea0f1803E5`.
