# The problem, and what this bridge does about it

## What a REST Delivery Point is

A Solace **REST Delivery Point (RDP)** binds one or more queues to one or more outbound HTTP
targets. It's a broker-native feature, no code, no separate process to run. Configure it via
the broker's management API or UI, and the broker itself starts POSTing (or PUTting) queued
messages to the target URL. For a "message arrives on a queue → lands on my HTTP endpoint" need,
RDP ships in minutes.

## What RDP does well

Before the gaps: RDP is a genuinely capable broker feature on its own, and knowing this list
matters, since the gap below isn't "RDP can't do X" for anything on it.

- **Nothing extra to run**: no separate process, container, or thing to patch or scale.
- **Fails over with the broker**: high availability comes from the broker itself.
- **Available on Solace Cloud**: the same feature, whether self-managed or fully managed.
- **Seven authentication schemes** built into the REST consumer, no code: `http-basic`,
  `client-certificate`, `http-header`, `oauth-client`, `oauth-jwt`, `transparent`, and `aws`
  (SigV4).
- **Substitution expressions**: request targets and headers can be built from topic values,
  message properties, or system-generated tokens, without touching the payload.
- **Configurable rejection codes** (broker version 10.12+): specific 4xx/5xx codes can be marked
  as permanent rejections, skipping retry and going straight to the dead message queue.

## Where application logic helps

- **No circuit breaker**: RDP retries at a fixed interval indefinitely by default (the count is
  bounded only if you configure a queue's `max-redelivery`/`max-ttl` yourself), with no growing
  backoff and no way to trip and stop calling a persistently failing target.
- **Response handling is broker-level, not application-level**: rejection codes (above) cover
  "never retry this," but there's still no branching on response *content*, and nowhere for that
  decision to live as testable, versionable code.
- **Logs are broker-level**: per-message delivery tracing (which target, which attempt, why it
  failed) lives in application code, not in the broker's own logs.
- **No body reshaping**: substitution expressions (above) cover dynamic *header* values, but the
  message body itself is delivered verbatim; reshaping or enriching its content needs application
  code.

None of this is a knock on RDP; it's a deliberately minimal broker feature, not an integration
platform. The gap is what this project fills.

## What this bridge adds

A small, focused Ballerina service that subscribes to a Solace queue (`solace:Listener`,
`CLIENT_ACK` mode, never fire-and-forget) and delivers each message to a configured REST
endpoint, closing every gap above:

| Capability | Solace RDP | This bridge |
|---|---|---|
| Circuit breaker | None; retries at a fixed interval indefinitely by default, no backoff | Per-target, trips on consecutive failures, recovers automatically |
| Retry policy | Fixed interval; bounded by `max-redelivery`/`max-ttl` if you configure them | Configurable growing backoff, bounded attempts, transient vs. permanent |
| Response handling | Configurable rejection codes (10.12+) skip retry; no branching on content | Full response inspection drives ack/nack/dead-letter |
| Error logging | Broker-level, not app-diagnosable | Structured: message ID, target, status code |
| Payload transformation | Headers only, via substitution expressions; body delivered verbatim | Field/header mapping and enrichment of the body itself |
| Auth to target | 7 schemes built in (Basic, OAuth2 client-credentials/JWT, mTLS, header, transparent, AWS SigV4) | Basic, OAuth2 client-credentials (with transparent refresh) |
| Setup effort | Broker config only, minutes | One more container + a config file |

**The honest trade-off:** RDP wins on zero operational footprint; there's nothing extra to
deploy, patch, or scale. That's real, and it's why RDP is the right first choice for the simple
case. This bridge trades that footprint away for control: one more container to run, but every
failure mode above becomes something you can configure, observe, and reason about.

This isn't a general-purpose integration platform (no visual mapping UI, no plugin
marketplace), it's a focused, single-purpose, open-source component, closer in spirit to a
well-written microservice than to a platform. Reach for it when a target needs more than "just
get it there": reliability or transformation, optionally combined with auth RDP also supports.

## Start with RDP, reach for this when...

For most delivery needs, RDP is the right first choice: zero operational footprint, native HA,
broad auth support out of the box. Reach for this bridge when you need one or more of:

- A target that fails intermittently and needs backoff plus a circuit breaker, not just bounded
  retries.
- The message body itself needs reshaping or enrichment before delivery, not just header values.
- Per-message, application-level tracing of what was delivered, where, and why it failed.
- Prometheus-style metrics on delivery outcomes.
- Any of the above alongside auth RDP also supports (Basic, OAuth2) - the value isn't a new auth
  mechanism, it's combining auth with the capabilities above in one composable piece of software.

The bridge's own reliability rests entirely on Solace's guaranteed messaging, `CLIENT_ACK`, the
dead message queue, and redelivery; it doesn't reimplement any of that. What it adds is
decision-making on top of a delivery mechanism Solace already built.

## Every scenario, in a runnable sample

Each capability above has its own working, self-contained sample under
[`../samples/`](../samples/): a real broker, the bridge, and a purpose-built mock target, with
the exact scenario explained, a comparison to what RDP would do instead, diagrams, and step-by-step
setup and test instructions.

| Scenario | What it shows | Sample |
|---|---|---|
| Resilient delivery | Retry/backoff, circuit breaker, response-aware ack/nack, with a real RDP running side by side for a direct comparison | [`samples/resilient-delivery`](../samples/resilient-delivery/) |
| Payload transformation | Field renaming and enrichment applied before delivery | [`samples/payload-transformation`](../samples/payload-transformation/) |
| Basic auth | Authenticating to a target that requires HTTP Basic credentials | [`samples/basic-auth`](../samples/basic-auth/) |
| OAuth2 client-credentials | Token acquisition, caching, and transparent refresh | [`samples/oauth2-client-credentials`](../samples/oauth2-client-credentials/) |
| Metrics and structured logs | Observing delivery outcomes via Prometheus-style counters and correlatable logs | Config layered onto any sample; see [`bridge/README.md`](../bridge/README.md) |

See [`architecture.md`](architecture.md) for how the bridge itself is put together, with
sequence diagrams for the delivery flow.
