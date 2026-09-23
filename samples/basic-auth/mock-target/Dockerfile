FROM ballerina/ballerina:2201.13.6 AS build
WORKDIR /build
COPY Ballerina.toml service.bal ./
RUN bal build .

FROM eclipse-temurin:21-jre-jammy
WORKDIR /app
COPY --from=build /build/target/bin/basic_auth_mock.jar .
CMD ["java", "-jar", "basic_auth_mock.jar"]
