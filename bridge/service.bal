// A Solace queue-to-REST delivery bridge: subscribes to a Solace queue and delivers each message
// to a configured HTTP target, with retry/backoff, a circuit breaker, response-aware ack/nack,
// payload transformation, metrics, and per-target auth (Basic or OAuth2) - the resilience a
// Solace REST Delivery Point (RDP) doesn't provide on its own.
//
// See docs/architecture.md for how the pieces fit together and docs/problem-and-solution.md for
// what this adds over RDP. Each capability below is demonstrated in isolation under samples/.
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/observe;
import ballerinax/prometheus as _;
import ballerinax/solace;

configurable string brokerUrl = "tcp://solace-broker:55555";
configurable string messageVpn = "default";
configurable string username = "admin";
configurable string password = "admin";

// Which queue to consume, where to deliver, and any static headers to attach to every request (in
// addition to any headers promoted from the payload via transformHeaderFields, and the always-on
// X-Correlation-Id - see transform.bal). targetUrl is the full URL including path, so pointing
// this at a different target - including a different path - is purely a config change.
configurable string queueName = "bridge-demo-queue";
configurable string targetUrl = "http://localhost:8081/deliver";
configurable map<string> targetHeaders = {};

// HTTP Basic auth - optional. An empty targetUsername (the default) means no Authorization header
// is sent at all, not one with empty credentials.
configurable string targetUsername = "";
configurable string targetPassword = "";

// OAuth2 client-credentials - an alternative to Basic above, not stacked with it (see
// newTargetClient's precedence: a non-empty targetOAuth2TokenUrl wins). Once configured, the
// http:Client handles the whole flow itself: fetching a token from tokenUrl using
// clientId/clientSecret, attaching it as a Bearer token on every request, and transparently
// re-fetching once the cached token's own expires_in has elapsed. Nothing in this file tracks
// token state.
configurable string targetOAuth2TokenUrl = "";
configurable string targetOAuth2ClientId = "";
configurable string targetOAuth2ClientSecret = "";
configurable string[] targetOAuth2Scopes = [];

// Retry + backoff, applied per delivery attempt by the http:Client itself. requestTimeout is
// per-attempt - a response slower than this counts as a timeout failure, which retries exactly
// like a 5xx does. retryCount is *additional* attempts after the first (so 3 means up to 4 total
// tries); interval grows by retryBackOffFactor each time, capped at retryMaxWaitInterval.
configurable decimal requestTimeout = 5;
configurable int retryCount = 3;
configurable decimal retryInterval = 1;
configurable float retryBackOffFactor = 2.0;
configurable decimal retryMaxWaitInterval = 10;

// Circuit breaker, wrapping the retry-enabled client above. requestVolumeThreshold is the minimum
// number of *final* outcomes (post-retry) required in the rolling window before the breaker will
// even consider tripping; failureThreshold is the failure ratio (0-1) that trips it once that
// minimum is met; resetTime is how long it stays open before a single trial call decides whether
// to close again (that trial itself still goes through the full retry sequence, so a failing
// trial can take as long as a normal failed attempt does).
//
// bucketSize/timeWindow need comfortable margin over how long a single failed attempt actually
// takes, or the rolling window's own bucket rotation clears each failure before enough of them can
// accumulate together, so the breaker never sees them as a group and never trips. How long a
// failed attempt takes isn't fixed either: a 5xx response fails fast, but a connection failure
// (e.g. DNS resolution against a stopped host) is typically slower. Size these with margin for
// the slower case for your own environment.
configurable int circuitBreakerRequestVolumeThreshold = 3;
configurable decimal circuitBreakerTimeWindow = 120;
configurable decimal circuitBreakerBucketSize = 30;
configurable float circuitBreakerFailureThreshold = 0.5;
configurable decimal circuitBreakerResetTime = 20;

// A fast-fail while the circuit is open costs microseconds, but the broker still redelivers with
// no backoff of its own even with the breaker in place. Without a floor here, the two combine into
// a busy loop against the broker itself - this delay is that floor, not a substitute for
// broker-level backoff (which this bridge doesn't configure - see docs/architecture.md).
configurable decimal circuitOpenNackDelay = 1;

