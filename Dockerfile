# Brazier production image for one of the example apps.
#
#   docker build -t brazier-counter .
#   docker build --build-arg EXAMPLE=todo --build-arg APP_MODULE=todo -t brazier-todo .
#   docker run --rm -p 8080:8080 brazier-counter
#
# EXAMPLE is the directory under examples/, APP_MODULE the Gleam module whose
# main/0 starts the app (the module `gleam run -m brazier/build` reports as the
# app module). To ship your own app, use this file as a template: copy your
# project instead of the repository and drop the examples/ prefix.
#
# Every step fails the image build on error: the Brazier build generates the
# server codec and client bundle, and the app refuses to start without them.

# Stage 1: build the app and export it as an Erlang shipment.
FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine AS builder

# The client bundle is built with the pinned esbuild through npx.
RUN apk add --no-cache nodejs npm

# Examples depend on Brazier by path (../..), so the whole repository is
# copied; .dockerignore keeps local build output out.
WORKDIR /src
COPY . .

ARG EXAMPLE=counter
WORKDIR /src/examples/${EXAMPLE}
# Resolving the dependencies looks each Hex package up through the Hex API,
# which allows 100 unauthenticated requests a minute per IP. A build on an IP
# it shares (a CI runner) can pass a read-only key as the BuildKit secret
# hexpm_read_api_key (docker build --secret id=hexpm_read_api_key,env=...);
# Gleam reads it as HEXPM_READ_API_KEY. It is in no layer of the image.
RUN --mount=type=secret,id=hexpm_read_api_key,required=false \
    set -eu; \
    if [ -s /run/secrets/hexpm_read_api_key ]; then \
      HEXPM_READ_API_KEY="$(cat /run/secrets/hexpm_read_api_key)"; \
      export HEXPM_READ_API_KEY; \
      echo "Hex requests are authenticated with HEXPM_READ_API_KEY"; \
    else \
      echo "No hexpm_read_api_key secret: Hex requests are unauthenticated"; \
    fi; \
    gleam deps download
RUN gleam run -m brazier/build
RUN gleam export erlang-shipment
RUN erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().' > /otp_release

# Stage 2: run on a plain Erlang image of the same OTP release. A BEAM file
# compiled by a newer release may not load on an older one, so the build
# fails when the two stages' releases differ.
FROM erlang:29-alpine

RUN --mount=type=bind,from=builder,source=/otp_release,target=/tmp/builder_otp_release \
    set -eu; \
    builder=$(cat /tmp/builder_otp_release); \
    runtime=$(erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'); \
    if [ "$builder" != "$runtime" ]; then \
      echo "the builder stage compiled with OTP $builder, but the runtime stage runs OTP $runtime" >&2; \
      exit 1; \
    fi; \
    echo "builder and runtime both run OTP $runtime"

ARG EXAMPLE=counter
ARG APP_MODULE=counter
ENV APP_MODULE=${APP_MODULE}

RUN addgroup -S brazier && adduser -S -G brazier brazier

WORKDIR /app
COPY --from=builder /src/examples/${EXAMPLE}/build/erlang-shipment/ ./lib/
# brazier.start reads the client manifest and bundle from priv/static,
# relative to the working directory.
COPY --from=builder /src/examples/${EXAMPLE}/priv/ ./priv/

# brazier.start blocks while the server runs, so main/0 returning means the
# app stopped: an Error result or a crash exits with status 1.
COPY <<'EOF' /app/start
#!/bin/sh
set -eu
module=$(printf '%s' "$APP_MODULE" | tr / @)
exec erl -pa /app/lib/*/ebin -noshell -eval "
  try '$module':main() of
    {error, Reason} ->
      io:format(standard_error, \"~s:main() returned an error: ~p~n\", [\"$module\", Reason]),
      halt(1);
    _ -> halt(0)
  catch Class:Error:Stack ->
    io:format(standard_error, \"~s:main() crashed: ~p:~p~n~p~n\", [\"$module\", Class, Error, Stack]),
    halt(1)
  end."
EOF
RUN chmod 0755 /app/start

USER brazier
EXPOSE 8080

# Brazier answers /health with 200 (see docs/DEPLOYMENT.md), but that only
# shows the listener is up. This check requests / instead, which renders the
# app's first page, so it also fails when the app cannot render it. Use
# /health for a cheaper liveness check.
# 127.0.0.1, not localhost: Alpine resolves localhost to ::1 first and the
# server listens on IPv4.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -q --spider http://127.0.0.1:8080/ || exit 1

CMD ["/app/start"]
