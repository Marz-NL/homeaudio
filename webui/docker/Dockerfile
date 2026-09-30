# Builds just the playerui binary (not player-guard-helper - this instance
# has no local audio hardware to manage, only ever forwards to the real
# rooms' own playerui instances) for whatever architecture the Docker host
# running `docker compose build` actually is - no cross-compilation needed,
# unlike the aarch64 Pi builds.
FROM rust:1-slim-bookworm AS builder
WORKDIR /build
COPY . .
RUN cargo build --release -p playerui

# Same Debian base/glibc version as the builder, to avoid an ABI mismatch
# between the two stages.
FROM debian:bookworm-slim
RUN useradd --system --no-create-home --shell /usr/sbin/nologin playerui
COPY --from=builder /build/target/release/playerui /usr/local/bin/playerui
USER playerui
EXPOSE 8189
ENTRYPOINT ["/usr/local/bin/playerui"]
CMD ["/config/hub.toml", "0.0.0.0:8189"]
