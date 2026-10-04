# syntax=docker/dockerfile:1
FROM rust:1.98.1-slim-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock build.rs ./
COPY src ./src
RUN cargo build --release --locked --features server --bin tasks-server --jobs 2

FROM debian:bookworm-slim AS runtime
RUN groupadd --gid 10001 tasks && useradd --uid 10001 --gid 10001 --no-create-home tasks \
    && mkdir /data && chown 10001:10001 /data
COPY --from=build /build/target/release/tasks-server /usr/local/bin/tasks-server
USER 10001:10001
WORKDIR /data
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["tasks-server", "--data-root", "/data"]
CMD ["serve", "--listen", "0.0.0.0:8080"]