// Which outcomes count as failures - shared by the retry and circuit-breaker configs above, since
// both are answering the same question: "was this a transient problem with the target, or
// something else?" A 4xx is deliberately excluded from both: it's a permanent rejection (see the
// branching in handleDelivery below), so it should neither be retried nor count against the
// target's health. Override via Config.toml if a target uses a code outside this default set to
// mean "transient."
configurable int[] transientStatusCodes = [500, 502, 503, 504, 507, 508, 509];

listener solace:Listener bridgeListener = check new (brokerUrl, {
    messageVpn,
    auth: {username, password}
});

// OAuth2 takes precedence over Basic when both happen to be configured - the two are
// alternatives, not stackable.
type TargetAuthConfig record {|
    string username = "";
    string password = "";
    string oauth2TokenUrl = "";
    string oauth2ClientId = "";
    string oauth2ClientSecret = "";
    string[] oauth2Scopes = [];
|};

function newTargetClient(string url, TargetAuthConfig auth) returns http:Client|error {
    http:ClientConfiguration config = {
        timeout: requestTimeout,
        retryConfig: {
            count: retryCount,
            interval: retryInterval,
            backOffFactor: retryBackOffFactor,
            maxWaitInterval: retryMaxWaitInterval,
            statusCodes: transientStatusCodes
        },
        circuitBreaker: {
            rollingWindow: {
                requestVolumeThreshold: circuitBreakerRequestVolumeThreshold,
                timeWindow: circuitBreakerTimeWindow,
                bucketSize: circuitBreakerBucketSize
            },
            failureThreshold: circuitBreakerFailureThreshold,
            resetTime: circuitBreakerResetTime,
            statusCodes: transientStatusCodes
        }
    };
    if auth.oauth2TokenUrl != "" {
        config.auth = {
            tokenUrl: auth.oauth2TokenUrl,
            clientId: auth.oauth2ClientId,
            clientSecret: auth.oauth2ClientSecret,
            scopes: auth.oauth2Scopes
        };
    } else if auth.username != "" {
        config.auth = {username: auth.username, password: auth.password};
    }
    return new (url, config);
}

// Note: an OAuth2-configured client fetches its first token *eagerly*, during construction. If
// the token endpoint rejects the credentials, client construction itself fails - which fails this
// whole module's init() and stops the bridge from starting at all, rather than only failing
// deliveries. Wrong Basic credentials, by contrast, only ever fail the deliveries that use them,
// since attaching a Basic header needs no network call first. See samples/oauth2-client-credentials
// for this behavior demonstrated directly.
final http:Client mockEndpoint = check newTargetClient(targetUrl, {
    username: targetUsername,
    password: targetPassword,
    oauth2TokenUrl: targetOAuth2TokenUrl,
    oauth2ClientId: targetOAuth2ClientId,
    oauth2ClientSecret: targetOAuth2ClientSecret,
    oauth2Scopes: targetOAuth2Scopes
});

// Three mutually exclusive outcomes per message - exactly one of these increments per delivery
// attempt, so together they total every message this bridge instance has handled. "Failure"
// covers every nack, whichever branch reached it (transformation failure, a 4xx from the target,
// or exhausted retries); circuit-open gets its own counter since it means the target was never
// even called - a meaningfully different outcome from a call that was made and failed. See
// bridge/README.md's Metrics section for how to scrape these.
final observe:Counter deliverySuccessCounter = new ("bridge_delivery_success_total",
        desc = "Messages successfully delivered and acked");
final observe:Counter deliveryFailureCounter = new ("bridge_delivery_failure_total",
        desc = "Messages nacked - transformation failure, a 4xx, or exhausted retries");
final observe:Counter circuitOpenCounter = new ("bridge_circuit_open_total",
        desc = "Deliveries fast-failed because the circuit was open - the target was never called");

