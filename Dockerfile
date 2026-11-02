# Beacon production image for one of the example apps.
#
#   docker build -t beacon-counter .
#   docker build --build-arg EXAMPLE=todo --build-arg APP_MODULE=todo -t beacon-todo .
#   docker run --rm -p 8080:8080 beacon-counter
#
# EXAMPLE is the directory under examples/, APP_MODULE the Gleam module whose
# main/0 starts the app (the module `gleam run -m beacon/build` reports as the
# app module). To ship your own app, use this file as a template: copy your
# project instead of the repository and drop the examples/ prefix.
#
# Every step fails the image build on error: the Beacon build generates the
# server codec and client bundle, and the app refuses to start without them.

# Stage 1: build the app and export it as an Erlang shipment.
FROM ghcr.io/gleam-lang/gleam:v1.19.2-erlang-alpine AS builder

# The client bundle is built with the pinned esbuild through npx.
RUN apk add --no-cache nodejs npm

# Examples depend on Beacon by path (../..), so the whole repository is
# copied; .dockerignore keeps local build output out.
WORKDIR /src
COPY . .

ARG EXAMPLE=counter
WORKDIR /src/examples/${EXAMPLE}
RUN gleam run -m beacon/build
RUN gleam export erlang-shipment

# Stage 2: run on a plain Erlang image of the same OTP release.
FROM erlang:28-alpine

ARG EXAMPLE=counter
ARG APP_MODULE=counter
ENV APP_MODULE=${APP_MODULE}

RUN addgroup -S beacon && adduser -S -G beacon beacon

WORKDIR /app
COPY --from=builder /src/examples/${EXAMPLE}/build/erlang-shipment/ ./lib/
# beacon.start reads the client manifest and bundle from priv/static,
# relative to the working directory.
COPY --from=builder /src/examples/${EXAMPLE}/priv/ ./priv/

# beacon.start blocks while the server runs, so main/0 returning means the
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

USER beacon
EXPOSE 8080

# Beacon has no built-in health route; this checks that the app serves its
# page. Add a dedicated route (see docs/DEPLOYMENT.md) for real deployments.
# 127.0.0.1, not localhost: Alpine resolves localhost to ::1 first and the
# server listens on IPv4.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -q --spider http://127.0.0.1:8080/ || exit 1

CMD ["/app/start"]
