"""Step 0 supplement: count callback deliveries that reverted inside the proxy (status 0, no CallbackFailure).

The spike showed these exist (gas limit below proxy overhead) and are invisible to CallbackFailure subscribers.
Scans every block in the window for txs from the Reactive signer to the callback proxy, then fetches receipts.

Usage: python3 reverted.py <net> <hours>   e.g. python3 reverted.py unichain_sepolia 24
"""
import json, os, sys, time
from rpc import call
from batch import batch

SIGNER = "0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb"
PROXY = {"base_sepolia": "0x476f44b11f5c942c58f4c8e3d0300e5710743585",
         "unichain_sepolia": "0x775c9b990ade401060b78d0e98684eef8d2466c1"}
FAIL = "0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"
BT = {"base_sepolia": 0.2, "unichain_sepolia": 1.0}
CFG = {"base_sepolia": (20, 1.0), "unichain_sepolia": (100, 0.2)}  # (batch size, pause)


def main():
    net, hours = sys.argv[1], float(sys.argv[2])
    end = int(call(net, "eth_blockNumber", []), 16) - 600
    start = end - int(hours * 3600 / BT[net])
    size, pause = CFG[net]
    txs = []
    for a in range(start, end + 1, 2000):
        blks = batch(net, [("eth_getBlockByNumber", [hex(n), True]) for n in range(a, min(a + 2000, end + 1))], size, pause)
        for b in blks:
            for t in b["transactions"]:
                if t["from"].lower() == SIGNER and (t.get("to") or "").lower() == PROXY[net]:
                    txs.append((int(b["number"], 16), int(b["timestamp"], 16), t["hash"], int(t["gas"], 16)))
        print(f"{a - start}/{end - start} blocks, {len(txs)} deliveries", file=sys.stderr)
    receipts = batch(net, [("eth_getTransactionReceipt", [h]) for _, _, h, _ in txs], size, pause)
    rows, reverted, failure, ok = [], 0, 0, 0
    for (bn, ts, h, gas), r in zip(txs, receipts):
        st = int(r["status"], 16)
        has_fail = any(l["topics"] and l["topics"][0] == FAIL for l in r["logs"])
        kind = "reverted" if st == 0 else ("callback_failure" if has_fail else "ok")
        reverted += kind == "reverted"; failure += kind == "callback_failure"; ok += kind == "ok"
        rows.append({"block": bn, "ts": ts, "tx": h, "gasLimit": gas, "gasUsed": int(r["gasUsed"], 16), "kind": kind})
    out = {"net": net, "hours": hours, "blocks": [start, end],
           "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(rows[0]["ts"])) if rows else None,
                          time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(rows[-1]["ts"])) if rows else None],
           "deliveries": len(rows), "ok": ok, "callback_failure": failure, "reverted_no_event": reverted, "rows": rows}
    os.makedirs("data", exist_ok=True)
    path = f"data/reverted_{net}_{int(hours)}h_{time.strftime('%Y%m%dT%H%MZ', time.gmtime())}.json"
    json.dump(out, open(path, "w"), indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "rows"}), "->", path)


if __name__ == "__main__":
    main()
