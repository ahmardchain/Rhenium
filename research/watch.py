"""Print every event in the spike loop, in time order, with tx hashes.

Usage: python3 watch.py <since_unix_ts> [seconds_to_wait]
Watches: SpikeOrigin + SpikeCallback + proxy CallbackFailure(recipient=callback) on Base Sepolia,
         SpikeReactive events on Lasna (Requested / Confirmed / FailureSeen / TimedOut / GaveUp / Tick / Cron).
"""
import sys, time
from rpc import call

ENV = dict(l.strip().split("=", 1) for l in open("../deployments/spike.env") if "=" in l and not l.startswith("#"))
ORIGIN, REACTIVE, CB = ENV["SPIKE_ORIGIN"].lower(), ENV["SPIKE_REACTIVE"].lower(), ENV["SPIKE_CALLBACK"].lower()
PROXY = "0x476f44b11f5c942c58f4c8e3d0300e5710743585"
FAIL = "0xc8313f695443128e273f1edfcec40b94b7deea8dfbeafd0043290d6601d999db"

def k(s):
    import subprocess
    return subprocess.run([__import__("os").path.expanduser("~/.foundry/bin/cast"), "keccak", s], capture_output=True, text=True).stdout.strip()

NAMES = {k(s): s.split("(")[0] for s in [
    "Ping(uint256,uint256,uint256)", "Delivered(uint256,uint256,uint256)", "Requested(uint256,uint256,uint64)",
    "Confirmed(uint256,uint256,uint256)", "FailureSeen(uint256,uint256,uint256)", "TimedOut(uint256,uint256)",
    "GaveUp(uint256,uint256)", "Tick(uint256,uint256)", "Cron(bool)"]}
NAMES[FAIL] = "CallbackFailure"


def block_at(net, t, bt):
    hi = int(call(net, "eth_blockNumber", []), 16)
    th = int(call(net, "eth_getBlockByNumber", [hex(hi), False])["timestamp"], 16)
    return max(0, hi - int((th - t) / bt) - 5), hi


def logs(net, flt, lo, hi, span):
    out = []
    for a in range(lo, hi + 1, span):
        out += call(net, "eth_getLogs", [dict(flt, fromBlock=hex(a), toBlock=hex(min(a + span - 1, hi)))])
    return out


def main():
    since = int(sys.argv[1]); wait = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    time.sleep(wait)
    rows = []
    blo, bhi = block_at("base_sepolia", since, 0.2)
    for l in logs("base_sepolia", {"address": [ORIGIN, CB]}, blo, bhi, 200) + \
             logs("base_sepolia", {"address": PROXY, "topics": [FAIL, "0x" + "0" * 24 + CB[2:]]}, blo, bhi, 200):
        rows.append(("base", l))
    llo, lhi = block_at("lasna", since, 1.06)
    for l in logs("lasna", {"address": REACTIVE}, llo, lhi, 5000):
        rows.append(("lasna", l))
    ts_cache = {}
    def ts(net, bn):
        if (net, bn) not in ts_cache:
            ts_cache[(net, bn)] = int(call("base_sepolia" if net == "base" else "lasna", "eth_getBlockByNumber", [bn, False])["timestamp"], 16)
        return ts_cache[(net, bn)]
    out = []
    for net, l in rows:
        t = ts(net, l["blockNumber"])
        name = NAMES.get(l["topics"][0], l["topics"][0][:10])
        id_ = int(l["topics"][1], 16) if len(l["topics"]) > 1 and name not in ("CallbackFailure",) else ""
        words = [int(l["data"][2 + 64 * i: 2 + 64 * (i + 1)], 16) for i in range(min(3, (len(l["data"]) - 2) // 64))] if name != "CallbackFailure" else []
        out.append((t, int(l["blockNumber"], 16), net, name, id_, words, l["transactionHash"]))
    for r in sorted(out):
        print(time.strftime("%H:%M:%S", time.gmtime(r[0])), f"{r[2]:5} {r[1]:>9} {r[3]:16} id={r[4]} {r[5]} {r[6]}")


if __name__ == "__main__":
    main()
