#!/usr/bin/env bash
# Provisions the two queues the bridge consumes from. The bridge always runs two routes (see
# ../../../bridge/README.md for why) - route 2 is configured identically to route 1 here since
# this sample is about payload transformation, not multi-target routing (see
# ../../multi-target-routing for that story).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./semp-lib.sh
source "$SCRIPT_DIR/semp-lib.sh"

QUEUE="bridge-demo-queue"
DMQ="bridge-demo-dmq"
QUEUE2="bridge-demo-queue-2"
DMQ2="bridge-demo-dmq-2"

wait_for_semp

create "dead message queue $DMQ" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$DMQ\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "queue $QUEUE" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$QUEUE\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true,\"deadMsgQueue\":\"$DMQ\"}"

create "dead message queue $DMQ2" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$DMQ2\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "queue $QUEUE2" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$QUEUE2\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true,\"deadMsgQueue\":\"$DMQ2\"}"

echo "Done. Publish to \"$QUEUE\" and watch: docker compose logs -f bridge mock-target"
