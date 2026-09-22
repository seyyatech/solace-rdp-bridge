#!/usr/bin/env bash
# Provisions everything this sample needs on the broker: a real RDP pointed at the mock target's
# always-failing `/` (the comparison point), and the two queues the bridge consumes from.
#
# The bridge always runs two routes (see ../../../bridge/README.md for why) - route 2 is
# configured identically to route 1 here since this sample is about resilience, not multi-target
# routing (see ../../multi-target-routing for that story). It still needs its own queue and dead
# message queue (DMQ) provisioned so the bridge can start.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./semp-lib.sh
source "$SCRIPT_DIR/semp-lib.sh"

RDP_QUEUE="rdp-demo-queue"
RDP="rdp-demo"
RDP_CONSUMER="rdp-demo-consumer"

BRIDGE_QUEUE="bridge-demo-queue"
BRIDGE_DMQ="bridge-demo-dmq"
BRIDGE_QUEUE2="bridge-demo-queue-2"
BRIDGE_DMQ2="bridge-demo-dmq-2"

wait_for_semp

# RDP side - broker-native, no code. postRequestTarget "/" hits the mock target's always-500
# resource.
create "queue $RDP_QUEUE" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$RDP_QUEUE\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "REST Delivery Point $RDP" \
  "msgVpns/$VPN/restDeliveryPoints" \
  "{\"restDeliveryPointName\":\"$RDP\",\"enabled\":true}"

create "REST consumer $RDP_CONSUMER" \
  "msgVpns/$VPN/restDeliveryPoints/$RDP/restConsumers" \
  "{\"restConsumerName\":\"$RDP_CONSUMER\",\"remoteHost\":\"mock-target\",\"remotePort\":8080,\"tlsEnabled\":false,\"enabled\":true,\"retryDelay\":5}"

create "queue binding $RDP_QUEUE -> $RDP" \
  "msgVpns/$VPN/restDeliveryPoints/$RDP/queueBindings" \
  "{\"queueBindingName\":\"$RDP_QUEUE\",\"postRequestTarget\":\"/\"}"

# Bridge side - route 1's queue + DMQ, and route 2's (mirrored, see note above).
create "dead message queue $BRIDGE_DMQ" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$BRIDGE_DMQ\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "queue $BRIDGE_QUEUE" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$BRIDGE_QUEUE\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true,\"deadMsgQueue\":\"$BRIDGE_DMQ\"}"

create "dead message queue $BRIDGE_DMQ2" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$BRIDGE_DMQ2\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true}"

create "queue $BRIDGE_QUEUE2" \
  "msgVpns/$VPN/queues" \
  "{\"queueName\":\"$BRIDGE_QUEUE2\",\"accessType\":\"non-exclusive\",\"permission\":\"consume\",\"ingressEnabled\":true,\"egressEnabled\":true,\"deadMsgQueue\":\"$BRIDGE_DMQ2\"}"

echo "Done. Publish to \"$RDP_QUEUE\" to see RDP hammer the mock target, or to \"$BRIDGE_QUEUE\""
echo "to see the bridge deliver through it - see this sample's README.md."
