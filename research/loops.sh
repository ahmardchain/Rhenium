#!/usr/bin/env bash
# Run N Rhenium payments back to back (each starting at GAS), waiting for each receipt to clear.
set -euo pipefail
cd "$(dirname "$0")/.."
source deployments/demo.env
N=${1:-5}; GAS=${2:-100000}; L=https://lasna-rpc.rnk.dev/
export PATH=$HOME/.foundry/bin:$PATH
START=$(date +%s); echo "$START" > research/data/loops.since
for i in $(seq 1 "$N"); do
  before=$(cast call $RHENIUM_REACTIVE 'nextReceiptId()(uint256)' --rpc-url $L)
  script/demo.sh pay rhenium "$GAS"
  n=0
  until [ "$(cast call $RHENIUM_REACTIVE 'nextReceiptId()(uint256)' --rpc-url $L)" -gt "$before" ] && \
        [ "$(cast call $RHENIUM_REACTIVE 'pendingCount()(uint256)' --rpc-url $L)" = "0" ] || [ $n -ge 60 ]; do sleep 5; n=$((n+1)); done
  echo "loop $i cleared after ~$((n*5))s"
  sleep 15   # let cron unsubscribe fully before the next one
done
