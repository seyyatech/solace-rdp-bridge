#!/usr/bin/env bash
# Provisions the queue the bridge consumes from.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./semp-lib.sh
source "$SCRIPT_DIR/semp-lib.sh"

QUEUE="bridge-demo-queue"
DMQ="bridge-demo-dmq"

wait_for_semp

create "dead message queue $DMQ" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$DMQ\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "queue $QUEUE" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$QUEUE\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true,\"deadMsgQueue\":\"$DMQ\"}"

echo "Done. Publish to \"$QUEUE\" and watch: docker compose logs -f bridge mock-target"
