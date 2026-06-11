# =============================================================================
# Stage 1: Build (Rust NIF + Elixir release + frontend assets)
# =============================================================================
ARG RUST_VERSION=stable
ARG BUILDER_IMAGE="hexpm/elixir:1.18.3-erlang-26.2.5.2-debian-bookworm-20260316-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260316-slim"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies: Rust, Node.js, C compiler, git
RUN apt-get update -y && \
    apt-get install -y build-essential git curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Rust (needed for sparse_solver NIF)
ARG RUST_VERSION
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Install Node.js (needed for esbuild external deps like deck.gl)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Prepare build dir
WORKDIR /app

# Set build ENV
ENV MIX_ENV="prod"
# Skip EXLA native compilation (use BinaryBackend in prod — no GPU needed)
ENV XLA_TARGET="cpu"
ENV EXLA_TARGET="cpu"

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy Rust NIF source and compile
COPY native/ native/
RUN cd native/sparse_solver && cargo build --release
RUN mkdir -p priv/native && \
    cp native/sparse_solver/target/release/libsparse_solver.so priv/native/sparse_solver.so

# Copy application source and compile FIRST (needed for phoenix-colocated)
COPY lib/ lib/
COPY priv/ priv/
RUN mix compile

# Install frontend dependencies and build assets AFTER compile
COPY assets/ assets/
RUN cd assets && npm install
RUN mix assets.deploy

# Build the release
COPY config/runtime.exs config/
COPY rel/ rel/
RUN mix release

# =============================================================================
# Stage 2: Runtime (minimal image with just the release)
# =============================================================================
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# Set runner ENV
ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

# Copy the release from the builder
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/power_model ./

# Copy static grid data (binary files for Deck.gl visualization)
COPY --from=builder --chown=nobody:root /app/priv/static/grid_data ./lib/power_model-0.1.0/priv/static/grid_data

USER nobody

CMD ["/app/bin/server"]
