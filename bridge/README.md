# bridge

The Ballerina service that is the actual product: it subscribes to one or more Solace queues and
delivers each message to a configured HTTP target, replacing what a Solace REST Delivery Point
(RDP) does, with the resilience RDP doesn't provide. See
[`../docs/problem-and-solution.md`](../docs/problem-and-solution.md) for the case against RDP and
[`../docs/architecture.md`](../docs/architecture.md) for how the pieces below fit together,
including sequence diagrams.

## What it does

- **Response-aware ack/nack**: a 2xx acks the message; a 4xx (a permanent rejection, including a
  target's own auth failure) nacks it straight to the dead message queue (DMQ) with no retry; a
  5xx, a timeout, or a request-level error retries, then nacks with a requeue if every attempt
  fails.
- **Retry with backoff and a circuit breaker**, per target: a struggling target gets protected
  instead of hammered at a fixed rate.
- **Structured logs**: every log line carries the message ID, the target, and whether the
  message was redelivered, so a failed delivery is root-causable from the bridge's own logs.
- **Payload transformation**: a fixed field/header mapping and enrichment, applied before
  delivery.
- **Prometheus-style metrics**: success/failure/circuit-open counters at `/metrics`.
- **Two independent, config-driven routes**: a distinct queue-to-target mapping per route, each
  reconfigurable without a rebuild.
- **HTTP Basic and OAuth2 client-credentials auth**, per route: OAuth2 handles token acquisition,
  caching, and transparent refresh on its own.

Every one of these is demonstrated in isolation, with a working setup and test steps, under
[`../samples/`](../samples/).

## Configuration

All configuration is `configurable` Ballerina variables, overridable via a `Config.toml`. The
tables below group every key by what it controls; see
[`Config.toml.example`](Config.toml.example) for the full reference, every key with its default,
ready to copy from. Each sample under `../samples/` ships its own `Config.toml` (or
`docker-config.toml`, bind-mounted for a no-rebuild config edit) tuned to that sample's scenario,
built against this same, unmodified `bridge` image.

Keys are listed once, for route 1. Route 2 is configured the same way, independently, using the
same keys with a `2` suffix (e.g. `targetUrl` / `targetUrl2`).

Every key already has a default, so nothing below is required for the bridge to start, but the
**Required** column distinguishes keys you need to set to a real value for the bridge to do
anything useful against your own broker/target from keys that are genuinely **optional**: safe to
leave at their default, which turns the whole feature they belong to off rather than leaving it
half-configured.

**Solace connection** (required to point at your own broker):

| Key | Default | Required | Controls |
|---|---|---|---|
| `brokerUrl` | `tcp://localhost:55554` | Required | Broker's SMF URL |
| `messageVpn` | `default` | Required | Message VPN to connect to |
| `username` / `password` | `admin` / `admin` | Required | Broker client credentials |

**Routing**

| Key | Default | Required | Controls |
|---|---|---|---|
| `queueName` | `bridge-demo-queue` | Required | Queue this route consumes from |
| `targetUrl` | `http://localhost:8081/deliver` | Required | Full delivery URL, including path |
| `targetHeaders` | `{ }` | Optional | Static headers attached to every request, in addition to the data-driven `X-Event-Type`/`X-Correlation-Id` headers set from the payload |

**Basic auth** (optional; leave unset to send no `Authorization` header at all):

| Key | Default | Required | Controls |
|---|---|---|---|
| `targetUsername` / `targetPassword` | `""` / `""` | Optional | HTTP Basic credentials for the target. An empty `targetUsername` sends no `Authorization` header at all |

**OAuth2 client-credentials** (optional; an alternative to Basic auth above, not stacked with it,
OAuth2 wins if both are set):

| Key | Default | Required | Controls |
|---|---|---|---|
| `targetOAuth2TokenUrl` | `""` | Optional | Token endpoint. Empty disables OAuth2 for this route |
| `targetOAuth2ClientId` / `targetOAuth2ClientSecret` | `""` / `""` | Optional | Client-credentials grant credentials. Token acquisition, caching, and refresh are handled transparently once set |
| `targetOAuth2Scopes` | `[]` | Optional | Scopes requested with the token. Empty requests the token endpoint's default scopes |

**Retry and backoff** (optional tuning; applied per delivery attempt by the underlying
`http:Client`, with working defaults out of the box):

| Key | Default | Required | Controls |
|---|---|---|---|
| `requestTimeout` | `5` | Optional | Per-attempt timeout, in seconds; a slower response counts as a timeout failure, retried like a 5xx |
| `retryCount` | `3` | Optional | *Additional* attempts after the first (3 = up to 4 total tries) |
| `retryInterval` | `1` | Optional | Initial wait between attempts, in seconds |
| `retryBackOffFactor` | `2.0` | Optional | Multiplier applied to the interval after each retry |
| `retryMaxWaitInterval` | `10` | Optional | Cap on the backoff interval, in seconds |

**Circuit breaker** (optional tuning; wraps the retry-enabled client above, per target):

| Key | Default | Required | Controls |
|---|---|---|---|
| `circuitBreakerRequestVolumeThreshold` | `3` | Optional | Minimum number of final (post-retry) outcomes required in the rolling window before the breaker will even consider tripping |
| `circuitBreakerTimeWindow` | `120` | Optional | Rolling window size, in seconds |
| `circuitBreakerBucketSize` | `30` | Optional | Bucket size within that window, in seconds |
| `circuitBreakerFailureThreshold` | `0.5` | Optional | Failure ratio (0-1) that trips the breaker once the volume threshold is met |
| `circuitBreakerResetTime` | `20` | Optional | How long the breaker stays open, in seconds, before a single trial call decides whether to close again |
| `circuitOpenNackDelay` | `1` | Optional | How long the bridge pauses, in seconds, before `nack(requeue=true)` while the circuit is open, so instant broker redelivery doesn't turn into a busy loop |

The rolling window is split into fixed-size buckets (`circuitBreakerTimeWindow` / `circuitBreakerBucketSize` of them) so the breaker can track "the last N seconds" cheaply: each bucket tallies outcomes for its slice of time, and the oldest bucket ages out as time moves forward. Size `circuitBreakerBucketSize` with margin over how long a failed attempt actually takes; too small, and a bucket can rotate out (clearing its failures) before enough accumulate together for the breaker to see them as a group.

**Failure classification** (optional tuning; shared by retry and the circuit breaker above, since
both are answering "was this a transient problem with the target?"):

| Key | Default | Required | Controls |
|---|---|---|---|
| `transientStatusCodes` | `[500, 502, 503, 504, 507, 508, 509]` | Optional | Status codes treated as transient. A 4xx is deliberately excluded: it's a permanent rejection, so it neither retries nor counts against target health |

## Running it directly

```bash
cd bridge
cp Config.toml.example Config.toml   # then edit to point at your broker/target
bal run
```

Or as a container: see any sample under `../samples/` for a complete, working
`docker-compose.yaml` that builds this folder and wires it up to a broker and a target.