// The whole per-message delivery pipeline.
//
// The outcome, in order of precedence: a payload that fails to parse nacks straight to the dead
// message queue (DMQ), no HTTP call made at all. Otherwise the transformed payload is POSTed to
// the target (retried per the retry config above, subject to the circuit breaker); a 2xx acks; a
// 4xx (including a 401/403 from a target's own auth check - already a permanent rejection) nacks
// to the DMQ without a requeue; anything else - a 5xx after retries are exhausted, a request-level
// error, or the circuit already being open - nacks with a requeue, which the broker redelivers.
// message.deliveryCount (a numeric attempt count) isn't logged: at the time this was written, the
// connector's own call into the underlying client library throws for this queue/broker
// configuration and the field is never populated. message.redelivered (a boolean) is reliably set
// and is logged instead.
function handleDelivery(solace:Message message, solace:Caller caller) returns error? {
    string? messageId = message.messageId;
    boolean redelivered = message.redelivered ?: false;

    log:printInfo("received", messageId = messageId, redelivered = redelivered);

    map<json>|error transformed = transformPayload(message.payload);
    if transformed is error {
        log:printError("payload transformation failed, bad payload - routing to DMQ",
                messageId = messageId, redelivered = redelivered, 'error = transformed);
        check caller->nack(message, requeue = false);
        deliveryFailureCounter.increment();
        log:printInfo("nacked, sent to DMQ", messageId = messageId, redelivered = redelivered);
        return;
    }

    http:Request request = new;
    request.setJsonPayload(transformed);
    foreach [string, string] [headerName, headerValue] in targetHeaders.entries() {
        request.setHeader(headerName, headerValue);
    }
    foreach [string, string] [headerName, headerValue] in resolveHeaderFields(transformed).entries() {
        request.setHeader(headerName, headerValue);
    }
    if messageId is string {
        request.setHeader("X-Correlation-Id", messageId);
    }

    log:printInfo("forwarding to target", messageId = messageId,
            target = targetUrl, redelivered = redelivered);
    http:Response|error response = mockEndpoint->post("", request);

    if response is http:Response {
        int statusCode = response.statusCode;
        if statusCode >= 200 && statusCode < 300 {
            log:printInfo("delivered", messageId = messageId, target = targetUrl,
                    redelivered = redelivered, statusCode = statusCode);
            check caller->ack(message);
            deliverySuccessCounter.increment();
            log:printInfo("acked", messageId = messageId, redelivered = redelivered);
        } else if statusCode >= 400 && statusCode < 500 {
            log:printError("delivery rejected, bad payload - routing to DMQ",
                    messageId = messageId, target = targetUrl,
                    redelivered = redelivered, statusCode = statusCode);
            check caller->nack(message, requeue = false);
            deliveryFailureCounter.increment();
            log:printInfo("nacked, sent to DMQ", messageId = messageId,
                    redelivered = redelivered);
        } else {
            log:printError("delivery failed after retries, requeueing for redelivery",
                    messageId = messageId, target = targetUrl,
                    redelivered = redelivered, statusCode = statusCode);
            check caller->nack(message, requeue = true);
            deliveryFailureCounter.increment();
            log:printInfo("nacked, requeued", messageId = messageId, redelivered = redelivered);
        }
    } else if response is http:UpstreamServiceUnavailableError {
        log:printError("circuit open, fast-failing without calling the target - requeueing",
                messageId = messageId, target = targetUrl, redelivered = redelivered,
                'error = response);
        runtime:sleep(circuitOpenNackDelay);
        check caller->nack(message, requeue = true);
        circuitOpenCounter.increment();
        log:printInfo("nacked, requeued", messageId = messageId, redelivered = redelivered);
    } else {
        log:printError("delivery attempt errored after retries, requeueing for redelivery",
                messageId = messageId, target = targetUrl, redelivered = redelivered,
                'error = response);
        check caller->nack(message, requeue = true);
        deliveryFailureCounter.increment();
        log:printInfo("nacked, requeued", messageId = messageId, redelivered = redelivered);
    }
}

function init() returns error? {
    check deliverySuccessCounter.register();
    check deliveryFailureCounter.register();
    check circuitOpenCounter.register();
}

@solace:ServiceConfig {
    queueName,
    ackMode: solace:CLIENT_ACK
}
service on bridgeListener {

    remote function onMessage(solace:Message message, solace:Caller caller) returns error? {
        return handleDelivery(message, caller);
    }
}
