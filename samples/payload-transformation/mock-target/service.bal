// Mock target for the "payload transformation" sample - a single resource that logs the body
// and every header it receives, so the bridge's transformation is visible arriving here, not
// just asserted.
import ballerina/http;
import ballerina/log;

listener http:Listener mockListener = new (8080);

service / on mockListener {

    resource function post deliver(http:Caller caller, http:Request req) returns error? {
        string|error body = req.getTextPayload();
        http:Response res = new;

        if body is error {
            log:printError("received request, unreadable body, returning 400", 'error = body);
            res.statusCode = 400;
            check caller->respond(res);
            return;
        }

        map<string> headers = {};
        foreach string headerName in req.getHeaderNames() {
            string|error headerValue = req.getHeader(headerName);
            if headerValue is string {
                headers[headerName] = headerValue;
            }
        }

        log:printInfo("received request", body = body, headers = headers.toString());
        res.statusCode = 200;
        check caller->respond(res);
    }
}
