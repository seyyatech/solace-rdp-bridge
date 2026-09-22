# Multi-stage build: compiles service.bal with the Ballerina toolchain, then runs the resulting
# jar on a plain JRE. No configuration is baked in here - every sample under samples/ supplies its
# own Config.toml via a bind mount at /app/Config.toml, so this image stays generic and reusable
# across every sample without a rebuild.
FROM ballerina/ballerina:2201.13.6 AS build
WORKDIR /build
COPY Ballerina.toml service.bal ./
RUN bal build .

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /build/target/bin/bridge.jar .
CMD ["java", "-jar", "bridge.jar"]
