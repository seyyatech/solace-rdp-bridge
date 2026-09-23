# The problem, and what this bridge does about it

## What a REST Delivery Point is

A Solace **REST Delivery Point (RDP)** binds one or more queues to one or more outbound HTTP
targets. It's a broker-native feature, no code, no separate process to run. Configure it via
the broker's management API or UI, and the broker itself starts POSTing (or PUTting) queued
messages to the target URL. For a "message arrives on a queue → lands on my HTTP endpoint" need,
RDP ships in minutes.

## Where it falls short

- **No circuit breaker**: if the target endpoint is down or returning errors, RDP keeps
  hammering it at a fixed rate. It doesn't back off, doesn't trip, doesn't protect the downstream
  system (or itself) from a persistent outage.
- **Responses are largely ignored**: retry/dead-letter behavior is coarse: success, or
  exhausted retries to the dead message queue. There's no branching on response *content*, and no
  way to distinguish "retry this" from "never retry this" the way application code can.
- **Thin error logging**: the broker log isn't built for root-causing a downstream HTTP
  problem. Diagnosing why a specific message was rejected, from broker logs alone, is painful.
- **No payload shaping**: no transformation, enrichment, or header mapping. Whatever is on the
  queue is what goes over the wire, verbatim.
- **Limited auth**: whatever the RDP's own REST target configuration happens to support; no
  first-class OAuth2 client-credentials flow with token refresh.

None of this is a knock on RDP; it's a deliberately minimal broker feature, not an integration
platform. The gap is what this project fills.

## What this bridge adds

A small, focused Ballerina service that subscribes to a Solace queue (`solace:Listener`,
`CLIENT_ACK` mode, never fire-and-forget) and delivers each message to a configured REST
endpoint, closing every gap above:

| Capability | Solace RDP | This bridge |
|---|---|---|
| Circuit breaker | None; hammers a failing target forever | Per-target, trips on consecutive failures, recovers automatically |
| Retry policy | Fixed, broker-level, coarse | Configurable backoff, bounded attempts, transient vs. permanent |
| Response handling | Mostly ignored | Full response inspection drives ack/nack/dead-letter |
| Error logging | Broker-level, not app-diagnosable | Structured: message ID, target, status code |
| Payload transformation | None | Field/header mapping and enrichment |
| Auth to target | Whatever the RDP config supports | Basic, OAuth2 client-credentials (with transparent refresh) |
| Setup effort | Broker config only, minutes | One more container + a config file |

**The honest trade-off:** RDP wins on zero operational footprint; there's nothing extra to
deploy, patch, or scale. That's real, and it's why RDP is the right first choice for the simple
case. This bridge trades that footprint away for control: one more container to run, but every
failure mode above becomes something you can configure, observe, and reason about instead of
something the broker just does to you.

This isn't a general-purpose integration platform (no visual mapping UI, no plugin
marketplace), it's a focused, single-purpose, open-source component, closer in spirit to a
well-written microservice than to a platform. Reach for it when a target needs more than "just
get it there": reliability, transformation, or real auth.

## Every scenario, in a runnable sample

Each capability above has its own working, self-contained sample under
[`../samples/`](../samples/): a real broker, the bridge, and a purpose-built mock target, with
the exact scenario explained, a comparison to what RDP would do instead, diagrams, and step-by-step
setup and test instructions.

| Scenario | What it shows | Sample |
|---|---|---|
| Resilient delivery | Retry/backoff, circuit breaker, response-aware ack/nack, with a real RDP running side by side, hammering a failing target with no backoff, for a direct comparison | [`samples/resilient-delivery`](../samples/resilient-delivery/) |
| Payload transformation | Field renaming and enrichment applied before delivery | [`samples/payload-transformation`](../samples/payload-transformation/) |
| Basic auth | Authenticating to a target that requires HTTP Basic credentials | [`samples/basic-auth`](../samples/basic-auth/) |
| OAuth2 client-credentials | Token acquisition, caching, and transparent refresh | [`samples/oauth2-client-credentials`](../samples/oauth2-client-credentials/) |
| Metrics and structured logs | Observing delivery outcomes via Prometheus-style counters and correlatable logs | Config layered onto any sample; see [`bridge/README.md`](../bridge/README.md) |

See [`architecture.md`](architecture.md) for how the bridge itself is put together, with
sequence diagrams for the delivery flow.
