# Shared helpers for this sample's init script, talking to the SEMP config API. Source, don't run:
#   source "$(dirname "${BASH_SOURCE[0]}")/semp-lib.sh"
SEMP_BASE="http://localhost:8080/SEMP/v2/config"
SEMP_AUTH="admin:admin"
VPN="default"

# create <label> <path relative to $SEMP_BASE> <JSON body>
# Idempotent: an existing object (SEMP status ALREADY_EXISTS) is left as-is rather than erroring
# out. Retries through the broker's transient "message spool not available yet" window on cold
# start.
create() {
  local label="$1" path="$2" body="$3"
  local attempt response code error_status

  for attempt in $(seq 1 20); do
    response=$(curl -sS -w '\n%{http_code}' -X POST -u "$SEMP_AUTH" \
      -H 'content-type: application/json' \
      "$SEMP_BASE/$path" -d "$body")
    code=$(tail -n1 <<<"$response")
    response=$(sed '$d' <<<"$response")

    if [[ "$code" == "200" ]]; then
      echo "created: $label"
      return
    fi

    error_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("meta",{}).get("error",{}).get("status",""))' <<<"$response" 2>/dev/null || true)
    if [[ "$error_status" == "ALREADY_EXISTS" ]]; then
      echo "already exists, skipping: $label"
      return
    elif [[ "$error_status" == "MESSAGE_SPOOL_DATA_NOT_AVAILABLE" ]]; then
      # Broker's message spool can still be initializing for a bit after SEMP itself answers.
      sleep 3
      continue
    else
      echo "failed to create $label (http $code): $response" >&2
      exit 1
    fi
  done

  echo "gave up creating $label: message spool never became available" >&2
  exit 1
}

wait_for_semp() {
  echo "Waiting for SEMP to be reachable at $SEMP_BASE ..."
  until curl -sS -o /dev/null -u "$SEMP_AUTH" "$SEMP_BASE/msgVpns/$VPN"; do
    sleep 2
  done
}
