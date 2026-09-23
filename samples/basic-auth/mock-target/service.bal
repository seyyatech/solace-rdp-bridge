// Mock target for the "Basic auth" sample - a single resource that requires HTTP Basic
// credentials before accepting a delivery.
import ballerina/http;
import ballerina/lang.array;
import ballerina/log;

const string USERNAME = "demo-user";
const string PASSWORD = "demo-pass";

listener http:Listener mockListener = new (8080);

service / on mockListener {

    resource function post deliver(http:Caller caller, http:Request req) returns error? {
        if !hasValidBasicAuth(req) {
            log:printInfo("received request, missing or invalid credentials, returning 401");
            http:Response res = new;
            res.statusCode = 401;
            res.setHeader("WWW-Authenticate", "Basic realm=\"mock-target\"");
            check caller->respond(res);
            return;
        }

        string|error body = req.getTextPayload();
        http:Response res = new;
        if body is error {
            log:printError("received request, unreadable body, returning 400", 'error = body);
            res.statusCode = 400;
            check caller->respond(res);
            return;
        }

        log:printInfo("received request, valid credentials", body = body);
        res.statusCode = 200;
        check caller->respond(res);
    }
}

// True only for a well-formed "Basic <base64(username:password)>" header decoding to exactly
// USERNAME:PASSWORD. Anything else (missing header, wrong scheme, malformed base64, wrong
// credentials) returns false, all treated the same by the caller: a 401.
function hasValidBasicAuth(http:Request req) returns boolean {
    string|error authHeader = req.getHeader("Authorization");
    if authHeader is error || !authHeader.startsWith("Basic ") {
        return false;
    }
    byte[]|error decoded = array:fromBase64(authHeader.substring(6));
    if decoded is error {
        return false;
    }
    byte[] expected = string `${USERNAME}:${PASSWORD}`.toBytes();
    return decoded == expected;
}
