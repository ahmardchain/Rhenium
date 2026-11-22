#!/usr/bin/env bash
# Naive vs Rhenium cross-chain payment demo (testnet only).
#   script/demo.sh deploy                 deploy + link everything, writes deployments/demo.env
#   script/demo.sh pay naive|rhenium GAS  Alice pays 25 mUSD to Bob on Unichain, starting with callback gas GAS
#   script/demo.sh balances               Bob's mUSD on Unichain, payer escrow on Base
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env; set +a
OUT=deployments/demo.env
[ -f "$OUT" ] && source "$OUT"

BASE_ID=84532; UNI_ID=1301
BASE_PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
UNI_PROXY=0x775c9B990ADe401060B78D0e98684eEf8d2466C1
CRON10=0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687
BOB=${BOB:-0x000000000000000000000000000000000000B0b0}   # payment recipient on Unichain (no key needed)

create() { # rpc contract [forge args...]  -> "address txhash"
  local rpc=$1 c=$2; shift 2
  forge create --broadcast --rpc-url "$rpc" --private-key "$PRIVATE_KEY" "$c" --json "$@" 2>/dev/null \
    | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t[t.rindex("{\n"):]); print(d["deployedTo"], d["transactionHash"])'
}
send() { # rpc to sig args...  -> txhash
  local rpc=$1; shift
  cast send --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json "$@" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="0x1", d; print(d["transactionHash"])'
}
save() { echo "$1=$2" >> "$OUT"; echo "$1=$2"; }

case "${1:-}" in
deploy)
  [ -f "$OUT" ] && { echo "$OUT exists; remove it to redeploy"; exit 1; }
  echo "# Rhenium demo deployment $(date -u +%FT%TZ)" > "$OUT"
  # (maxAttempts, gasStep, maxGasLimit, cooldownBlocks, timeoutBlocks, cronTopic, cronEnabled, alarmChainId, alarmRecipient, alarmGasLimit)
  CFG="(4,100000,600000,0,${TIMEOUT_BLOCKS:-20},$CRON10,true,0,0x0000000000000000000000000000000000000000,0)"
  read -r NAIVE_R T < <(create "$LASNA_RPC" src/demo/PaymentReactives.sol:NaivePaymentReactive --value "${NAIVE_FUND:-0.3ether}" --constructor-args $BASE_ID $UNI_ID)
  save NAIVE_REACTIVE "$NAIVE_R"; save NAIVE_REACTIVE_TX "$T"
  read -r RH_R T < <(create "$LASNA_RPC" src/demo/PaymentReactives.sol:RheniumPaymentReactive --value "${RH_FUND:-1.5ether}" --constructor-args $BASE_ID $UNI_ID "$CFG")
  save RHENIUM_REACTIVE "$RH_R"; save RHENIUM_REACTIVE_TX "$T"
  read -r USD_B T < <(create "$BASE_SEPOLIA_RPC" src/demo/MockUSD.sol:MockUSD); save BASE_MUSD "$USD_B"
  read -r NP T < <(create "$BASE_SEPOLIA_RPC" src/demo/Payer.sol:Payer --constructor-args "$USD_B" $BASE_PROXY "$NAIVE_R"); save NAIVE_PAYER "$NP"
  read -r RP T < <(create "$BASE_SEPOLIA_RPC" src/demo/Payer.sol:Payer --value "${PAYER_FUND:-0.002ether}" --constructor-args "$USD_B" $BASE_PROXY "$RH_R"); save RHENIUM_PAYER "$RP"
  read -r USD_U T < <(create "$UNICHAIN_SEPOLIA_RPC" src/demo/MockUSD.sol:MockUSD); save UNI_MUSD "$USD_U"
  read -r NE T < <(create "$UNICHAIN_SEPOLIA_RPC" src/demo/Payees.sol:NaivePayee --value "${PAYEE_FUND:-0.003ether}" --constructor-args "$USD_U" $UNI_PROXY "$NAIVE_R"); save NAIVE_PAYEE "$NE"
  read -r RE T < <(create "$UNICHAIN_SEPOLIA_RPC" src/demo/Payees.sol:RheniumPayee --value "${PAYEE_FUND:-0.003ether}" --constructor-args "$USD_U" $UNI_PROXY "$RH_R"); save RHENIUM_PAYEE "$RE"
  save NAIVE_LINK_TX "$(send "$LASNA_RPC" "$NAIVE_R" 'link(address,address)' "$NP" "$NE")"
  save RHENIUM_LINK_TX "$(send "$LASNA_RPC" "$RH_R" 'link(address,address,uint64)' "$RP" "$RE" 200000)"
  send "$UNICHAIN_SEPOLIA_RPC" "$USD_U" 'mint(address,uint256)' "$NE" 1000000000 >/dev/null
  send "$UNICHAIN_SEPOLIA_RPC" "$USD_U" 'mint(address,uint256)' "$RE" 1000000000 >/dev/null
  send "$BASE_SEPOLIA_RPC" "$USD_B" 'mint(address,uint256)' "$DEPLOYER" 1000000000 >/dev/null
  send "$BASE_SEPOLIA_RPC" "$USD_B" 'approve(address,uint256)' "$NP" 1000000000 >/dev/null
  send "$BASE_SEPOLIA_RPC" "$USD_B" 'approve(address,uint256)' "$RP" 1000000000 >/dev/null
  save BOB "$BOB"
  echo "deployed and linked"
  ;;
pay)
  P=$([ "$2" = naive ] && echo "$NAIVE_PAYER" || echo "$RHENIUM_PAYER")
  cast send --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" --json "$P" 'pay(address,uint256,uint64)' "$BOB" "${AMOUNT:-25000000}" "$3" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("pay tx", d["transactionHash"], "block", int(d["blockNumber"],16), "status", d["status"])'
  ;;
balances)
  echo "bob mUSD on Unichain:  $(cast call --rpc-url "$UNICHAIN_SEPOLIA_RPC" "$UNI_MUSD" 'balanceOf(address)(uint256)' "$BOB")"
  echo "naive payer escrow:    $(cast call --rpc-url "$BASE_SEPOLIA_RPC" "$BASE_MUSD" 'balanceOf(address)(uint256)' "$NAIVE_PAYER")"
  echo "rhenium payer escrow:  $(cast call --rpc-url "$BASE_SEPOLIA_RPC" "$BASE_MUSD" 'balanceOf(address)(uint256)' "$RHENIUM_PAYER")"
  echo "rhenium pending:       $(cast call --rpc-url "$LASNA_RPC" "$RHENIUM_REACTIVE" 'pendingCount()(uint256)') cron=$(cast call --rpc-url "$LASNA_RPC" "$RHENIUM_REACTIVE" 'cronSubscribed()(bool)')"
  echo "rhenium reactive REACT: $(cast balance --rpc-url "$LASNA_RPC" "$RHENIUM_REACTIVE" --ether)"
  ;;
*) echo "usage: $0 deploy | pay naive|rhenium GAS | balances"; exit 1;;
esac
