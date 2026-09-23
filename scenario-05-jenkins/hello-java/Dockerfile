# Multi-stage: build with the JDK, ship with the JRE.
#
# The reason is size and attack surface. The build stage needs a compiler,
# Maven and the whole dependency tree; the runtime needs a JVM and one jar.
# Shipping the build stage would mean shipping javac and your entire ~/.m2 to
# production.
#
# Kaniko builds this in the pipeline - there is no Docker socket anywhere in
# the agent, and nothing here requires one.

# --- build ---------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# Copy the pom alone first and resolve dependencies as their own layer. That
# layer is cached and only invalidated when the pom changes, so an ordinary
# source-only commit skips re-downloading the internet. Copying everything up
# front would invalidate it on every commit.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q clean verify

# --- runtime -------------------------------------------------------------
FROM eclipse-temurin:21-jre

# Non-root, and created explicitly rather than relying on the base image.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

WORKDIR /app
COPY --from=build /build/target/hello-java-*.jar app.jar

EXPOSE 8080

# Exec form, so the JVM is PID 1 and receives SIGTERM directly. With the shell
# form, sh is PID 1, does not forward signals, and Kubernetes ends up killing
# the pod after the grace period instead of letting it shut down.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
