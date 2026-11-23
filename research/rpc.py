"""Minimal JSON-RPC helper for the Step 0 measurement (stdlib only)."""
import json, time, urllib.request

RPC = {
    "lasna": "https://lasna-rpc.rnk.dev/",
    "base_sepolia": "https://sepolia.base.org",
    "unichain_sepolia": "https://sepolia.unichain.org",
    "eth_sepolia": "https://ethereum-sepolia-rpc.publicnode.com",
}

def call(net, method, params, retries=4):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for i in range(retries):
        try:
            req = urllib.request.Request(RPC.get(net, net), body, {"content-type": "application/json", "user-agent": "rhenium-research"})
            r = json.load(urllib.request.urlopen(req, timeout=60))
            if "error" in r:
                raise RuntimeError(r["error"])
            return r["result"]
        except Exception as e:
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))
