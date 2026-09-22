FROM ballerina/ballerina:2201.13.6 AS build
WORKDIR /build
COPY Ballerina.toml service.bal ./
RUN bal build .

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /build/target/bin/resilient_delivery_mock.jar .
CMD ["java", "-jar", "resilient_delivery_mock.jar"]
