"""Print every event of the payment demo across Base Sepolia, Lasna and Unichain Sepolia, ordered by time.

Usage: python3 demo_watch.py <since_unix_ts> [--json out.json]
Covers: PaymentRequested / PaymentRefunded (Base Payers), PayoutRequested / PayoutTracked / Receipt* / Cron* (Lasna),
        Paid / Delivered (Unichain Payees), CallbackFailure (Unichain proxy, per payee), plus every Reactive signer
        delivery tx to the Unichain proxy for our payees, including reverted ones (which emit nothing).
"""
import json, sys, time
from rpc import call
from batch import batch

ENV = dict(l.strip().split("=", 1) for l in open("../deployments/demo.env") if "=" in l and not l.startswith("#"))
E = {k: v.lower() for k, v in ENV.items()}
UNI_PROXY = "0x775c9b990ade401060b78d0e98684eef8d2466c1"
SIGNER = "0xf7e866d726658f6c3f14b8ee537fe268a4d91ddb"
FAIL = "0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"


def keccak(sig):
    import subprocess, os
    return subprocess.run([os.path.expanduser("~/.foundry/bin/cast"), "keccak", sig], capture_output=True, text=True).stdout.strip()


SIGS = ["PaymentRequested(uint256,address,uint256,uint64,address)", "PaymentRefunded(uint256,address,uint256,uint256)",
        "PayoutRequested(uint256,address,uint256,uint64)", "PayoutTracked(uint256,uint256,address,uint256)",
        "ReceiptSent(uint256,uint256,address,uint256,uint64)", "ReceiptConfirmed(uint256,uint256,uint256)",
        "ReceiptFailureSeen(uint256,uint256,uint256)", "ReceiptTimedOut(uint256,uint256)", "ReceiptGaveUp(uint256,uint256)",
        "AlarmSent(uint256,uint256,address)", "CronSubscribed(uint256)", "CronUnsubscribed(uint256)",
        "Paid(uint256,address,uint256,uint256)", "Paid(uint256,address,uint256)", "Delivered(uint256,uint256)",
        "AlarmReceived(uint256,uint256,address)", "Transfer(address,address,uint256)", "Approval(address,address,uint256)"]
NAMES = {keccak(s): s.split("(")[0] for s in SIGS}
NAMES[FAIL] = "CallbackFailure"
# Keyed by (chain, address): the same deployer nonce gives the same address on different chains.
WHO = {("base", E["NAIVE_PAYER"]): "naive", ("base", E["RHENIUM_PAYER"]): "rhenium",
       ("lasna", E["NAIVE_REACTIVE"]): "naive", ("lasna", E["RHENIUM_REACTIVE"]): "rhenium",
       ("uni", E["NAIVE_PAYEE"]): "naive", ("uni", E["RHENIUM_PAYEE"]): "rhenium"}


def recipient_of(inp):
    """Recipient inside a proxy delivery tx: 0x8d1f0fa1 + (version, offset, len, 0x20, chainId, recipient, ...)."""
    return "0x" + inp[10 + 64 * 5 + 24: 10 + 64 * 6].lower()
BT = {"base_sepolia": 0.2, "lasna": 1.06, "unichain_sepolia": 1.0}


def rng(net, since):
    hi = int(call(net, "eth_blockNumber", []), 16)
    th = int(call(net, "eth_getBlockByNumber", [hex(hi), False])["timestamp"], 16)
    return max(0, hi - int((th - since) / BT[net]) - 5), hi


def logs(net, flt, lo, hi, span):
    out = []
    for a in range(lo, hi + 1, span):
        out += call(net, "eth_getLogs", [dict(flt, fromBlock=hex(a), toBlock=hex(min(a + span - 1, hi)))])
    return out


def collect(since):
    rows = []
    b0, b1 = rng("base_sepolia", since)
    for l in logs("base_sepolia", {"address": [E["NAIVE_PAYER"], E["RHENIUM_PAYER"]]}, b0, b1, 200):
        rows.append(("base", l))
    l0, l1 = rng("lasna", since)
    for l in logs("lasna", {"address": [E["NAIVE_REACTIVE"], E["RHENIUM_REACTIVE"]]}, l0, l1, 5000):
        rows.append(("lasna", l))
    u0, u1 = rng("unichain_sepolia", since)
    payees = [E["NAIVE_PAYEE"], E["RHENIUM_PAYEE"]]
    for l in logs("unichain_sepolia", {"address": payees}, u0, u1, 1000):
        rows.append(("uni", l))
    for p in payees:
        for l in logs("unichain_sepolia", {"address": UNI_PROXY, "topics": [FAIL, "0x" + "0" * 24 + p[2:]]}, u0, u1, 1000):
            l["_payee"] = p
            rows.append(("uni", l))
    # delivery txs (including reverted ones, which leave no log)
    blks = batch("unichain_sepolia", [("eth_getBlockByNumber", [hex(n), True]) for n in range(u0, u1 + 1)], 100, 0.2)
    dtx = [(b, t) for b in blks for t in b["transactions"]
           if t["from"].lower() == SIGNER and (t.get("to") or "").lower() == UNI_PROXY and recipient_of(t["input"]) in payees]
    rcpts = batch("unichain_sepolia", [("eth_getTransactionReceipt", [t["hash"]]) for _, t in dtx], 50, 0.2) if dtx else []
    tsc = {}

    def ts(net, bn):
        key = (net, bn)
        if key not in tsc:
            n = {"base": "base_sepolia", "lasna": "lasna", "uni": "unichain_sepolia"}[net]
            tsc[key] = int(call(n, "eth_getBlockByNumber", [bn, False])["timestamp"], 16)
        return tsc[key]

    ev = []
    for net, l in rows:
        name = NAMES.get(l["topics"][0], l["topics"][0][:10])
        if name in ("Transfer", "Approval"):
            continue
        who = WHO.get((net, l.get("_payee") or l["address"].lower()), "?")
        t1 = int(l["topics"][1], 16) if len(l["topics"]) > 1 and name != "CallbackFailure" else None
        ev.append({"ts": ts(net, l["blockNumber"]), "chain": net, "block": int(l["blockNumber"], 16), "flow": who,
                   "event": name, "id": t1, "data": l["data"], "tx": l["transactionHash"]})
    for (b, t), r in zip(dtx, rcpts):
        who = WHO[("uni", recipient_of(t["input"]))]
        st = "ok" if r["status"] == "0x1" else "REVERTED (no event)"
        ev.append({"ts": int(b["timestamp"], 16), "chain": "uni", "block": int(b["number"], 16), "flow": who,
                   "event": f"delivery tx gas={int(t['gas'], 16)} used={int(r['gasUsed'], 16)} {st}", "id": None, "data": "", "tx": t["hash"]})
    return sorted(ev, key=lambda e: (e["ts"], e["chain"] != "base", e["block"]))


def main():
    since = int(sys.argv[1])
    ev = collect(since)
    for e in ev:
        print(time.strftime("%H:%M:%S", time.gmtime(e["ts"])), f"{e['chain']:5} {e['flow']:7} {e['event']:44} id={e['id']} {e['tx']}")
    if "--json" in sys.argv:
        json.dump(ev, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
