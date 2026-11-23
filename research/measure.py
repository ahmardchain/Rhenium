"""Step 0: measure how many Reactive Lasna callbacks get no on-chain confirmation.

Sources (all public JSON-RPC, no explorer APIs):
  * Lasna system contract 0x8888...8888 emits CallbackRequest(uint256 indexed chainId,
    address indexed sender, address indexed recipient, uint8 version, bytes configuration)
    for every requested callback.
  * On each destination chain a single Reactive signer EOA submits every delivery as a
    transaction to the callback proxy (selector 0x8d1f0fa1). The change in that EOA's nonce
    over a window is therefore the number of delivery attempts (verified by block scan).
  * The proxy emits CallbackFailure(address indexed recipient, bytes payload) when the
    recipient call fails; the delivery tx itself still succeeds and is still billed.
  * The system contract exposes getCallbacks(uint256 reactiveTxHash), documented as the
    per-request delivery record. We sample it.

Usage: python3 measure.py [days]   -> writes data/measure_<utc>.json
"""
import json, os, random, subprocess, sys, time
from rpc import call
from batch import batch

SYSTEM = "0x8888888888888888888888888888888888888888"
CALLBACK_REQUEST = "0xef94dbc611c4b95bf4b8ba34b413972180c2faf26fbb480befacedd83e07b133"  # keccak CallbackRequest(uint256,address,address,uint8,bytes)
CALLBACK_FAILURE = "0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"  # keccak CallbackFailure(address,bytes)
SIGNER = "0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb"
DEST = {
    84532: dict(net="base_sepolia", proxy="0x476F44b11F5C942c58f4c8E3d0300E5710743585", span=200, bsize=20, pause=1.0),
    1301: dict(net="unichain_sepolia", proxy="0x775c9B990ADe401060B78D0e98684eEf8d2466C1", span=1000, bsize=20, pause=0.3),
    11155111: dict(net=None, proxy="0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4"),  # no reachable RPC from the build env
}
LAG_SECONDS = 2 * 3600  # end the window 2h ago so every request had time to be delivered


def ts(net, n):
    return int(call(net, "eth_getBlockByNumber", [hex(n), False])["timestamp"], 16)


def block_at(net, t):
    """Smallest block with timestamp >= t (binary search)."""
    hi = int(call(net, "eth_blockNumber", []), 16)
    bt = {"lasna": 1.0637, "base_sepolia": 0.2, "unichain_sepolia": 1.0}[net]
    lo = max(0, hi - int(1.05 * (ts(net, hi) - t) / bt) - 100)
    while ts(net, lo) > t:  # widen if the estimate overshot
        lo = max(0, lo - int(3600 / bt))
    while lo < hi:
        mid = (lo + hi) // 2
        if ts(net, mid) < t:
            lo = mid + 1
        else:
            hi = mid
    return lo


def logs_chunked(net, address, topic0, lo, hi, span, bsize, pause):
    reqs = []
    for a in range(lo, hi + 1, span):
        reqs.append(("eth_getLogs", [{"address": address, "topics": [topic0], "fromBlock": hex(a), "toBlock": hex(min(a + span - 1, hi))}]))
    out = []
    for r in batch(net, reqs, bsize, pause):
        out += r
    return out


