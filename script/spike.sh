#!/usr/bin/env bash
# Step 1 spike deployment (testnet only). Usage: script/spike.sh deploy | ping <gasLimit> <work> | status
# Reads PRIVATE_KEY / RPCs from .env. Writes addresses to deployments/spike.env.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
mkdir -p deployments
OUT=deployments/spike.env
[ -f "$OUT" ] && source "$OUT"

BASE_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
BASE_ID=84532

create() { # rpc contract args...
  local rpc=$1 c=$2; shift 2
  forge create --broadcast --rpc-url "$rpc" --private-key "$PRIVATE_KEY" "$c" "$@" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["deployedTo"], d["transactionHash"])'
}

case "${1:-}" in
deploy)
  read -r ORIGIN TX1 < <(create "$BASE_SEPOLIA_RPC" src/spike/SpikeOrigin.sol:SpikeOrigin)
  echo "SPIKE_ORIGIN=$ORIGIN  # base sepolia, tx $TX1"
  read -r REACTIVE TX2 < <(create "$LASNA_RPC" src/spike/SpikeReactive.sol:SpikeReactive --value "${REACTIVE_FUND:-2ether}" \
      --constructor-args $BASE_ID "$ORIGIN" $BASE_ID $BASE_PROXY)
  echo "SPIKE_REACTIVE=$REACTIVE  # lasna, tx $TX2"
  read -r CB TX3 < <(create "$BASE_SEPOLIA_RPC" src/spike/SpikeCallback.sol:SpikeCallback --value "${CALLBACK_FUND:-0.01ether}" \
      --constructor-args $BASE_PROXY "$REACTIVE")
  echo "SPIKE_CALLBACK=$CB  # base sepolia, tx $TX3"
  TX4=$(cast send --rpc-url "$LASNA_RPC" --private-key "$PRIVATE_KEY" "$REACTIVE" "setCallback(address)" "$CB" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["transactionHash"])')
  echo "setCallback tx $TX4"
  printf "SPIKE_ORIGIN=%s\nSPIKE_REACTIVE=%s\nSPIKE_CALLBACK=%s\n# txs: origin %s reactive %s callback %s setCallback %s\n" \
    "$ORIGIN" "$REACTIVE" "$CB" "$TX1" "$TX2" "$TX3" "$TX4" > "$OUT"
  ;;
ping)
  cast send --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" "$SPIKE_ORIGIN" "ping(uint256,uint256)" "$2" "$3" --json \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ping tx",d["transactionHash"],"block",int(d["blockNumber"],16))'
  ;;
status)
  for f in cronOn pending ticks; do echo "$f $(cast call --rpc-url "$LASNA_RPC" "$SPIKE_REACTIVE" "$f()(uint256)" 2>/dev/null || cast call --rpc-url "$LASNA_RPC" "$SPIKE_REACTIVE" "$f()(bool)")"; done
  echo "reactive debt $(cast call --rpc-url "$LASNA_RPC" 0x8888888888888888888888888888888888888888 "debt(address)(uint256)" "$SPIKE_REACTIVE")"
  echo "reactive balance $(cast balance --rpc-url "$LASNA_RPC" "$SPIKE_REACTIVE" --ether)"
  echo "callback debt $(cast call --rpc-url "$BASE_SEPOLIA_RPC" $BASE_PROXY "debt(address)(uint256)" "$SPIKE_CALLBACK")"
  echo "callback balance $(cast balance --rpc-url "$BASE_SEPOLIA_RPC" "$SPIKE_CALLBACK" --ether)"
  ;;
*) echo "usage: $0 deploy | ping <gasLimit> <work> | status"; exit 1;;
esac
