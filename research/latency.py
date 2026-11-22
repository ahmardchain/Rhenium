"""Latency of the Rhenium payment loop, from the events demo_watch.py collects.

Usage: python3 latency.py events.json [more.json ...]  -> prints a table and the medians, writes data/latency.json

Per receipt:
  request    Base   PaymentRequested(paymentId)            origin event
  detect     Lasna  first ReceiptTimedOut / ReceiptFailureSeen
  delivered  Uni    Delivered(receiptId)                   payee paid, acknowledgement emitted
  confirmed  Lasna  ReceiptConfirmed(receiptId)            reactive contract knows it landed
Block timestamps are per chain; Lasna's clock was observed 1-3 s ahead of Base/Unichain, so cross-chain deltas carry
that skew. request -> delivered is Base vs Unichain only (both OP-stack L2s, no Lasna clock involved).
"""
import json, statistics, sys


def main():
    ev = []
    for p in sys.argv[1:]:
        ev += json.load(open(p))
    seen = set()
    ev = [e for e in ev if not (e["tx"], e["event"], e["id"]) in seen and not seen.add((e["tx"], e["event"], e["id"]))]
    rh = [e for e in ev if e["flow"] == "rhenium"]
    pay2rec = {}
    # PayoutTracked(paymentId, receiptId) and the first ReceiptSent(receiptId) are emitted in the same Lasna tx.
    tracked = sorted([e for e in rh if e["event"] == "PayoutTracked"], key=lambda e: e["ts"])
    sent0 = sorted([e for e in rh if e["event"] == "ReceiptSent" and e["tx"] in {t["tx"] for t in tracked}], key=lambda e: e["ts"])
    for t, s in zip(tracked, sent0):
        pay2rec[t["id"]] = s["id"]
    req = {e["id"]: e["ts"] for e in rh if e["event"] == "PaymentRequested" and e["chain"] == "base"}
    rows = []
    for pid, rid in sorted(pay2rec.items()):
        def first(name, chain):
            xs = [e["ts"] for e in rh if e["event"] == name and e["id"] == rid and e["chain"] == chain]
            return min(xs) if xs else None
        det = [e["ts"] for e in rh if e["event"] in ("ReceiptTimedOut", "ReceiptFailureSeen") and e["id"] == rid]
        sent = sorted(e["ts"] for e in rh if e["event"] == "ReceiptSent" and e["id"] == rid)
        sends = len(sent)
        r = {"paymentId": pid, "receiptId": rid, "attempts": sends, "request": req.get(pid), "detect": min(det) if det else None,
             "delivered": first("Delivered", "uni"), "confirmed": first("ReceiptConfirmed", "lasna"),
             "last_sent": sent[-1] if sent else None}
        for a, b, k in [("request", "delivered", "request_to_delivered"), ("detect", "delivered", "detect_to_delivered"),
                        ("delivered", "confirmed", "delivered_to_confirmed"), ("request", "detect", "request_to_detect"),
                        # single-clock (Lasna only): no cross-chain skew
                        ("detect", "confirmed", "detect_to_confirmed_lasna"), ("last_sent", "confirmed", "roundtrip_lasna")]:
            r[k] = r[b] - r[a] if r[a] is not None and r[b] is not None else None
        rows.append(r)
    print(f"{'pay':>3} {'rcpt':>4} {'att':>3} {'req->detect':>11} {'detect->deliv':>13} {'req->deliv':>10} {'detect->conf(L)':>15} {'roundtrip(L)':>12}")
    for r in rows:
        f = lambda v: "-" if v is None else f"{v:d}s"
        print(f"{r['paymentId']:>3} {r['receiptId']:>4} {r['attempts']:>3} {f(r['request_to_detect']):>11} {f(r['detect_to_delivered']):>13} {f(r['request_to_delivered']):>10} {f(r['detect_to_confirmed_lasna']):>15} {f(r['roundtrip_lasna']):>12}")
    med = {}
    for k in ["request_to_detect", "detect_to_delivered", "request_to_delivered", "detect_to_confirmed_lasna", "roundtrip_lasna"]:
        xs = [r[k] for r in rows if r[k] is not None]
        med[k] = statistics.median(xs) if xs else None
    print("median", json.dumps(med), "over", len(rows), "loops")
    json.dump({"rows": rows, "median": med}, open("data/latency.json", "w"), indent=1)


if __name__ == "__main__":
    main()