def main():
    days = float(sys.argv[1]) if len(sys.argv) > 1 else 7
    now = int(time.time())
    t1 = now - LAG_SECONDS
    t0 = t1 - int(days * 86400)
    res = {"generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "window_utc": [
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t1))], "days": days}

    # --- Lasna side: every requested callback ---------------------------------
    l0, l1 = block_at("lasna", t0), block_at("lasna", t1) - 1
    res["lasna_blocks"] = [l0, l1]
    print("lasna blocks", l0, l1, file=sys.stderr)
    reqs = logs_chunked("lasna", SYSTEM, CALLBACK_REQUEST, l0, l1, 10000, 5, 0.3)
    requests = [{"chainId": int(l["topics"][1], 16), "sender": "0x" + l["topics"][2][-40:], "recipient": "0x" + l["topics"][3][-40:],
                 "gasLimit": int(l["data"][2 + 64 * 6: 2 + 64 * 7], 16) if len(l["data"]) > 2 + 64 * 7 else None,
                 "tx": l["transactionHash"], "block": int(l["blockNumber"], 16)} for l in reqs]
    res["requests_total"] = len(requests)
    by_chain = {}
    for r in requests:
        by_chain[r["chainId"]] = by_chain.get(r["chainId"], 0) + 1
    res["requests_by_chain"] = by_chain
    print("requests", len(requests), by_chain, file=sys.stderr)

    # --- Destination side ------------------------------------------------------
    res["dest"] = {}
    for cid, d in DEST.items():
        if d["net"] is None:
            res["dest"][cid] = {"requests": by_chain.get(cid, 0), "note": "destination RPC unreachable from build environment; not measured"}
            continue
        net = d["net"]
        b0, b1 = block_at(net, t0), block_at(net, t1) - 1
        n0 = int(call(net, "eth_getTransactionCount", [SIGNER, hex(b0)]), 16)
        n1 = int(call(net, "eth_getTransactionCount", [SIGNER, hex(b1 + 1)]), 16)
        fails = logs_chunked(net, d["proxy"], CALLBACK_FAILURE, b0, b1, d["span"], d["bsize"], d["pause"])
        fail_recips = {}
        for f in fails:
            a = "0x" + f["topics"][1][-40:]
            fail_recips[a] = fail_recips.get(a, 0) + 1
        req = by_chain.get(cid, 0)
        attempts = n1 - n0
        res["dest"][cid] = {"net": net, "blocks": [b0, b1], "requests": req, "delivery_attempts": attempts,
                            "callback_failures": len(fails), "never_attempted": max(req - attempts, 0),
                            "failure_recipients": dict(sorted(fail_recips.items(), key=lambda x: -x[1])),
                            "failure_txs": [f["transactionHash"] for f in fails]}
        print(cid, res["dest"][cid]["requests"], attempts, len(fails), file=sys.stderr)

    # --- getCallbacks() delivery-record sample -------------------------------
    sample = random.Random(1).sample(requests, min(40, len(requests)))
    nonempty = 0
    recs = []
    for r in sample:
        o = subprocess.run(["cast", "call", SYSTEM, "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])", r["tx"],
                            "--rpc-url", "https://lasna-rpc.rnk.dev/"], capture_output=True, text=True)
        out = o.stdout.strip()
        recs.append({"tx": r["tx"], "result": out or o.stderr.strip()[:200]})
        if out and out != "[]":
            nonempty += 1
    res["getCallbacks_sample"] = {"sampled": len(sample), "non_empty": nonempty, "records": recs}

    os.makedirs("data", exist_ok=True)
    path = f"data/measure_{time.strftime('%Y%m%dT%H%MZ', time.gmtime(now))}.json"
    json.dump({"summary": {k: v for k, v in res.items() if k != "requests"}, "requests": requests}, open(path, "w"), indent=1)
    # Headline
    m = [v for v in res["dest"].values() if "delivery_attempts" in v]
    R = sum(v["requests"] for v in m); A = sum(v["delivery_attempts"] for v in m); F = sum(v["callback_failures"] for v in m)
    print(json.dumps({k: v for k, v in res.items() if k not in ("dest",)} | {"dest": {c: {k: x for k, x in v.items() if k not in ("failure_txs",)} for c, v in res["dest"].items()}}, indent=1, default=str)[:6000])
    print(f"\nHEADLINE (Base+Unichain Sepolia): over {R} callbacks requested on Lasna in {days:g} days, "
          f"{max(R-A,0)} never produced a destination tx, {F} emitted CallbackFailure; "
          f"{max(R-A,0)+F} ({100*(max(R-A,0)+F)/max(R,1):.1f}%) did not land. -> {path}")


if __name__ == "__main__":
    main()
