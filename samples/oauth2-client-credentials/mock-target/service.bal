// Mock target for the "OAuth2 client-credentials" sample - a token endpoint (/oauth2/token) that
// issues a short-lived bearer token to a valid client, and a delivery target (/deliver) that
// requires it. Each issued token is distinct (demo-token-1, demo-token-2, ...) and short-lived
// (5 seconds), so a refresh is both fast to demo and visibly a *different* token, not a repeated
// call.
import ballerina/http;
import ballerina/lang.array;
import ballerina/log;

const string CLIENT_ID = "demo-client";
const string CLIENT_SECRET = "demo-secret";
const int TOKEN_EXPIRY_SECONDS = 5;

int tokenCounter = 0;

function issueToken() returns string {
    lock {
        tokenCounter += 1;
        return "demo-token-" + tokenCounter.toString();
    }
}

listener http:Listener mockListener = new (8080);

service / on mockListener {

    // Accepts client credentials either as HTTP Basic (RFC 6749's recommended form, and this
    // connector's default) or as client_id/client_secret form fields, since either is spec-legal.
    resource function post oauth2/token(http:Caller caller, http:Request req) returns error? {
        if !hasValidClientCredentials(req) {
            log:printInfo("received token request, invalid client credentials, returning 401");
            http:Response res = new;
            res.statusCode = 401;
            check caller->respond(res);
            return;
        }
        string token = issueToken();
        log:printInfo("received token request, issuing token", token = token,
                expiresIn = TOKEN_EXPIRY_SECONDS);
        http:Response res = new;
        res.statusCode = 200; // RFC 6749 §5.1 requires 200, not a POST resource's 201 default
        res.setJsonPayload({
            access_token: token,
            token_type: "Bearer",
            expires_in: TOKEN_EXPIRY_SECONDS
        });
        check caller->respond(res);
    }

    resource function post deliver(http:Caller caller, http:Request req) returns error? {
        if !hasValidBearerToken(req) {
            log:printInfo("received request, missing or invalid bearer token, returning 401");
            http:Response res = new;
            res.statusCode = 401;
            res.setHeader("WWW-Authenticate", "Bearer");
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

        log:printInfo("received request, valid token", body = body);
        res.statusCode = 200;
        check caller->respond(res);
    }
}

function hasValidClientCredentials(http:Request req) returns boolean {
    string|error authHeader = req.getHeader("Authorization");
    if authHeader is string && authHeader.startsWith("Basic ") {
        byte[]|error decoded = array:fromBase64(authHeader.substring(6));
        if decoded is error {
            return false;
        }
        byte[] expected = string `${CLIENT_ID}:${CLIENT_SECRET}`.toBytes();
        return decoded == expected;
    }

    map<string>|error params = req.getFormParams();
    if params is error {
        return false;
    }
    return params["client_id"] == CLIENT_ID && params["client_secret"] == CLIENT_SECRET;
}

// Any token this mock itself issued is accepted - the point of this sample is observing the
// bridge's *client-side* fetch/cache/refresh behavior, not building real server-side token
// validation for a mock that only ever hands out its own tokens to begin with.
function hasValidBearerToken(http:Request req) returns boolean {
    string|error authHeader = req.getHeader("Authorization");
    if authHeader is error || !authHeader.startsWith("Bearer ") {
        return false;
    }
    return authHeader.substring(7).startsWith("demo-token-");
}
