import json, time, urllib.request
from rpc import RPC
def batch(net, reqs, size=20, pause=1.0):
    out = []
    for i in range(0, len(reqs), size):
        chunk = reqs[i:i+size]
        body = json.dumps([{"jsonrpc":"2.0","id":j,"method":m,"params":p} for j,(m,p) in enumerate(chunk)]).encode()
        for attempt in range(6):
            try:
                r = json.load(urllib.request.urlopen(urllib.request.Request(RPC[net], body, {"content-type":"application/json","user-agent":"rhenium-research"}), timeout=90))
                r = sorted(r, key=lambda x: x["id"])
                if any("error" in x for x in r): raise RuntimeError([x["error"] for x in r if "error" in x][0])
                out += [x["result"] for x in r]; break
            except Exception as e:
                if attempt == 5: raise
                time.sleep(2 + attempt * 2)
        time.sleep(pause)
    return out
