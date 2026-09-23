# Samples

Each sample below is a fully self-contained, runnable demo: a real Solace broker, the shared
[`../bridge`](../bridge/), and a small, purpose-built mock target. Nothing in a sample reaches
outside its own folder except that shared `bridge/` build context, so each one can be read, run,
and understood on its own. Only run one sample's stack at a time; they use the same container
names and ports.

| Sample | What it shows |
|---|---|
| [`resilient-delivery`](resilient-delivery/) | Retry/backoff, circuit breaker, response-aware ack/nack, with a real RDP running side by side for a direct comparison |
| [`payload-transformation`](payload-transformation/) | Field renaming and enrichment applied before delivery |
| [`basic-auth`](basic-auth/) | Authenticating to a target that requires HTTP Basic credentials |
| [`oauth2-client-credentials`](oauth2-client-credentials/) | Token acquisition, caching, and transparent refresh |

New to the project? Start with [`../docs/problem-and-solution.md`](../docs/problem-and-solution.md)
for what this extends and why, and [`../docs/architecture.md`](../docs/architecture.md) for how
the bridge itself works, then pick whichever sample matches what you're trying to do.

## How to run a sample

1. Pick a sample from the table above and go to its folder:

   ```bash
   cd samples/<sample-name>   # e.g. cd samples/basic-auth
   ```

2. Refer to that sample's own `README.md`; each one is self-contained and documents its exact
   setup, try-it, and teardown steps, since what's being demonstrated differs per sample. The
   general shape is the same across all of them:

   ```bash
   docker compose up -d --build   # starts the broker, bridge, and mock target
   ./init/setup.sh                 # provisions the queue(s)/DMQ the sample uses
   # ... then the sample's own "Try it" steps ...
   docker compose down --remove-orphans   # tear down when done
   ```

Only run one sample's stack at a time; they share container names and ports.

Metrics and structured logs aren't a separate sample: every sample's `docker-config.toml` ships
the Prometheus config commented out, ready to enable on top of whichever scenario you're already
running. See [`../bridge/README.md`](../bridge/README.md) for what they measure and how.

## Moving from a sample to your own deployment

Each sample's `docker-compose.yaml` doubles as a starting template: point its `docker-config.toml`
at your real broker and target instead of the demo values, then edit the compose file to remove
the `mock-target` service and its entry in the `bridge` service's `depends_on` (it exists to give
the sample something to demonstrate against, not to be part of your deployment).
