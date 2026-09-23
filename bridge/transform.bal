// Config-driven payload transformation: renames, constant/timestamp enrichment, and header
// promotion, none of which need this module rebuilt to change - see bridge/README.md's Payload
// transformation section for the full reference. samples/payload-transformation sets these to
// reproduce its documented before/after example; every other sample leaves them at their empty
// defaults, so the payload passes through untouched.
import ballerina/time;

configurable map<string> transformFieldRenames = {};
configurable map<json> transformStaticFields = {};
configurable string transformTimestampField = "";
configurable map<string> transformHeaderFields = {};

// Splits a dot-path into its segments without relying on a regex engine - "a.b.c" -> ["a","b","c"].
function splitPath(string path) returns string[] {
    string[] segments = [];
    string remaining = path;
    int? dotIndex = remaining.indexOf(".");
    while dotIndex is int {
        segments.push(remaining.substring(0, dotIndex));
        remaining = remaining.substring(dotIndex + 1);
        dotIndex = remaining.indexOf(".");
    }
    segments.push(remaining);
    return segments;
}

// Reads a value from a JSON object by dot-path. An exact, literal top-level key match is tried
// first; only if no such key exists does this split the path on "." and walk it as nested
// objects. That's what lets a payload with a genuinely flat key containing a literal dot (e.g.
// {"employee.employeeId": 1}) and a payload with real nesting (e.g.
// {"employee": {"employeeId": 1}}) both resolve correctly from the same "employee.employeeId"
// config string, with no separate escaping syntax to learn.
function getByPath(map<json> obj, string path) returns json {
    if obj.hasKey(path) {
        return obj[path];
    }
    string[] segments = splitPath(path);
    if segments.length() == 1 {
        return ();
    }
    json current = obj;
    foreach string segment in segments {
        map<json> currentObj;
        if current is map<json> {
            currentObj = current;
        } else {
            return ();
        }
        if !currentObj.hasKey(segment) {
            return ();
        }
        current = currentObj[segment];
    }
    return current;
}

// Removes whatever getByPath would have found - same literal-key-first, then nested-walk
// resolution - so a rename cleans up the exact field it read from, flat or nested, without
// leaving a stale copy behind.
function removeByPath(map<json> obj, string path) {
    if obj.hasKey(path) {
        _ = obj.remove(path);
        return;
    }
    string[] segments = splitPath(path);
    if segments.length() == 1 {
        return;
    }
    map<json> current = obj;
    foreach int i in 0 ..< segments.length() - 1 {
        json next = current[segments[i]];
        if next is map<json> {
            current = next;
        } else {
            return;
        }
    }
    string lastSegment = segments[segments.length() - 1];
    if current.hasKey(lastSegment) {
        _ = current.remove(lastSegment);
    }
}

// Writes a value into a JSON object by dot-path, creating intermediate objects as needed. There's
// no pre-existing structure to disambiguate against on the write side (unlike getByPath), so a
// dot always means "nest" here.
function setByPath(map<json> obj, string path, json value) {
    string[] segments = splitPath(path);
    map<json> current = obj;
    foreach int i in 0 ..< segments.length() - 1 {
        string segment = segments[i];
        json existing = current[segment];
        if existing is map<json> {
            current = existing;
        } else {
            map<json> newLevel = {};
            current[segment] = newLevel;
            current = newLevel;
        }
    }
    current[segments[segments.length() - 1]] = value;
}

// Applies transformFieldRenames/transformStaticFields/transformTimestampField to a parsed JSON
// object. Fields not mentioned in transformFieldRenames pass through untouched.
function applyTransform(map<json> payload) returns map<json> {
    map<json> transformed = payload.clone();

    foreach [string, string] [fromPath, toPath] in transformFieldRenames.entries() {
        json value = getByPath(transformed, fromPath);
        if value !is () {
            removeByPath(transformed, fromPath);
            setByPath(transformed, toPath, value);
        }
    }

    foreach [string, json] [fieldPath, value] in transformStaticFields.entries() {
        setByPath(transformed, fieldPath, value);
    }

    if transformTimestampField != "" {
        setByPath(transformed, transformTimestampField, time:utcToString(time:utcNow()));
    }

    return transformed;
}

// Parses payload (bytes, string, or already-json) into a JSON object, then applies the configured
// transformation above. Same validation as before this was made config-driven: a payload that
// isn't valid JSON, or is valid JSON but not an object, is an error - handleDelivery treats that
// as a permanent rejection to the DMQ, regardless of what transformFieldRenames etc. are set to.
function transformPayload(anydata payload) returns map<json>|error {
    json parsed;
    if payload is byte[] {
        parsed = check (check string:fromBytes(payload)).fromJsonString();
    } else if payload is string {
        parsed = check payload.fromJsonString();
    } else if payload is json {
        parsed = payload;
    } else {
        return error("payload is neither bytes, string, nor json - cannot transform");
    }

    if parsed !is map<json> {
        return error("payload is valid JSON but not a JSON object - cannot transform");
    }

    return applyTransform(parsed);
}

// Resolves transformHeaderFields against the already-transformed payload into a header map, merged
// into the outgoing request by handleDelivery alongside targetHeaders (static) and X-Correlation-Id
// (always set from the Solace message ID, not from the payload, so it isn't part of this config).
function resolveHeaderFields(map<json> transformed) returns map<string> {
    map<string> headers = {};
    foreach [string, string] [headerName, fieldPath] in transformHeaderFields.entries() {
        json value = getByPath(transformed, fieldPath);
        if value is string {
            headers[headerName] = value;
        }
    }
    return headers;
}
