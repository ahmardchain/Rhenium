# Demo video script (target 2:45, hard limit 3:00)

Record at 1080p. Two windows: the dashboard (browser) and a terminal in the repo. Have `script/demo.sh balances`
ready. Before recording, check the Rhenium reactive contract has at least 0.3 REACT (`script/demo.sh balances`).

| Time | Show | Say (about 150 words a minute) |
|---|---|---|
| 0:00–0:20 | README top: the number | "Over the last week on Reactive Lasna, 10,252 callbacks were sent to Base and Unichain Sepolia. 289 failed on the destination and were still billed; 31 never arrived at all. And not one of the 10,252 told the contract that sent it whether it landed. Reactive callbacks are fire-and-forget: no acknowledgement, no retry." |
| 0:20–0:35 | Diagram in README | "Rhenium is the missing layer. Inherit RheniumReactive, call `_sendTracked` instead of `requestCallback`, and every callback gets a receipt that stays pending until the destination says Delivered. Failures are retried with more gas. Nothing disappears." |
| 0:35–1:05 | Terminal: `script/demo.sh pay naive 100000` and `script/demo.sh pay rhenium 100000` | "Here is the same cross-chain payment twice: Alice pays 25 mUSD on Base, Bob should get it on Unichain. Both start with a callback gas limit that is too low, the most common mistake in the docs' own debugging guide. The left one is written the usual way. The right one uses Rhenium." |
| 1:05–1:40 | Dashboard: the new receipt appears Pending, attempt 0 → "No event at all", then TimedOut, attempt 1 → CallbackFailure, attempt 2 → Delivered, Confirmed; cron chip flips on then off | "Attempt zero reverts inside the callback proxy. No event, anywhere: a contract that listens for CallbackFailure would wait forever. Rhenium's cron timeout catches it and retries with more gas. That attempt reaches the payout but runs out of gas: CallbackFailure, seen on Lasna two seconds later, retried again. Third attempt: Delivered. Bob is paid, the receipt is confirmed, and cron switches itself off so it stops costing REACT." |
| 1:40–1:55 | Naive table on the dashboard + `script/demo.sh balances` | "The naive payment? Status unknown, forever. Bob was never paid from it, Alice's money sits in escrow, and no contract on any chain knows." |
| 1:55–2:15 | README latency table | "Over six live loops: failure detected to delivered in five seconds; payment to paid in 32, most of which is the timeout for the silent case, which is configurable. A CallbackFailure is handled in about two." |
| 2:15–2:35 | Code: `src/examples/Minimal.sol` | "Using it is ten lines. Inherit RheniumReactive and call `_sendTracked`; inherit RheniumCallback and implement `_onDelivery`. Rhenium adds exactly-once delivery, so a retry can never pay Bob twice, and a give-up alarm: if every attempt fails, the payer is refunded." |
| 2:35–2:50 | README: feedback table, then `forge test` passing | "41 Foundry tests, everything on-chain on Lasna, Base Sepolia and Unichain Sepolia, and feedback for the Reactive team in the README. Rhenium: every callback, confirmed." |

Notes
* If the live retry takes longer than expected, cut from the first `ReceiptSent` straight to the confirmed receipt and
  say so ("about 30 seconds later").
* Don't claim latencies you did not see on screen; the README numbers are from `research/data/latency.json`.
