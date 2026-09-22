// Mock target for the "resilient delivery" sample - two independent resources:
// - `/` always returns 500, simulating the target a Solace REST Delivery Point (RDP) would
//   hammer forever with no backoff.
// - `/deliver` is the bridge's target. It returns 200 by default, or an ambient failure mode set
//   via `/control`, so the bridge's retry/circuit-breaker behavior can be triggered on demand
//   without touching a single message. A per-request `forceStatus`/`delaySeconds` field in the
//   message body still overrides the ambient mode when present, for triggering one specific
//   outcome on demand instead of flipping global state.
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;

type ControlState record {|
    int? statusCode = ();
    int? delaySeconds = ();
|};

ControlState controlState = {};

function getControlState() returns ControlState {
    lock {
        return controlState.clone();
    }
}

function setControlState(ControlState newState) {
    lock {
        controlState = newState.clone();
    }
}

listener http:Listener mockListener = new (8080);

service / on mockListener {

    // The bridge's delivery target.
    resource function post deliver(http:Caller caller, http:Request req) returns error? {
        string|error body = req.getTextPayload();
        http:Response res = new;

        if body is error {
            log:printError("received request, unreadable body, returning 400", 'error = body);
            res.statusCode = 400;
            check caller->respond(res);
            return;
        }

        json|error payload = body.fromJsonString();
        if payload is error {
            log:printInfo("received request, non-JSON body, returning 400", body = body);
            res.statusCode = 400;
            check caller->respond(res);
            return;
        }

        ControlState ambient = getControlState();
        int statusCode = ambient.statusCode ?: 200;
        int delaySeconds = ambient.delaySeconds ?: 0;
        if payload is map<json> {
            json pDelaySeconds = payload["delaySeconds"];
            if pDelaySeconds is int && pDelaySeconds > 0 {
                delaySeconds = pDelaySeconds;
            }
            json forceStatus = payload["forceStatus"];
            if forceStatus is int {
                statusCode = forceStatus;
            }
        }
        if delaySeconds > 0 {
            log:printInfo("delaying before responding", delaySeconds = delaySeconds);
            runtime:sleep(<decimal>delaySeconds);
        }

        log:printInfo("received request, returning status", body = body, statusCode = statusCode);
        res.statusCode = statusCode;
        check caller->respond(res);
    }

    // Sets (or reads) the ambient failure mode `/deliver` defaults to - e.g. `{"statusCode": 503}`
    // to simulate the target being unhealthy, or `{}` to clear back to healthy.
    resource function post control(http:Caller caller, http:Request req) returns error? {
        json|error body = req.getJsonPayload();
        if body is error || body !is map<json> {
            http:Response res = new;
            res.statusCode = 400;
            check caller->respond(res);
            return;
        }
        json rawStatusCode = body["statusCode"];
        json rawDelaySeconds = body["delaySeconds"];
        ControlState newState = {
            statusCode: rawStatusCode is int ? rawStatusCode : (),
            delaySeconds: rawDelaySeconds is int ? rawDelaySeconds : ()
        };
        setControlState(newState);
        log:printInfo("control state updated", statusCode = newState.statusCode,
                delaySeconds = newState.delaySeconds);
        check caller->respond(newState);
    }

    resource function get control(http:Caller caller) returns error? {
        check caller->respond(getControlState());
    }

    // RDP's target - always fails, so RDP hammers it with no backoff, for direct comparison.
    resource function post [string... path](http:Caller caller) returns error? {
        log:printInfo("received request, always returning 500", path = string:'join("/", ...path));
        http:Response res = new;
        res.statusCode = 500;
        check caller->respond(res);
    }
}
