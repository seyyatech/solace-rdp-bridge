import ballerina/test;

// These exercise the path-resolution helpers directly - they don't depend on any configurable
// value, so they're unaffected by tests/Config.toml below.

@test:Config {}
function testFlatRename() {
    map<json> obj = {"workerId": "W-1"};
    test:assertEquals(getByPath(obj, "workerId"), "W-1");
}

@test:Config {}
function testExactKeyBeatsNestedSplit() {
    // A literal flat key containing a dot must win over splitting into a nested walk - the fix
    // for the {"employee.employeeId": ...} vs {"employee": {"employeeId": ...}} ambiguity.
    map<json> flatDotted = {"employee.employeeId": 23243};
    test:assertEquals(getByPath(flatDotted, "employee.employeeId"), 23243);

    map<json> nested = {"employee": {"employeeId": 123}};
    test:assertEquals(getByPath(nested, "employee.employeeId"), 123);
}

@test:Config {}
function testGetByPathMissingReturnsNil() {
    map<json> obj = {"a": 1};
    test:assertTrue(getByPath(obj, "b") is ());
    test:assertTrue(getByPath(obj, "a.b") is ());
}

@test:Config {}
function testRemoveByPathFlatAndNested() {
    map<json> flatDotted = {"employee.employeeId": 1, "keep": "x"};
    removeByPath(flatDotted, "employee.employeeId");
    test:assertFalse(flatDotted.hasKey("employee.employeeId"));
    test:assertEquals(flatDotted["keep"], "x");

    map<json> nested = {"employee": {"employeeId": 1, "other": "y"}};
    removeByPath(nested, "employee.employeeId");
    json employee = nested["employee"];
    if employee is map<json> {
        test:assertFalse(employee.hasKey("employeeId"));
        test:assertEquals(employee["other"], "y");
    } else {
        test:assertFail("employee should still be a map");
    }
}

@test:Config {}
function testSetByPathCreatesNesting() {
    map<json> obj = {};
    setByPath(obj, "employee.id", 42);
    json employee = obj["employee"];
    if employee is map<json> {
        test:assertEquals(employee["id"], 42);
    } else {
        test:assertFail("expected employee to be created as a nested object");
    }
}

// These exercise the configurable-driven functions under tests/Config.toml, which sets
// transformFieldRenames/transformStaticFields/transformTimestampField/transformHeaderFields to
// the same values samples/payload-transformation's docker-config.toml uses - proving the
// config-driven engine reproduces the original hardcoded transformPayload exactly.

@test:Config {}
function testConfiguredTransformReproducesOriginalHardcodedBehavior() {
    map<json>|error result = transformPayload(
        "{\"workerId\":\"W-1\",\"eventType\":\"HIRE\",\"department\":\"Engineering\"}");
    if result is map<json> {
        test:assertEquals(result["employeeId"], "W-1");
        test:assertEquals(result["action"], "HIRE");
        test:assertEquals(result["department"], "Engineering"); // untouched field still passes through
        test:assertEquals(result["source"], "solace-delivery-bridge");
        test:assertFalse(result.hasKey("workerId"));
        test:assertFalse(result.hasKey("eventType"));
        test:assertTrue(result["processedAt"] is string);

        map<string> headers = resolveHeaderFields(result);
        test:assertEquals(headers["X-Event-Type"], "HIRE");
    } else {
        test:assertFail("expected successful transform");
    }
}

@test:Config {}
function testTransformPayloadRejectsNonJson() {
    map<json>|error result = transformPayload("not json");
    test:assertTrue(result is error);
}

@test:Config {}
function testTransformPayloadRejectsNonObjectJson() {
    map<json>|error result = transformPayload("[1,2,3]");
    test:assertTrue(result is error);
}
